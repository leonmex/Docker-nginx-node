#!/usr/bin/env python3
import os
import re
from PIL import Image as PILImage
from reportlab.lib.pagesizes import letter
from reportlab.lib import colors
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, Image, HRFlowable, KeepTogether
)
from reportlab.pdfgen import canvas

MD_PATH = "/Users/nbarrera/projects/Docker/node-nginx-clean/project_description_20260728.md"
PDF_PATH = "/Users/nbarrera/projects/Docker/node-nginx-clean/project_description_20260728.pdf"

class NumberedCanvas(canvas.Canvas):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._saved_page_states = []

    def showPage(self):
        self._saved_page_states.append(dict(self.__dict__))
        self._startPage()

    def save(self):
        num_pages = len(self._saved_page_states)
        for state in self._saved_page_states:
            self.__dict__.update(state)
            self.draw_page_decorations(num_pages)
            super().showPage()
        super().save()

    def draw_page_decorations(self, page_count):
        self.saveState()
        self.setFont("Helvetica", 9)
        self.setFillColor(colors.HexColor("#737686"))
        
        # Header (pages > 1)
        if self._pageNumber > 1:
            self.drawString(36, 760, "Blablarags Ecosystem — Investor Specification & Architectural Guide")
            self.setStrokeColor(colors.HexColor("#c3c6d7"))
            self.setLineWidth(0.5)
            self.line(36, 752, 576, 752)

        # Footer
        self.setStrokeColor(colors.HexColor("#c3c6d7"))
        self.setLineWidth(0.5)
        self.line(36, 45, 576, 45)
        
        page_str = f"Page {self._pageNumber} of {page_count}"
        self.drawRightString(576, 30, page_str)
        self.drawString(36, 30, "CONFIDENTIAL — BLABLARAGSANDRIGS GMBH")
        self.restoreState()

def parse_markdown_to_flowables(md_text):
    styles = getSampleStyleSheet()
    
    primary_color = colors.HexColor("#004ac6")
    text_color = colors.HexColor("#191c1e")
    sub_color = colors.HexColor("#434655")
    
    title_style = ParagraphStyle(
        'DocTitle', parent=styles['Heading1'],
        fontName='Helvetica-Bold', fontSize=22, leading=26,
        textColor=primary_color, spaceAfter=12
    )
    h2_style = ParagraphStyle(
        'Heading2_Custom', parent=styles['Heading2'],
        fontName='Helvetica-Bold', fontSize=15, leading=18,
        textColor=primary_color, spaceBefore=14, spaceAfter=8,
        keepWithNext=True
    )
    h3_style = ParagraphStyle(
        'Heading3_Custom', parent=styles['Heading3'],
        fontName='Helvetica-Bold', fontSize=12, leading=15,
        textColor=text_color, spaceBefore=10, spaceAfter=6,
        keepWithNext=True
    )
    h4_style = ParagraphStyle(
        'Heading4_Custom', parent=styles['Heading4'],
        fontName='Helvetica-Bold', fontSize=10, leading=13,
        textColor=sub_color, spaceBefore=8, spaceAfter=4,
        keepWithNext=True
    )
    body_style = ParagraphStyle(
        'Body_Custom', parent=styles['Normal'],
        fontName='Helvetica', fontSize=9.5, leading=13.5,
        textColor=text_color, spaceAfter=6
    )
    bullet_style = ParagraphStyle(
        'Bullet_Custom', parent=body_style,
        leftIndent=15, firstLineIndent=-10, spaceAfter=4
    )
    code_box_style = ParagraphStyle(
        'CodeBox', parent=styles['Code'],
        fontName='Courier', fontSize=8, leading=10.5,
        textColor=colors.HexColor("#1e293b"), spaceAfter=8
    )
    note_style = ParagraphStyle(
        'NoteBox', parent=body_style,
        fontName='Helvetica-Oblique', fontSize=9, leading=12.5,
        textColor=colors.HexColor("#1e3a8a"), spaceBefore=4, spaceAfter=4
    )

    flowables = []
    lines = md_text.split('\n')
    in_code_block = False
    code_lines = []
    in_table = False
    table_rows = []

    def flush_table():
        nonlocal in_table, table_rows
        if not table_rows:
            return
        
        col_count = max(len(r) for r in table_rows)
        col_width = 540.0 / col_count
        
        formatted_table = []
        for r_idx, row in enumerate(table_rows):
            formatted_row = []
            for cell in row:
                cell_p = Paragraph(cell, h3_style if r_idx == 0 else body_style)
                formatted_row.append(cell_p)
            while len(formatted_row) < col_count:
                formatted_row.append(Paragraph("", body_style))
            formatted_table.append(formatted_row)

        t = Table(formatted_table, colWidths=[col_width] * col_count)
        t.setStyle(TableStyle([
            ('BACKGROUND', (0, 0), (-1, 0), colors.HexColor("#dbe1ff")),
            ('TEXTCOLOR', (0, 0), (-1, 0), colors.HexColor("#004ac6")),
            ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
            ('VALIGN', (0, 0), (-1, -1), 'TOP'),
            ('BOTTOMPADDING', (0, 0), (-1, -1), 6),
            ('TOPPADDING', (0, 0), (-1, -1), 6),
            ('LEFTPADDING', (0, 0), (-1, -1), 6),
            ('RIGHTPADDING', (0, 0), (-1, -1), 6),
            ('GRID', (0, 0), (-1, -1), 0.5, colors.HexColor("#c3c6d7")),
            ('ROWBACKGROUNDS', (0, 1), (-1, -1), [colors.white, colors.HexColor("#f8f9fb")]),
        ]))
        flowables.append(Spacer(1, 4))
        flowables.append(t)
        flowables.append(Spacer(1, 8))
        in_table = False
        table_rows = []

    for line in lines:
        raw_line = line.strip()

        # Handle Code Blocks
        if raw_line.startswith("```"):
            if in_code_block:
                code_text = "\n".join(code_lines)
                code_p = Paragraph(code_text.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;").replace("\n", "<br/>"), code_box_style)
                t_code = Table([[code_p]], colWidths=[540])
                t_code.setStyle(TableStyle([
                    ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor("#f1f5f9")),
                    ('BOX', (0, 0), (-1, -1), 0.5, colors.HexColor("#cbd5e1")),
                    ('PADDING', (0, 0), (-1, -1), 8),
                ]))
                flowables.append(t_code)
                flowables.append(Spacer(1, 8))
                in_code_block = False
                code_lines = []
            else:
                if in_table:
                    flush_table()
                in_code_block = True
                code_lines = []
            continue

        if in_code_block:
            code_lines.append(line)
            continue

        # Handle Markdown Tables
        if raw_line.startswith("|") and raw_line.endswith("|"):
            if "---" in raw_line:
                continue
            cells = [c.strip() for c in raw_line.split("|")[1:-1]]
            table_rows.append(cells)
            in_table = True
            continue
        elif in_table:
            flush_table()

        if not raw_line:
            continue

        # Handle Horizontal Rules
        if raw_line in ("---", "***", "___"):
            flowables.append(HRFlowable(width="100%", thickness=0.75, color=colors.HexColor("#c3c6d7"), spaceBefore=8, spaceAfter=8))
            continue

        # Handle Images: ![caption](path) or [Visual Reference](file:///path)
        img_match = re.search(r'!\[(.*?)\]\((.*?)\)|\[(.*?)\]\((file:///.*?\.png)\)', raw_line)
        if img_match:
            img_caption = img_match.group(1) or img_match.group(3) or "Screen Preview"
            img_url = img_match.group(2) or img_match.group(4)
            img_path = img_url.replace("file://", "")
            
            if os.path.exists(img_path):
                try:
                    with PILImage.open(img_path) as pil_img:
                        orig_w, orig_h = pil_img.size

                    aspect = orig_h / float(orig_w) if orig_w > 0 else 1.0

                    if aspect > 1.2:
                        # Mobile Vertical Screen (Portrait)
                        target_h = 240.0
                        target_w = target_h / aspect
                    else:
                        # Desktop Dashboard Screen (Landscape)
                        target_w = 460.0
                        target_h = target_w * aspect
                        if target_h > 260.0:
                            target_h = 260.0
                            target_w = target_h / aspect

                    img = Image(img_path, width=target_w, height=target_h)
                    
                    # Wrap image in a clean border frame
                    t_img = Table([[img]], colWidths=[target_w + 12])
                    t_img.setStyle(TableStyle([
                        ('ALIGN', (0, 0), (-1, -1), 'CENTER'),
                        ('VALIGN', (0, 0), (-1, -1), 'MIDDLE'),
                        ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor("#f8f9fa")),
                        ('BOX', (0, 0), (-1, -1), 0.75, colors.HexColor("#cbd5e1")),
                        ('PADDING', (0, 0), (-1, -1), 6),
                    ]))
                    t_img.hAlign = 'CENTER'

                    caption_p = Paragraph(f"<b>Visual Reference:</b> {img_caption}", note_style)
                    flowables.append(KeepTogether([
                        Spacer(1, 4),
                        caption_p,
                        Spacer(1, 4),
                        t_img,
                        Spacer(1, 8)
                    ]))
                    continue
                except Exception as e:
                    print(f"Could not load image {img_path}: {e}")

        # Format inline formatting
        fmt_line = raw_line
        fmt_line = re.sub(r'\*\*(.*?)\*\*', r'<b>\1</b>', fmt_line)
        fmt_line = re.sub(r'\*(.*?)\*', r'<i>\1</i>', fmt_line)
        fmt_line = re.sub(r'`(.*?)`', r'<font name="Courier" color="#004ac6">\1</font>', fmt_line)

        # Handle Headings
        if raw_line.startswith("# "):
            flowables.append(Paragraph(fmt_line[2:], title_style))
        elif raw_line.startswith("## "):
            flowables.append(Paragraph(fmt_line[3:], h2_style))
        elif raw_line.startswith("### "):
            flowables.append(Paragraph(fmt_line[4:], h3_style))
        elif raw_line.startswith("#### "):
            flowables.append(Paragraph(fmt_line[5:], h4_style))
        elif raw_line.startswith("- ") or raw_line.startswith("* "):
            flowables.append(Paragraph(f"• {fmt_line[2:]}", bullet_style))
        elif raw_line.startswith("1. ") or raw_line.startswith("2. ") or raw_line.startswith("3. ") or raw_line.startswith("4. ") or raw_line.startswith("5. "):
            flowables.append(Paragraph(fmt_line, bullet_style))
        elif raw_line.startswith("> "):
            note_p = Paragraph(fmt_line[2:], note_style)
            t_note = Table([[note_p]], colWidths=[540])
            t_note.setStyle(TableStyle([
                ('BACKGROUND', (0, 0), (-1, -1), colors.HexColor("#eff6ff")),
                ('BOX', (0, 0), (-1, -1), 0.5, colors.HexColor("#93c5fd")),
                ('PADDING', (0, 0), (-1, -1), 6),
            ]))
            flowables.append(t_note)
            flowables.append(Spacer(1, 6))
        else:
            flowables.append(Paragraph(fmt_line, body_style))

    if in_table:
        flush_table()

    return flowables

def main():
    print(f"Reading markdown file: {MD_PATH}")
    with open(MD_PATH, 'r', encoding='utf-8') as f:
        md_text = f.read()

    print(f"Parsing content and building mobile-optimized PDF layout...")
    flowables = parse_markdown_to_flowables(md_text)

    print(f"Generating PDF output to: {PDF_PATH}")
    doc = SimpleDocTemplate(
        PDF_PATH,
        pagesize=letter,
        leftMargin=36,
        rightMargin=36,
        topMargin=54,
        bottomMargin=54
    )

    doc.build(flowables, canvasmaker=NumberedCanvas)
    print(f"SUCCESS: PDF created at {PDF_PATH}")

if __name__ == "__main__":
    main()
