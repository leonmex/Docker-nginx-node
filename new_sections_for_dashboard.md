# New Dashboard Sections: Blablarags Mobile Backend & Dashboard RBAC Architecture

Written as a build proposal for the Ant Design Pro admin dashboard, covering
the data/endpoints added in `server/db/migrations/0004_blablarags_catalog_and_profiles.sql`,
`0005_user_teams_privileges.sql`, and `server/src/routes/{accounts,mobileProfile,apparel,paymentFraudReviews}.ts`
(see `Flutter_Apps/blablaragsandrigs/project_migrate_endpoints_to_server_v1.md`
for the mobile API these back). Every section below follows the same
backend/frontend/test build order as `claude-add-new-section.md` — this doc
is the "Description" input for each of those five invocations, plus the
priority ordering and the backend gaps that block starting some of them.

No emojis anywhere, per repo convention.

> [!IMPORTANT]
> **Every route below MUST live under `/api/admin/`** — not a convention to
> follow loosely, an enforced requirement. `nginx/default.conf` has a
> dedicated `location /api/admin/` block with **no rate limiting at all**
> (unlike every other `/api/*` path), because the dashboard is a trusted
> internal tool that legitimately does bulk operations (e.g. auditing
> thousands of mobile accounts) and every route here is already gated by
> `requireAdmin()`/the session cookie — that auth check is the real defense,
> not a rate ceiling. A route that's admin-gated but registered outside this
> prefix (the mistake found and fixed 2026-07-19 in
> `llm-performance.ts` — its two admin actions were at `/api/llm-performance/...`
> instead of `/api/admin/llm-performance/...`) silently falls into the
> rate-limited general zone instead and can get 503'd during real bulk admin
> work. See `proxy_hardening_and_public_access_proposal.md` §2.1.

---

## Dashboard Main Menu & Submenu Hierarchy

Based on `server/docs/database-entity-relaction.md`, the dashboard structure is organized into four primary top-level menu domains:

```
├── System & Roles (Internal Dashboard Users)
│   ├── Internal Users & Teams (`users`, `user_tags`, `user_teams`)
│   ├── Role & Team Privileges (`user_teams_privileges`)
│   └── Dashboard Notices & Activity (`dashboard_notices`, `fake_list`, `account_activity_items`)
│
├── Accounts (App & Web Customers Domain)
│   ├── Customers (`mobile_accounts`, `user_profiles`) --> see feature_customers_dashboard.md
│   ├── Payment & Fraud Review (`user_payment_methods`, `payment_fraud_reviews`)
│   └── Pro Seller Applications (`user_pro_seller`)
│
├── BlablaAI (LLM Analytics)
│   └── LLM Performance (`user_action_logs`, `pending_category_suggestions`)
│
└── Apparel Catalog (Taxonomy & Catalog Moderation)
    ├── Apparel Categories (`categories`, `category_tree`)
    └── Catalog Moderation (`product_groups`, `product_items`, `item_images`)
```

---

## Dashboard RBAC: User Teams Privileges Table

Dashboard user privileges, responsibilities, view scope, and specific section actions (e.g., editing customer data) are managed through `user_teams_privileges` (migration `server/db/migrations/0005_user_teams_privileges.sql`), joining `users` to `user_teams` by `title_key`:

- **Table**: `user_teams_privileges`
  - `id`: `SERIAL PRIMARY KEY`
  - `team_title_key`: `VARCHAR(64)` (e.g. `'Customer-Service'`, `'Catalog-Admin'`)
  - `section_key`: `VARCHAR(64)` (e.g. `'customers'`, `'account_data'`, `'apparel_categories'`)
  - `action_key`: `VARCHAR(64)` (e.g. `'view'`, `'edit_customers'`, `'takedown'`)
  - `permission_scope`: `VARCHAR(32)` (`'all'`, `'own_team'`, `'read_only'`)
  - `is_granted`: `BOOLEAN` (`true`/`false`)

---

## Priority Order and Why

1. **Apparel Categories (taxonomy)** — blocking. Every apparel upload today
   silently produces `predicted_category_id: null` because the `categories`
   table has never been seeded and no admin route exists to populate it.
2. **Payment & Fraud Review** — cheapest win. The backend is already 100% built and tested.
3. **Pro Seller Applications** — blocking a dead-end feature.
4. **Accounts -> Customers** — read/moderate the end-user base (detailed in `dashboard/docs/feature_customers_dashboard.md`).
5. **Product Groups / Items (catalog moderation)** — read-heavy, lowest urgency.

---

## Feature-Specific Documentation

Each dashboard section is specified in detail in its own feature document:

- **Accounts -> Customers**: [`dashboard/docs/feature_customers_dashboard.md`](file:///Users/nbarrera/projects/Docker/node-nginx-clean/dashboard/docs/feature_customers_dashboard.md)
  - Tables: `mobile_accounts`, `user_profiles`
  - Displays: `id`, `account_id` (Act. Id), `username` (User Name), `email_verified` (Email Verf.), `is_verified` (Account Verf.), `member_since` (Mem. Since), `language_code` (Language), `currency_code` (Curr.)
  - Form Route: `Customer/Details` (based on `dashboard/src/pages/form/advanced-form`)
  - Protected Card: **"Account Data"** (formerly "Repository Management") with top-right **Edit** button restricted to users belonging to team `user_teams.title_key = "Customer-Service"` via `edit_customers` privilege.

---

## 1. Apparel Categories (taxonomy)

**Slug**: `apparel-categories`. **Menu**: "Apparel Categories" (under Apparel Catalog menu).

### Current backend state
- Table exists (`categories`, `category_tree` closure table). Zero rows.

### What's missing (backend)
- `ICategoryRepository` interface and implementation.
- Closure table `category_tree` maintenance on create/update.
- Seed data (`db/fixtures.ts`).

---

## 2. Payment & Fraud Review

**Slug**: `payment-fraud-review`. **Menu**: "Payment Fraud Review" (under Accounts menu).

### Current backend state — fully done
- `GET /api/admin/payment-fraud-reviews` (paginated).
- `POST /api/admin/payment-fraud-reviews/:id/review`.

---

## 3. Pro Seller Applications

**Slug**: `pro-seller-applications`. **Menu**: "Pro Seller Applications" (under Accounts menu).

---

## 4. Accounts -> Customers (`mobile-accounts`)

**Slug**: `mobile-accounts`. **Menu**: `Accounts` -> `Customers`.
Full specification available at [`dashboard/docs/feature_customers_dashboard.md`](file:///Users/nbarrera/projects/Docker/node-nginx-clean/dashboard/docs/feature_customers_dashboard.md).

---

## 5. Product Groups / Items (catalog moderation)

**Slug**: `apparel-catalog`. **Menu**: "Apparel Catalog" (under Apparel Catalog menu).
