# Feature Specification: Dynamic Email Template Builder & Management System

**Author**: Senior Software & Data Architect  
**Target Repository**: `node-nginx-clean` (Backend Server & Admin Dashboard)  
**Location**: `server/FEATURES/NEW-BASIC-EMAIL-BUILDER.md`  
**Feature**: Dynamic Email Template Management & Rendering System under `Marketing -> Email Templates`

---

## Executive Summary

To move away from hardcoded email strings and establish a flexible, production-grade email management system, we will design and implement a dynamic **Email Template Engine** with a full **CRUD Dashboard interface** under `Marketing -> Email Templates`.

This system will allow administrators to manage, edit, preview, and test transactional & marketing email templates (such as `verification_code`, `password_reset`, `welcome_email`, `order_confirmation`, etc.) directly from the Dashboard without redeploying code.

---

## 1. Database Architecture & Schema Design

We will add a new dedicated table `email_templates` via PostgreSQL migration (`db/migrations/0039_email_templates.sql`).

```sql
CREATE TABLE email_templates (
  id SERIAL PRIMARY KEY,
  template_key VARCHAR(64) UNIQUE NOT NULL, -- e.g. 'verification_code', 'welcome_user'
  name VARCHAR(128) NOT NULL,              -- e.g. 'User Account Verification'
  description TEXT,                         -- Description for marketing/admin teams
  subject VARCHAR(255) NOT NULL,            -- e.g. 'Verify your {{appName}} account'
  html_body TEXT NOT NULL,                  -- Responsive HTML body with {{variable}} placeholders
  text_body TEXT NOT NULL,                  -- Plain text fallback with {{variable}} placeholders
  available_variables JSONB NOT NULL DEFAULT '[]', -- List of supported keys: ["verificationCode", "appName", ...]
  is_active BOOLEAN NOT NULL DEFAULT true,  -- Enables soft disabling
  created_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
```

### Initial Seed Data
The database migration will seed default system templates (including `verification_code` with high-deliverability HTML layout and placeholder keys `{{verificationCode}}`, `{{appName}}`, `{{supportEmail}}`).

---

## 2. Server Architecture (`server/src/`)

### A. Template Rendering Engine (`services/EmailTemplateRenderer.ts`)
A lightweight, fast Mustache/Handlebars-style interpolation engine using standard regex replacement:

```typescript
export function renderTemplate(templateStr: string, variables: Record<string, unknown>): string {
  return templateStr.replace(/\{\{\s*([a-zA-Z0-9_]+)\s*\}\}/g, (match, key) => {
    return variables[key] !== undefined ? String(variables[key]) : match;
  });
}
```

### B. Repository Layer (`repositories/PgEmailTemplateRepository.ts`)
Exposes repository methods:
- `findAll(params: { page, limit, search }): Promise<EmailTemplate[]>`
- `findByKey(templateKey: string): Promise<EmailTemplate | null>`
- `create(data): Promise<EmailTemplate>`
- `update(id, data): Promise<EmailTemplate>`
- `delete(id): Promise<void>`

### C. Admin API Endpoints (`routes/adminEmailTemplates.ts`)
Under `/api/admin/marketing/email-templates`:
- `GET /` — List email templates (with search & pagination).
- `GET /:id` — Get single template details.
- `POST /` — Create new template.
- `PUT /:id` — Update existing template (subject, HTML body, text body, variables).
- `DELETE /:id` — Delete template.
- `POST /:id/test-send` — Send test email to specified recipient.

### D. Service Integration (`services/SmtpEmailService.ts` / `routes/accounts.ts`)
`accounts.ts` will fetch the active `verification_code` template from `PgEmailTemplateRepository` (with Redis caching for high throughput), render it dynamically with `{ verificationCode: '9948-4177', appName: 'Blablarags' }`, and dispatch via `SmtpEmailService`.

---

## 3. Frontend Architecture (`dashboard/src/`)

### A. Navigation & Routing (`config/routes.ts`)
Under `Marketing` (`/marketing`):
- `Marketing -> Campaigns` (`/marketing/campaigns`)
- `Marketing -> Email Templates` (`/marketing/email-templates`) **[NEW]**
- `Marketing -> Email Templates -> Create/Edit` (`/marketing/email-templates/form`) **[NEW]**

### B. Dashboard UI Features (`pages/marketing/email-templates/`)
1. **List View (`index.tsx`)**:
   - ProTable displaying Template Name, Key, Description, Available Variables tags, Last Updated, Status, and Actions (Edit, Test Send, Delete).
2. **Editor View (`form.tsx`)**:
   - **Template Metadata**: Name, Key, Description.
   - **Subject Line**: Input field supporting `{{variable}}` insertion.
   - **Available Variables Inspector**: Interactive tag pill list showing allowable variables (e.g. `{{verificationCode}}`, `{{username}}`, `{{supportEmail}}`). Clicking a tag inserts it into the active editor!
   - **Dual Code / Live Preview Editor**:
     - Left pane: HTML code editor with syntax highlighting.
     - Right pane: Live responsive iframe preview rendering real-time HTML with sample mock variables.
   - **Plain Text Fallback Tab**: Plain text editor for non-HTML email clients.
3. **Test Send Modal**:
   - Allows administrators to type a test email address and trigger an instant test send.

---

## 4. Verification & Deployment Plan

### Automated Tests
- Database migration unit tests.
- Repository & template renderer unit tests (`{{variable}}` substitution edge cases).
- API integration tests for CRUD endpoints & test email dispatch.

### Manual Verification
- Log into Admin Dashboard $\rightarrow$ navigate to `Marketing -> Email Templates`.
- Edit `verification_code` subject or HTML layout.
- Use **Test Send** modal to send a live test email.
- Trigger mobile app registration and verify the custom HTML layout renders in the inbox with the generated verification code.
