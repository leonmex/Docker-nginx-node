# New Dashboard Sections: Blablarags Mobile Backend

Written as a build proposal for the Ant Design Pro admin dashboard, covering
the data/endpoints added in `server/db/migrations/0004_blablarags_catalog_and_profiles.sql`
and `server/src/routes/{accounts,mobileProfile,apparel,paymentFraudReviews}.ts`
(see `Flutter_Apps/blablaragsandrigs/project_migrate_endpoints_to_server_v1.md`
for the mobile API these back). Every section below follows the same
backend/frontend/test build order as `claude-add-new-section.md` — this doc
is the "Description" input for each of those five invocations, plus the
priority ordering and the backend gaps that block starting some of them.

No emojis anywhere, per repo convention.

---

## Priority order and why

1. **Apparel Categories (taxonomy)** — blocking. Every apparel upload today
   silently produces `predicted_category_id: null` because the `categories`
   table has never been seeded and no admin route exists to populate it.
   This isn't a "nice to have dashboard CRUD" — without it, the taxonomy
   feature of the mobile app doesn't work at all yet.
2. **Payment & Fraud Review** — cheapest win. The backend (repository +
   routes) is already 100% built and tested; this is frontend-only work.
3. **Pro Seller Applications** — blocking a dead-end feature. `GET /api/me`
   hardcodes `sectionAccess.proSeller = 'viewOnly'`, meaning the ONLY
   legitimate path to `is_pro_seller = true` is an admin action — but no
   such action exists anywhere yet. Needs a small schema addition before the
   dashboard workflow makes sense (see its section below).
4. **Mobile Accounts** — read/moderate the end-user base.
5. **Product Groups / Items (catalog moderation)** — read-heavy, lowest
   urgency; nothing depends on it functioning for the mobile app itself.

---

## 1. Apparel Categories (taxonomy)

**Slug**: `apparel-categories`. **Menu**: "Apparel Categories" (or nested
under a new "Blablarags" parent menu, alongside Payment Fraud Review and
Pro Seller Applications below — recommend grouping all Blablarags sections
under one parent, separate from BlablaAI's `llm-performance`).

### Current backend state
- Table exists (`categories`, `category_tree` closure table), described in
  the migration. **Zero rows** — nothing has ever inserted into it.
- `PgApparelRepository.findCategoryByKeyPath(level, key, parentId)` is the
  only code that reads it, called internally by `createSingleItem`/
  `createGroup`/`updateGroup` to resolve a predicted category id. There is
  no write path at all — no route, no repository method.

### What's missing (backend)
- `ICategoryRepository` (new interface in `repositories/types.ts`):
  `listTree(): Promise<CategoryNode[]>` (or a nested-tree shape for the
  dashboard's tree control), `create(parentId, level, key, label)`,
  `update(id, label)`, `delete(id)` (should cascade-refuse or explicitly
  warn if `product_items.predicted_category_id` references it — `REFERENCES
  categories(id)` has no `ON DELETE` action specified today, i.e. `NO
  ACTION`/`RESTRICT`, so a delete with existing references will error, which
  is probably the right default; don't change it to `SET NULL` without a
  deliberate decision).
- `category_tree` closure-table maintenance: every `create` must insert the
  self-row (`ancestor=descendant=new id, depth=0`) plus one row per ancestor
  of the new parent (`depth = parent's depth + 1`). This is real logic that
  doesn't exist anywhere in the codebase yet — write it once here, unit-test
  it directly (a closure table is easy to get subtly wrong).
- Routes: `GET /api/admin/categories` (full tree), `POST
  /api/admin/categories`, `PUT /api/admin/categories/:id`, `DELETE
  /api/admin/categories/:id` — admin-gated, mirroring
  `paymentFraudReviews.ts`'s `requireAdmin` pattern exactly.
- **Seed data**: this is the actual unblocking work. Populate at least a
  first-pass taxonomy (e.g. level 0: Men/Women/Kids; level 1: Tops/Bottoms/
  Shoes/Outerwear/Accessories per gender; level 2: a handful of styles per
  category) via `db/fixtures.ts` + `db/seed.ts`/`db/reset.ts`, so
  `resolveCategoryId` actually resolves something in dev/test. The dashboard
  CRUD is how an admin maintains this ongoing, but ship the seed regardless
  of dashboard timing — mobile uploads are broken without it today.

### Dashboard frontend
- Tree view, not a flat ProTable — Ant Design's `Tree` or `TreeSelect` for
  navigating levels, with a side form (label + key) for create/edit. Enforce
  `level` client-side (a level-2 node can only be created under a level-1
  parent, etc.) but the backend must also enforce it — don't trust the
  client alone here (a malformed tree corrupts real product data).
- i18n: category `label` values are deliberately plain English right now
  (see the migration's own comment, referencing blablaragsandrigs' own
  deferred i18n gap for `Global.garmentCategories`) — don't add an i18n key
  column speculatively; match what already exists.

---

## 2. Payment & Fraud Review

**Slug**: `payment-fraud-review`. **Menu**: "Payment Fraud Review".

### Current backend state — fully done
- `GET /api/admin/payment-fraud-reviews` (paginated, admin-gated).
- `POST /api/admin/payment-fraud-reviews/:id/review` (`action`:
  `clear`/`confirm_fraud`/`block`, optional `notes`).
- Both routes tested in `test/api.integration.test.ts` (`describe('payment
  fraud review (admin)', ...)`.

### What's missing
Nothing backend-side. This is a pure frontend build, and the fastest of the
five to ship — copy the shape of `llm-performance`'s "Pending Suggestions"
tab almost directly:
- ProTable listing `flaggedReason`, `riskScore`, `flaggedBy`, `flaggedAt`,
  and the associated account (the API currently returns `accountId` only —
  the dashboard will want the account's `username`/`email` joined in for
  display; either extend `PgPaymentFraudRepository.listPendingReviews` to
  join `mobile_accounts`, or have the dashboard resolve it via the Mobile
  Accounts section's detail endpoint once that exists (Section 4 below) —
  extending the join is simpler and avoids an N+1 client-side lookup).
- Row action opens a modal: action select (`clear`/`confirm fraud`/`block`)
  + notes textarea. On submit, `POST .../:id/review`; a 404 response means
  "already reviewed by someone else" (the repository's `WHERE status =
  'pending_review'` race guard) — surface that distinctly from a generic
  error, since it's a real, expected concurrent-admin scenario, not a bug.
- No create/delete here — this is a review queue, not a CRUD resource in
  the traditional sense. Nothing to seed either; it's empty until a fraud
  heuristic (not built — see the compliance memory) or an admin manually
  flags something.

### Note on the missing "flag" action
There is currently no way for an admin to flag an account in the first
place outside a fraud heuristic that doesn't exist yet. If manual flagging
by an admin (e.g., responding to a support ticket) is a real workflow,
that's a SIXTH small piece of backend work: `POST
/api/admin/payment-fraud-reviews` (admin-gated, calls
`IPaymentFraudRepository.flagAccount` with `flaggedBy: 'admin'`) plus a
"Flag account" button/form in this same dashboard page. Confirm whether
that's wanted before building it — it's cheap to add once decided.

---

## 3. Pro Seller Applications

**Slug**: `pro-seller-applications`. **Menu**: "Pro Seller Applications".

### Current backend state
- `user_pro_seller` table: `is_pro_seller`, `business_name`, `vat_number`,
  `registration_number`, `sales_last_30_days`, `badge_level`. Seeded to
  defaults (`is_pro_seller = false`) for every new account.
- `GET /api/me` returns this section with `sectionAccess.proSeller =
  'viewOnly'` hardcoded — the mobile app can never write to it.

### The gap that needs a decision before building this
There is no "application" concept in the schema today — just a flat
boolean. For a real approval workflow you need to distinguish "hasn't
applied" / "applied, pending" / "approved" / "rejected", plus capture
whatever the user submitted (business name, VAT number) BEFORE an admin
approves it, since right now those columns only get values if something
writes them directly (nothing does).

Two ways to close this gap — pick one before starting the dashboard build:
- **(a) Add an `application_status` column** to `user_pro_seller`
  (`'none' | 'pending' | 'approved' | 'rejected'`, default `'none'`), and a
  new mobile-facing endpoint (`POST /api/me/pro-seller-application`) that
  lets a user submit `business_name`/`vat_number`/`registration_number` and
  sets `application_status = 'pending'`. Simpler, reuses the existing table.
- **(b) A separate `pro_seller_applications` table** (event-log style, like
  `payment_fraud_reviews`) if you want to preserve a history of every
  application/resubmission rather than overwriting one row. More correct if
  rejections-then-reapplications are expected to be common.

Recommend (a) for a first pass — it mirrors the existing 1-to-1 sub-table
pattern and is a smaller migration; move to (b) only if the product actually
needs an audit trail of past applications.

### Backend work (assuming option a)
- Migration: `ALTER TABLE user_pro_seller ADD COLUMN application_status
  VARCHAR(16) NOT NULL DEFAULT 'none'`.
- New mobile route: `POST /api/me/pro-seller-application` (JWT-gated, sets
  the submitted fields + `application_status = 'pending'`).
- New admin routes: `GET /api/admin/pro-seller-applications` (filter
  `application_status = 'pending'`, mirrors the fraud-review list shape),
  `POST /api/admin/pro-seller-applications/:accountId/review` (`approve` ->
  `is_pro_seller = true, application_status = 'approved', badge_level = ...`;
  `reject` -> `application_status = 'rejected'`).

### Dashboard frontend
Same review-queue pattern as Payment Fraud Review — ProTable of pending
applications (business name, VAT number, account) + approve/reject action.
Genuinely a near-copy of Section 2's page once the backend above exists.

---

## 4. Mobile Accounts

**Slug**: `mobile-accounts`. **Menu**: "Mobile Accounts".

### Current backend state
- `mobile_accounts` + the eight 1-to-1 profile sub-tables + `user_addresses`
  exist and are fully populated by the registration/verification flow.
- Every existing route (`GET /api/me`, apparel routes) is **self-scoped**
  via the JWT (`req.mobileAccountId`) — there is no admin-facing "look up
  any account" capability anywhere.

### What's missing (backend)
- `IMobileAccountAdminRepository` (or extend `IMobileAccountRepository`
  carefully — probably a separate interface, since admin listing/search
  needs pagination + filtering that the mobile-facing interface has no
  reason to support): `listAccounts(filter, page, pageSize)`,
  `findAccountDetail(id)` (the same aggregate `PgMobileProfileRepository.
  findProfile` already assembles — reuse it rather than duplicating the
  7-way join).
- Routes: `GET /api/admin/mobile-accounts` (search by username/email),
  `GET /api/admin/mobile-accounts/:id` (full profile aggregate — SECURITY:
  same masking rule as `GET /api/me` applies, payment fields must stay
  server-side-decrypted-on-demand only, never cached, and this admin route
  needs its own justification/audit-logging given it exposes the SAME
  sensitive payment data `GET /api/me` does, just for an arbitrary account —
  worth extra scrutiny before shipping, see
  [[payment-data-compliance-and-fraud-review]]).
- **Missing account-status concept**: there is no `status`/`suspended`
  column on `mobile_accounts` at all. If moderation needs to disable a
  bad-actor account, that's a migration addition (`status VARCHAR(16) NOT
  NULL DEFAULT 'active'` — `'active' | 'suspended' | 'deleted'`) plus a
  check in the JWT preHandler (`authenticateMobileJwt` in `routes/
  accounts.ts`) so a suspended account's existing tokens stop working, not
  just future logins. Decide whether this is in scope before starting.

### Dashboard frontend
- List page: ProTable, search by username/email, columns for `memberSince`,
  `emailVerified`, `isVerified` (trust badge), `isProSeller`.
- Detail page/drawer: read-only render of the full profile aggregate (reuse
  the mobile app's own section grouping — public profile, shipping,
  personalization, notifications, privacy — as tabs), EXCLUDING the payment
  section unless a specific justified admin workflow needs it (default to
  not showing IBAN/card details in a general account browser at all, even
  masked — that's what Section 3's fraud-review flow is for).
- Actions: toggle `is_verified` (trust badge) is a reasonable, low-risk
  first action to ship. Account suspension depends on the schema decision
  above.

---

## 5. Product Groups / Items (catalog moderation)

**Slug**: `apparel-catalog`. **Menu**: "Apparel Catalog" (or "Listings").

### Current backend state
- `product_groups`/`product_items`/`item_images` fully populated by the
  mobile upload flow. All existing routes (`POST/PUT/DELETE
  /api/v1/apparel/groups/...`) are account-owner-scoped only.

### What's missing (backend)
- Admin-scoped read routes: `GET /api/admin/product-groups` (search across
  ALL accounts — by account, category, status, date range),
  `GET /api/admin/product-groups/:id` (full detail with items + images).
- A moderation action: `PATCH /api/admin/product-items/:id` to force
  `item_status = 'hidden'` (content takedown) — the only admin write this
  section plausibly needs; full edit/delete of someone else's listing is
  probably NOT wanted (that's a seller-owned action, not an admin one).
- Note the existing `updateGroup` design limitation carried over from the
  mobile routes: it's a full delete+reinsert, so item ids are not stable
  across a mobile-side edit. Irrelevant for a READ-ONLY admin browse, but
  relevant if this section ever needs to reference an item by id across
  admin sessions (e.g., a saved moderation note) — don't build anything
  that assumes an item's id is durable without checking this first.

### Dashboard frontend
- Lowest priority of the five — read-only ProTable + detail drawer showing
  images, predictions vs. user overrides, price/currency, status. A single
  "Hide listing" action button covers the realistic moderation need; don't
  build more CRUD surface than that without a concrete requirement driving
  it (per this project's own "don't design for hypothetical future
  requirements" convention).

---

## Summary table

| Section | Backend work needed | Frontend work | Blocking? |
|---|---|---|---|
| Apparel Categories | Repository + admin routes + closure-table logic + **seed data** | Tree CRUD | Yes — mobile uploads produce null categories without it |
| Payment & Fraud Review | None (done) | ProTable + review modal | No |
| Pro Seller Applications | Schema decision + migration + 3 routes | Review-queue ProTable | Only for that one feature |
| Mobile Accounts | Admin list/detail routes + reuse profile aggregate | List + read-only detail | No |
| Product Groups/Items | Admin list/detail + one moderation action | Read-only ProTable + detail | No |

Recommend building in the priority order at the top of this document, not
this table's order — Categories first because it's the one thing actually
broken today, Payment Fraud Review second because it's free (backend
already shipped).
