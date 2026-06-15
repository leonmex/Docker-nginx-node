#!/usr/bin/env python3
"""
Extract LinkedIn recommendations from a saved HTML dump into JSON.

This parses the "Recommendations" page HTML saved from LinkedIn (the raw
markup with obfuscated CSS class names) and pulls out, for each entry:

    - name            -> the person who wrote the recommendation
    - role            -> their headline / title (the line under the name)
    - recommendation  -> the full recommendation text (all paragraphs joined,
                         including the part hidden behind the "…more" link)
    - linkedinProfile -> the URL of the recommender's LinkedIn profile

HOW THE PARSING WORKS
---------------------
We don't rely on the (volatile, auto-generated) CSS class names. Instead we
strip all HTML tags, collapse the page into a flat list of visible text lines,
and exploit the very regular structure LinkedIn renders for each card:

    Yevhenii Shevchuk                 <- name
    · 1st                             <- connection degree  (the anchor we key on)
    Senior PHP Developer              <- role / headline
    February 18, 2026, ... directly   <- date + relationship line
    All LinkedIn members              <- visibility label
    On                                <- visibility toggle state
    <paragraph 1>                     <- recommendation body...
    <paragraph 2>
    …                                 <- truncation ellipsis (ignored)
    more                              <- "see more" link      (ignored)

So the algorithm is:
    1. A record starts wherever a line is immediately followed by a
       "· <N>st/nd/rd/th" connection-degree line.
    2. name = that line, role = the line after the degree.
    3. Skip forward past the "On" line (end of the metadata block).
    4. Collect every following line as body text until we hit the next record
       (next name + degree pair) or end of file, dropping the boilerplate
       lines ("All LinkedIn members", "On") and the "…" / "more" UI cruft.

If LinkedIn changes its markup, the connection-degree regex (`CONN_RE`) and the
set of skipped boilerplate lines (`SKIP_LINES`) are the two things to revisit.

USAGE
-----
    # 1) Pass the HTML location on the command line:
    python3 read-recommendations-from-linkedin.py path/to/saved.html -o out.json

    # 2) Or run with no arguments and you'll be prompted for the input
    #    (and output) location interactively:
    python3 read-recommendations-from-linkedin.py
"""

from __future__ import annotations

import argparse
import html as html_module
import json
import re
import sys
from pathlib import Path

# Matches the connection-degree line that always follows a person's name,
# e.g. "· 1st", "· 2nd", "· 3rd". This is our anchor for detecting a record.
CONN_RE = re.compile(r"^· \d+(st|nd|rd|th)$")

# Each card wraps the recommender's avatar and name in an <a> linking to their
# LinkedIn profile. We rewrite those opening tags into a sentinel line (see
# html_to_lines) so the profile URL survives tag-stripping; PROFILE_RE pulls the
# URL back out of that sentinel.
PROFILE_OPEN_RE = re.compile(
    r'<a\b[^>]*href="(https://www\.linkedin\.com/in/[^"]+)"[^>]*>'
)
PROFILE_RE = re.compile(r"^@@PROFILE:(.+)@@$")

# Boilerplate / UI lines that appear inside a card but are not body text.
SKIP_LINES = {"All LinkedIn members", "On", "…", "more"}

# Suggested defaults, only used as the prompt fallback when running interactively.
DEFAULT_INPUT = "src/data/all-recommendations.html"
DEFAULT_OUTPUT = "src/data/recommendations.json"


def html_to_lines(raw_html: str) -> list[str]:
    """Strip tags and return a flat list of non-empty, unescaped text lines.

    Profile links are first rewritten into "@@PROFILE:<url>@@" sentinel lines so
    the URL is not lost when the surrounding tags are stripped.
    """
    raw_html = PROFILE_OPEN_RE.sub(r"\n@@PROFILE:\1@@\n", raw_html)
    text = re.sub(r"<[^>]+>", "\n", raw_html)
    return [
        html_module.unescape(line.strip())
        for line in text.split("\n")
        if line.strip()
    ]


def parse_recommendations(lines: list[str]) -> list[dict]:
    """Walk the flat line list and build one dict per recommendation."""
    recs: list[dict] = []
    i, n = 0, len(lines)
    last_profile = ""  # most recent profile sentinel seen; belongs to next card

    while i < n:
        # Track profile sentinels; the nearest one before a name is that card's.
        profile_match = PROFILE_RE.match(lines[i])
        if profile_match:
            last_profile = profile_match.group(1)
            i += 1
            continue

        # A record begins when the next line is a connection-degree marker.
        if i + 1 < n and CONN_RE.match(lines[i + 1]):
            name = lines[i]
            role = lines[i + 2] if i + 2 < n else ""

            # Advance past the metadata block (date, visibility) ending at "On".
            j = i + 3
            while j < n and lines[j] != "On":
                j += 1
            j += 1  # step over "On"

            # Collect body paragraphs until the next record or end of input.
            body: list[str] = []
            while j < n:
                if PROFILE_RE.match(lines[j]):
                    break  # profile sentinel = start of the next person's card
                if j + 1 < n and CONN_RE.match(lines[j + 1]):
                    break  # start of the next person's card
                if lines[j] not in SKIP_LINES:
                    body.append(lines[j])
                j += 1

            recs.append(
                {
                    "name": name,
                    "role": role,
                    "recommendation": " ".join(body),
                    "linkedinProfile": last_profile,
                }
            )
            i = j
        else:
            i += 1

    return recs


def prompt_for_path(question: str, default: str) -> str:
    """Ask the user for a path, falling back to `default` on empty input."""
    answer = input(f"{question} [{default}]: ").strip()
    return answer or default


def resolve_paths(args: argparse.Namespace) -> tuple[Path, Path]:
    """Determine input/output locations, prompting the user when not provided."""
    input_arg = args.input
    if input_arg is None:
        input_arg = prompt_for_path(
            "Path to the saved LinkedIn HTML file", DEFAULT_INPUT
        )

    output_arg = args.output
    if output_arg is None:
        output_arg = prompt_for_path(
            "Path to write the JSON output", DEFAULT_OUTPUT
        )

    return Path(input_arg).expanduser(), Path(output_arg).expanduser()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Extract LinkedIn recommendations from saved HTML into JSON."
    )
    parser.add_argument(
        "input",
        nargs="?",
        default=None,
        help="Input HTML file. If omitted, you will be prompted for it.",
    )
    parser.add_argument(
        "-o",
        "--output",
        default=None,
        help="Output JSON file. If omitted, you will be prompted for it.",
    )
    args = parser.parse_args(argv)

    input_path, output_path = resolve_paths(args)

    if not input_path.is_file():
        print(f"error: input file not found: {input_path}", file=sys.stderr)
        return 1

    raw_html = input_path.read_text(encoding="utf-8")
    recs = parse_recommendations(html_to_lines(raw_html))

    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text(
        json.dumps(recs, ensure_ascii=False, indent=2), encoding="utf-8"
    )

    print(f"Wrote {len(recs)} recommendations to {output_path}")
    for r in recs:
        print(f"  - {r['name']} | {r['role']}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
