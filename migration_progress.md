# Migration Progress — Mock to PostgreSQL + Fastify Backend

Tracking log for the **Database-First** modernization (`CLAUDE-DATABASE-FIRST-STEP.md`).
Last updated: **2026-07-18**.

No emojis are used in this document (project rule).

## Status at a glance

| Milestone | Scope | Status |
|-----------|-------|--------|
| 1 | Database setup, schema, seeding, connection abstractions, tests | Done |
| 2 | Repositories, cache-aside layer, observability, Fastify API endpoints | Done |
| 3 | `server` container running Fastify + nginx `/api/` proxy | Done |
| 4 | Disable Umi mocks, security hardening, finalize this log | Done |

> Observability (added mid-Milestone-2 per requirement): a vendor-agnostic
> `ILogger` (Section 3D) with a `pino` implementation backs all app code — no
> `console.*`. Logs are structured JSON carrying `service`, `pid`, `hostname`, and
> per-request `reqId`, ready to feed any collector (OTel/Datadog/Loki/stdout).
> Output destination is env-configurable: `LOG_OUTPUT` (stdout|file|both),
> `LOG_DIR`, `LOG_FILE`.

Everything runs container-first — no host `npm install`. Tooling runs via
`docker compose run --rm server npm run <script>`.

---

## Milestone 1 — Done

### Database schema (`server/db/schema.sql`)
| Table | Source mock | Backs endpoint | Status |
|-------|-------------|----------------|--------|
| `users` | `dashboard/mock/utils.ts` (`defaultUser`) | `POST /api/login/account`, `GET /api/currentUser` | done |
| `user_tags` | `defaultUser.tags` | `GET /api/currentUser` | done |
| `dashboard_notices` | `dashboard/mock/notices.ts` (12 rows) | `GET /api/notices` | done |
| `fake_list` | `dashboard/mock/user.ts` (raw `GET /api/users` array, 3 rows) | `GET /api/users` | done |
| `dashboard_tags` | `dashboard/src/pages/dashboard/monitor/_mock.ts` | `GET /api/tags` | done (Milestone 4) |

### Infrastructure (`docker-compose.yml`)
- `redis` (7-alpine), reachable in-network as `redis://redis:6379`.
- `dbPostgres` pinned to `postgres:18.4`, bound to `127.0.0.1` (not public).
- `server` dev service (`node:22-alpine`) with named volume `server_node_modules` and runtime `npm install` (mirrors `webapp`).
- `.env` extended with `REDIS_URL`, `USE_CACHE`, `CACHE_PROVIDER`.

### Backend foundation (`server/`)
- TS project: `package.json`, `tsconfig.json` (path aliases `@/*`, `@db/*`, `@test/*`), `biome.json`, `vitest.config.ts`.
- `src/config.ts` — pure `process.env`; connection URLs assembled from parts (host=`localhost`, container=`dbPostgres`/`redis`).
- `src/core/IDatabase.ts` + `src/core/PgConnectionManager.ts` — read/write splitting (master `write` / replica `read` with single-node fallback) and `withTransaction` and `withoutTransaction` (autocommit/DDL).
- `db/fixtures.ts` — mock data extracted into `server/` (DB is now the source of truth).
- `db/seed.ts` — DDL via `withoutTransaction`, data via `withTransaction`, bcrypt-hashed passwords, idempotent (TRUNCATE + reload).
- `db/connection.ts` — `npm run db:check` health probe.

---

## Milestone 2 — Repositories, cache, API — Done
- [x] Repository interfaces: `IUserRepository`, `INoticeRepository`, `IFakeListRepository`, `ITagRepository` (`src/repositories/types.ts`).
- [x] Postgres implementations (reads -> `db.read`): `PgUserRepository`, `PgNoticeRepository`, `PgFakeListRepository`, `PgTagRepository`.
- [x] `ICacheManager` (`get/set/delete/flush`) + `RedisCacheManager` (graceful degradation) + `NoopCacheManager`; factory honors `USE_CACHE` / `CACHE_PROVIDER`.
- [x] Cache-aside decorators: `CachedUserRepository` (profiles cached, credentials never), `CachedNoticeRepository`, `CachedFakeListRepository`, `CachedTagRepository` (+ `invalidate*` hooks for future writes).
- [x] Vendor-agnostic logging: `ILogger` + `pino` (`src/core/logger.ts`); retrofitted `seed.ts`/`connection.ts`.
- [x] Fastify v5.8 server (`src/index.ts`, `src/app.ts`) + route plugins:
  - [x] `POST /api/login/account` (bcrypt verify -> signed session cookie)
  - [x] `POST /api/login/outLogin` (clears cookie)
  - [x] `GET /api/currentUser` (reads cookie -> profile, 401 when absent)
  - [x] `GET /api/users`
  - [x] `GET /api/notices`
  - [x] `GET /api/tags` (Monitor word cloud; added in Milestone 4 after a 404 was observed)
  - [x] `GET /api/health`
- [x] Tests: unit (mocked cache/repos), repository integration, API integration via `fastify.inject`. TSC clean.

## Milestone 3 — Docker & proxy — Done
- [x] `server` container runs Fastify (`npm start`), `expose: 5000` (internal only, no host port).
- [x] Container env sets `HOST=0.0.0.0` / `PORT=5000` / `DB_HOST=dbPostgres` / `REDIS_HOST=redis`.
- [x] `proxy` `depends_on: server` (nginx resolves the upstream at startup); removed unused host port `6277`.
- [x] webapp debugger port hardened to `127.0.0.1:9229` (off `0.0.0.0`).
- [x] `nginx/default.conf`: `location /api/ -> http://server:5000` added to the `:80` and `:3000` servers; removed the `6277` / MCP-SSE server block.
- [x] Verified end-to-end through nginx (`http://localhost/api/*`): health, notices, users, tags, and the full login -> cookie -> currentUser (200) / no-cookie (401) flow.

> Note: because nginx matches the `/api/` prefix to `server:5000`, API calls bypass
> the Umi mock middleware at the proxy layer already. Milestone 4 still turns the
> mocks off in Umi itself (run `dev` not `start`) for cleanliness.

## Milestone 4 — Frontend cutover, security, logs — Done
- [x] `GET /api/tags` implemented database-first (was returning 404 from the Monitor page).
- [x] Disabled Umi mock middleware: `webapp` now runs `npm run dev` (`MOCK=none`); `/api/*` is served by the real backend via nginx.
- [x] Security: Google Analytics block commented out in `dashboard/config/config.ts` (kept for reference, disabled).
- [x] Security: chatbot `CHAT_API_URL` default repointed from `api.x.ant.design` to the local `/api/chat` (set `CHAT_API_URL` for a real gateway).
- [x] Verified end-to-end after cutover: dashboard root 200; `/api/health`, `/api/notices`, `/api/users`, `/api/tags` served by the backend (tags return the English seed, proving the mock is bypassed).
- [x] This log kept current.

### Known remaining 404s (deferred, not blocking)
- `GET /api/monitor/map-geo` and `GET /api/monitor/map-grid` (Monitor page map) — large static GeoJSON; serve as static assets or a dedicated route in a later pass.
- `POST/GET /api/chat` — chatbot now points at the local `/api/chat`; no backend handler yet (intentionally no external call).
- `GET /api/fake_list`, `GET/POST /api/rule` — card list / rule CRUD still mock-shaped; transition when those pages are needed.

### Remaining `dashboard/mock/` (and co-located `_mock.ts`) to transition
| File | Endpoint(s) | Plan |
|------|-------------|------|
| `mock/user.ts` | login / currentUser / users | Done (backed by `users`, `user_tags`, `fake_list`) |
| `mock/notices.ts` | `GET /api/notices` | Done (backed by `dashboard_notices`) |
| `pages/dashboard/monitor/_mock.ts` (tags) | `GET /api/tags` | Done (backed by `dashboard_tags`) |
| `pages/dashboard/monitor/_mock.ts` (map) | `GET /api/monitor/map-geo`, `/api/monitor/map-grid` | Later — large static geo datasets |
| `mock/fakeList.ts` | `GET /api/fake_list` (card list) | Later — dynamically generated; needs a generated/seeded table |
| `mock/listTableList.ts` | `GET/POST /api/rule` | Later — dynamically generated; full CRUD table |
| `mock/route.ts` | dynamic routes | Evaluate; may stay static |

---

## Operational tooling — migration runner (`dev:executemigration`)

Spec: `README.md` §3 "Database Migrations". Implemented in
`server/db/executeMigration.ts`.

- Tracks applied files in a new `schema_migrations(filename PK, applied_at)`
  table (also added to `schema.sql`, so fresh databases start with it).
- On each run: reads `db/migrations/*.sql` in filename order, skips any
  already recorded in `schema_migrations`, and runs the rest — each file
  inside its own transaction, recording it in the same transaction so a
  failure never leaves a half-applied file marked as done.
- `npm run dev:executemigration -- --backup` dumps every `public` schema
  table to a timestamped JSON file under `server/db/backups/` (gitignored —
  contains raw row data, including password hashes) before running anything.
- Picked up `db/migrations/0005_user_teams_privileges.sql` (new
  `user_teams_privileges` table — team/section/action permission grid,
  seeded with baseline Customer-Service rows) as its first real pending
  migration; folded into `schema.sql` per the existing convention.
- Verified against the running dev DB: `--backup` run applied 0001-0005
  cleanly (0001-0004 are idempotent re-runs, matching their existing
  "safe to re-run" design), a second run correctly reported nothing pending,
  and `db:seed` still applies the updated `schema.sql` without error.

---

## Operational tooling — interactive reset & restore (`db:reset`)

Spec: `CLAUDE-DATABASE-MIGRATION-V1.md`. Implemented in `server/db/reset.ts`
(`npm run db:reset`). Uses Node 22 `readline/promises` (no new deps).

- Option 1 — Full reset & restore: re-applies schema, truncates + reseeds all
  tables, flushes Redis (reuses `seed()` + `cache.flush()`).
- Option 2 — Table-specific reset: truncate + restore selected table(s), FK-aware
  (resetting `users` also restores `user_tags`), flushes cache.
- Option 3 — ID-range restore: delete + reinsert fixtures whose serial PK falls in
  `[startId, endId]` (tables `users`, `user_tags`, `fake_list`, `dashboard_tags`),
  invalidating the affected cache keys (`user:profile:<userid>`, `fakelist:all`,
  `tags:all`).

The spec omitted tests; core operations are factored into exported functions
(`fullReset`, `resetTables`, `restoreIdRange`) with the readline CLI as a thin
wrapper. Covered by `server/test/reset.integration.test.ts` (6 tests: full reset +
flush, table-specific reset isolation, FK-cascade restore, ID-range restore with
cache-key invalidation, invalid-range rejection). Cache assertions use a spy cache.
All transactional via `db.withTransaction`; DB/Redis disconnect on exit/error.
Total server tests: 42.

---

## Internationalization (i18n) — EN / DE / ES

Guide: `CLAUDE-I18N-GUIDE.md` (how to convert pages + build new sections with i18n).

Root cause found on `/dashboard/analysis`: user-visible text was hardcoded Chinese
literals in the components (not i18n, not from the DB), and the page's data came
from an un-migrated mock. Reseeding/cache-clear had no effect because the page
never touched the backend.

- [x] Pilot: `src/pages/dashboard/analysis` fully internationalized — all literals
      moved to `pages.analysis.*` keys in `en-US`, `de-DE`, `es-ES` (`useIntl` +
      `formatMessage` with `defaultMessage`). Dashboard TSC + Biome pass.
- [x] Migrated its data endpoint `GET /api/fake_analysis_chart_data` to the Fastify
      backend (`StaticAnalyticsProvider` + `CachedAnalyticsProvider`, English/
      deterministic data) — was 404 with mocks off; now 200 via nginx.
- [x] `src/pages/dashboard/monitor` UI internationalized (`pages.monitor.*` in all
      three locales; `index.tsx`, `ActiveChart`, `Map`). Dashboard TSC + Biome pass.
      Note: the map's data endpoints (`/api/monitor/map-geo`, `/api/monitor/map-grid`)
      and their large zh-CN GeoJSON dataset remain deferred (separate from UI text).
- [x] `src/pages/account/settings` and `src/pages/account/center` (+ shared
      `src/components/ArticleListContent`) fully internationalized —
      `pages.account.settings.*` / `pages.account.center.*` /
      `component.articleListContent.*` in `en-US`, `de-DE`, `es-ES`. See "New
      section: Account (settings/center)" below for the accompanying backend
      migration. Dashboard TSC + Biome + `antd lint` pass; zero Chinese in
      `src/pages/account`.
- [ ] Remaining pages with hardcoded text (~50 files): workplace and others.
      Enumerate with `grep -rIl "[一-鿿]" src/pages | sort` and convert per the guide.
      Track here as they are done.
- [ ] New full-stack sections: use `claude-add-new-section.md` (agent prompt that
      builds menu + form + charts + sub-sections + backend + tests + migration from
      just a slug, menu label, and functionality description).

Server tests: 43 passing (added analytics endpoint test).

---

## New section: BlablaAI > Dashboard (llm-performance)

Built from `claude-add-new-section.md` (inputs from `dashboard/DASHBOARD-IDEAS-LLMLBLBLA_V1_gemini.md`).
First section created with i18n + DB + tests from scratch.

- Migration `server/db/migrations/0001_llm_performance.sql` + idempotent DDL in
  `schema.sql`: `user_action_logs`, `pending_category_suggestions` (Option A loose
  event log; added `confidence_score` + `is_flagged_for_retraining`). Seeded via
  `db:seed` (37 action logs, 8 suggestions) and covered by `db:reset` (all three modes).
- Backend: `ILlmPerformanceRepository` + `PgLlmPerformanceRepository` (reads ->
  replica, writes -> master) + `CachedLlmPerformanceRepository` (caches
  `llm-performance:metrics`, invalidates on write). Routes (`src/routes/llm-performance.ts`):
  - `GET /api/llm-performance/metrics` (KPIs, action-flow, top overridden)
  - `GET /api/llm-performance/suggestions` (region/status filter, paginated)
  - `POST /api/admin/llm-performance/suggestions/:id/review` (admin: approve/reject/merge)
  - `GET /api/llm-performance/logs` (override/misclassification log)
  - `POST /api/admin/llm-performance/logs/:id/flag` (admin: flag for retraining)
  Write actions are admin-gated (401 without session, 403 for non-admins) and
  live under `/api/admin/` (2026-07-19 rename) so nginx's admin-traffic
  rate-limit exemption covers them — every admin-gated route should register
  under this prefix going forward, see
  `proxy_hardening_and_public_access_proposal.md` §2.1.
- Frontend: `dashboard/src/pages/llm-performance` (4 KPI cards + 3 tabs: Overview
  charts, Pending Suggestions ProTable, Override Log ProTable). Action buttons shown
  only to admins (`currentUser.access === 'admin'`). Route `BlablaAI > Dashboard`
  (`/blabla-ai/dashboard`); `menu.blabla-ai*` + `pages.llmPerformance.*` in EN/DE/ES.
- Tests: repo integration (`test/llm-performance.repo.integration.test.ts`), API
  inject cases + admin-gating in `test/api.integration.test.ts`, cache unit tests in
  `test/cache.test.ts`. **Server: 59 tests passing.**
- Gates passed: server `tsc`+`test`; dashboard `tsc`, Biome, `antd lint`, `build`;
  zero Chinese in the section. Verified end-to-end via nginx.

---

## New section: Accounts > Customers

Built from `dashboard/docs/feature_customers_dashboard.md` (item 4 of the
5-section proposal in `new_sections_for_dashboard.md`). Read/moderate the
mobile app's end-user base — deliberately excludes payment data (IBAN/card),
which stays behind the separate Payment & Fraud Review flow per that
proposal's flag.

- **Access control**: new team-based privilege table
  (`db/migrations/0005_user_teams_privileges.sql`: `user_teams_privileges`,
  keyed `team_title_key`/`section_key`/`action_key`), a finer-grained
  alternative to the coarse `users.access === 'admin'` flag `requireAdmin`
  (llm-performance, payment-fraud-review) uses. Seeded: `Customer-Service`
  team gets `customers.view` and `account_data.edit_customers`; the seeded
  `admin` login is on that team, `user` deliberately is not, so tests have a
  ready-made "no privilege" persona (`db/fixtures.ts`). `IPrivilegeRepository`
  / `PgPrivilegeRepository.hasPrivilege` — not cache-wrapped, a revoked grant
  must take effect on the next request.
- **Backend**: `src/domain/customer.types.ts` (`CustomerListItem`,
  `CustomerDetail` with a route-computed `canEdit`, `CustomerEditableFields`
  — identity columns username/user_id/email are permanently excluded from
  edits, enforced by the route schema's `additionalProperties: false`).
  `ICustomerRepository` / `PgCustomerRepository` joins `mobile_accounts` +
  `user_profiles` (no cache wrapper — admin/support tool, current data over
  read latency). Routes (`src/routes/customers.ts`, all under
  `/api/admin/mobile-accounts`):
  - `GET /api/admin/mobile-accounts` (list, filterable by id/userId/username/
    email/emailVerified/isVerified/memberSince range/languageCode/
    currencyCode, paginated) — requires `customers.view`.
  - `GET /api/admin/mobile-accounts/:id` (detail + `canEdit`) — requires
    `customers.view`.
  - `PATCH /api/admin/mobile-accounts/:id` (emailVerified/isVerified/
    languageCode/currencyCode only) — requires the stricter
    `account_data.edit_customers`, re-checked here regardless of an earlier
    GET's `canEdit`.
- **Frontend**: `dashboard/src/pages/accounts/customers` — `index.tsx` (Accounts
  -> Customers ProTable matching the spec's column mapping, explicit
  pagination with a 10/20/50/100 size changer), `detail.tsx` (Customer/Details
  form; based on `form/advanced-form`'s Card layout, split into two cards —
  "Account Data" (`mobile_accounts` fields) and "Profile Settings"
  (`user_profiles` fields) — matching `PgCustomerRepository.update`'s own
  two independent UPDATE statements; each card has its own Edit/Save/Cancel.
  Identity fields (username/user_id/email) always read-only. Email/Account
  Verified are `ProFormRadio.Group` (button style), not a bare Switch — its
  readonly view falls back to pro-components' generic "open"/"close" text.
  Language/Currency are `ProFormSelect`s populated from `GET /api/languages`
  / `GET /api/currencies` (see the Admin -> Sys-Config entry below), not free
  text. Every card's edit affordance is gated on the GET/PATCH response's
  `canEdit` rather than a client-side role check — the PATCH route echoes
  `canEdit: true` too (it's trivially known there, since the route already
  required `account_data.edit_customers` to reach that point), fixing a bug
  where saving made the Edit button disappear (the dashboard replaces its
  whole customer object with the PATCH response, and a missing `canEdit`
  reads as false). New top-level `Accounts` menu (`config/routes.ts`) with
  `Customers` as its child item; `/accounts/customers/:id` is reachable but
  `hideInMenu`. i18n: `menu.accounts*` + `pages.accounts.customers.*` in
  EN/DE/ES.
- **Tests**: repo integration (`test/customers.repo.integration.test.ts` —
  list filters/pagination, findById/findByUsername/findByEmail, partial
  update semantics), API inject cases in `test/api.integration.test.ts`
  (401/403 privilege gating for GET and PATCH separately, since they require
  different grants; detail 404; PATCH schema rejects identity-field edits and
  echoes `canEdit`).
- Gates: server `tsc` + `test` passed once (before the Sys-Config work below
  landed — needs a re-run); dashboard `tsc` passed (205 files, no issues) and
  scoped Biome passed (`biome check src/pages/accounts src/locales` — 29
  files, no issues). `antd lint` not yet run. `npm run build` blocked by the
  `webapp` dev server holding the utoopack cache lock (same non-issue as the
  Account section's entry below) — not re-attempted since the dev server is
  what's actually serving the app for manual verification right now.

---

## New section: Admin -> Sys-Config (Languages, Currencies, Countries)

Grew out of two real bugs found while using the Customers section above: the
Language/Currency fields were free text with no validation against real data,
and saving Account Data or Profile Settings made the Edit button disappear
(fixed above). Scoped up per direct request into admin-managed reference data
with its own dashboard section, rather than a one-off hardcoded list.

- **Schema** (`db/migrations/0006_sys_config_languages_currencies.sql` +
  `schema.sql`): `languages` (code PK, `name` — a plain editable display
  string, NOT an i18n key like `countries`/`provinces`/`cities` use, since
  these rows are admin-CRUD content rather than static seed data — `is_active`,
  timestamps), `currencies` (code PK, `name`, `rate` NUMERIC(14,6) relative to
  base currency EUR = 1.000000 — reserved for future conversion calculations,
  nothing reads it yet; static placeholder seed values, not a live FX feed —
  `is_active`, timestamps), and `countries.default_language_code` (new FK ->
  `languages.code`). Seeded (`db/fixtures.ts`): languages en/de/es
  (reconstructing the app's 3 supported locales from the 4 seeded countries'
  primary language — ES/MX -> es, DE -> de, GB -> en); currencies EUR/GBP/MXN
  (matching the seeded countries; no USD, since no seeded country uses it).
  Delete is a soft `isActive` toggle everywhere, never a hard DELETE —
  `currency_code`/`language_code` are unconstrained free text elsewhere
  (`user_profiles`), so removing a row outright could silently orphan data.
  `db/seed.ts`/`db/reset.ts` wired: languages insert before countries (FK
  dependency), `resetTables`'s cascade-aware branch extended (truncating
  `languages` now cascades through `countries` -> `provinces`/`cities` too).
- **Backend**: `src/domain/sysConfig.types.ts` (`Language`, `Currency`,
  `CountryAdminItem` + their editable-field types).
  `ILanguageRepository`/`PgLanguageRepository`,
  `ICurrencyRepository`/`PgCurrencyRepository` (list/create/update; NUMERIC
  `rate` explicitly `Number()`-converted — pg returns it as a string, same
  driver behavior `PgCustomerRepository.list`'s `total` already had to work
  around), `ICountryAdminRepository`/`PgCountryAdminRepository` (list/update
  only — distinct from `IGeographicRepository`, which returns locale-translated
  `{id, name}` display options for the mobile/account address cascade; this
  exposes the raw `code`/`name_key`/`default_language_code` instead). None
  cache-wrapped (admin/support tool, current data over read latency — same
  rationale as Customers/Payment-Fraud-Review). Routes
  (`src/routes/sysConfig.ts`):
  - `GET /api/languages`, `GET /api/currencies` (`?includeInactive=true`) —
    open to any authenticated dashboard user, not admin-gated: the Customer
    Details selects and the Customers list filters both need to read these,
    and neither necessarily holds the admin flag (they only need
    `customers.view`/`account_data.edit_customers`). Exposing a handful of
    reference rows to any logged-in user is harmless — same posture as the
    existing `/api/geographic/*` routes.
  - `POST`/`PATCH /api/admin/languages(/:code)`,
    `POST`/`PATCH /api/admin/currencies(/:code)`,
    `GET`/`PATCH /api/admin/countries(/:code)` — all `requireAdmin`-gated
    (mirrors llm-performance/payment-fraud-review's coarse
    `users.access === 'admin'` check, not Customers' narrower team privilege
    — sys config affects the whole platform). Countries is list + edit only,
    no create/delete: provinces/cities cascade off it and expanding the
    geography set wasn't requested.
- **Frontend**: `dashboard/src/pages/admin/sys-config/currencies` (ProTable +
  one `ModalForm` handling both create and edit, an inline `Switch` per row
  for the active/inactive toggle) and
  `dashboard/src/pages/admin/sys-config/languages-countries` (two `Tabs`:
  Languages — same ModalForm/ProTable pattern as Currencies minus `rate`;
  Countries — list + edit-only ProTable, the edit modal's Default Language
  field is itself a `ProFormSelect` sourced from `GET /api/languages`). New
  `Admin -> Sys-Config` menu with `Currencies` / `Languages & Countries`
  children (`config/routes.ts`, under the existing `canAdmin`-gated `/admin`
  parent). i18n: `menu.admin.sys-config*` + `pages.sysConfig.*` in EN/DE/ES.
- **Tests**: repo integration
  (`test/sysConfig.repo.integration.test.ts` — active/inactive filtering,
  create/update for languages and currencies including the NUMERIC `rate`
  conversion, countries list/update, soft-delete-not-hard-delete assertion).
  API-level route tests (401/403/admin-gating, full CRUD flows) were drafted
  but not yet landed in `test/api.integration.test.ts` — left for a follow-up
  pass.
- Gates: not yet run — this section was built immediately after the Customers
  gate-check above; needs its own `tsc`/`test`/Biome/`antd lint`/`build` pass
  before it can be called done.

---

## New section: Account (settings/center)

Migrated `dashboard/src/pages/account/{settings,center}` off the legacy Express
mocks (`_mock.ts`, `dashboard/mock/utils.ts`) onto Postgres + Fastify, added a
lightweight backend i18n mechanism, and fully internationalized the pages'
previously-hardcoded Chinese UI text in the same pass. Built from
`implementation_plan-section-account.md` / `project-migrate-section-account.md`.

- **Backend i18n** (`server/src/core/i18n.ts`, new): a flat `I18nManager`
  dictionary per locale (`en`/`es`/`de`), no external i18n library. Any DB
  column holding translatable content stores a *key* (e.g. `country.ES`,
  `user.admin.signature`), resolved per-request via `resolveLocale(Accept-Language)`.
  Never throws on a missing key — falls back to the caller's `defaultMessage`
  or the key itself, mirroring the frontend's `useIntl` convention.
- **Schema** (`db/migrations/0003_account_section.sql` + `schema.sql`): new
  `countries`/`provinces`/`cities` (Spain, Germany, England, Mexico — 4
  countries, 12 provinces, 12 cities), `user_teams` (Center sidebar "team"
  list, replacing `getProjectNotice()`), `account_activity_items` (shared
  Articles/Projects/Applications feed, replacing the mock's random
  `fakeList(count)` generator with 30 deterministic seeded rows). `users`
  keeps its existing columns, but `signature`/`title`/`group_name`/
  `user_tags.label` now store translation keys, and `geographic` stores only
  `{ province: { key }, city: { key } }` — labels are resolved at read time
  via a join, not stored. The seeded admin/user profiles were reassigned from
  China (`浙江省`/`杭州市`) to Spain (`ES-MD`/`ES-MD-MAD`) since the target
  country list is ES/DE/GB/MX; no Chinese content remains in the seeds.
- **Repositories**: `IGeographicRepository` (`Pg`/`CachedGeographicRepository`,
  cache keyed `geo:{countries,provinces,cities}:<locale>:...`);
  `IAccountRepository` (`Pg`/`CachedAccountRepository` — `findDetail` reuses
  the injected `IUserRepository.findProfile` rather than duplicating the
  profile query; `listActivityItems` caches the full list per locale and lets
  the route slice by `count`). `IUserRepository.findProfile` gained a
  `locale` parameter; `CachedUserRepository`'s cache key became
  `user:profile:<userid>:<locale>` since content is now locale-dependent.
  New domain types live in `src/domain/geographic.types.ts` and
  `src/domain/account.types.ts` (kept out of the growing `domain/types.ts`
  per review feedback — a follow-up should split that file the same way).
- **Auth**: centralized `authenticateHandler` (`routes/auth.ts`), registered
  as `app.decorate('authenticate', ...)` on the *root* Fastify instance in
  `app.ts` (not inside a plugin — see Issue 9 in `learned_lessons.md` for why
  that placement matters) so both `routes/auth.ts` and `routes/users.ts` can
  gate routes with `{ preHandler: app.authenticate }`.
- **Routes**: `GET /api/accountSettingCurrentUser`, `GET /api/geographic/countries`,
  `GET /api/geographic/province?country=`, `GET /api/geographic/city/:province`,
  `GET /api/currentUserDetail`, `GET /api/fake_list_Detail?count=` — all
  gated, all locale-aware. `GET /api/currentUser` untouched behaviorally,
  just threads `locale` through to `findProfile`.
- **Frontend**: `settings/service.ts` gained `queryCountries()` and
  `queryProvince(country?)`; `settings/components/base.tsx`'s country
  `ProFormSelect` is now DB-backed and the province select is wrapped in
  `ProFormDependency` on `country` (mirrors the existing province -> city
  dependency). Deleted `settings/_mock.ts`, `center/_mock.ts`, and the
  unused `settings/geographic/{province,city}.json`.
- **i18n conversion**: all 10 hardcoded-Chinese files under
  `pages/account/**` plus the shared `components/ArticleListContent`
  converted to `useIntl`/`formatMessage`, keys in `pages.account.settings.*`,
  `pages.account.center.*`, `component.articleListContent.*` (EN/DE/ES). The
  Applications tab's Chinese-locale `万` (10k) number-abbreviation hack was
  removed in favor of the existing `formatNumber` utility, since it doesn't
  apply to any of this product's EN/DE/ES locales.
- **Tests**: `test/i18n.test.ts` (unit), `test/account.repo.integration.test.ts`
  (new — geographic + account repo reads), extended `test/api.integration.test.ts`
  (401 gating for all 6 new/extended routes, locale-translation assertions),
  updated `SeedCounts` assertions in `test/db.integration.test.ts` /
  `test/reset.integration.test.ts` (Issue 5 pattern) and cache-key assertions
  in `test/cache.test.ts` / `test/reset.integration.test.ts` (locale-scoped
  keys). **Server: 85 tests passing.**
- Gates passed: server `tsc`+`test` (85/85); dashboard `tsc`, Biome,
  `antd lint`; zero Chinese in `src/pages/account`. Verified end-to-end
  through nginx with `curl` (login, all 6 endpoints, en/es/de headers, 401
  without a cookie). Dashboard `npm run build` was not run — the `webapp`
  container was mid-dev-server at verification time and holds the utoopack
  build-cache lock (see Issue 10-style conflict; not a code issue).

---

## Production deployment trade-offs

These are deliberate dev-time shortcuts that must be revisited before shipping.

1. Read/write splitting and replication lag. The abstraction routes reads to a
   replica, but in dev the replica is the master (same pool), so the
   "INSERT-on-master visible on replica read" test passes only because there is no
   lag. With a real replica (`DB_REPLICA_HOST`), reads can be stale right after a
   write. Mitigate: read-after-write goes to master, or rely on the cache layer,
   or accept eventual consistency per endpoint.

2. `schema.sql` is not a migration system. `CREATE TABLE IF NOT EXISTS` has no
   versioning, no `ALTER`, no rollback. The seed TRUNCATEs and reloads — fine for
   dev/first load, destructive in production. Adopt a real migration tool
   (node-pg-migrate / drizzle-kit / prisma migrate) and make seeds idempotent
   (`ON CONFLICT`) before prod.

3. bcryptjs over native bcrypt/argon2id. Pure-JS bcryptjs avoids native builds in
   alpine but is slower. For real auth load, prefer `argon2` (needs a build
   toolchain in the image) and raise the cost factor (currently `SALT_ROUNDS=10`).

4. Runtime `npm install` + `tsx`. Dev favors fast iteration (install at container
   start, run TS directly). Production needs a multi-stage build: `npm ci` against
   a committed `package-lock.json`, then either compile to JS or run a pinned
   `tsx`. No lockfile is committed yet — reproducibility risk.

5. Path aliases need build-time resolution. `@/*` aliases are clean and work under
   `tsx`/vitest, but `tsc` does not rewrite them in compiled output. The prod build
   must use a bundler or `tsc-alias`, otherwise compiled JS fails to resolve `@/...`.

6. Secrets live in `.env`. Dev DB credentials are committed for convenience.
   Production must pull `POSTGRES_*`, `DATABASE_URL`, `REDIS_URL`, `COOKIE_SECRET`
   from a secrets manager and never commit them.

7. Host-exposed data ports. Postgres is bound to `127.0.0.1` (better than
   `0.0.0.0`) and Redis to loopback; in production neither should be host-exposed
   at all — internal network only (`expose`).

8. Connection pool defaults. Using `pg` defaults (max 10 per pool). Production
   needs tuned pool sizes and likely PgBouncer in front of Postgres.

9. Seed data is still Chinese (zh-CN) in places. Notices carry the original
   mock content, which conflicts with the EN/DE/ES-only product constraint (see
   `dashboard-project.md`). Localize or replace remaining seed content before
   release. (`dashboard_tags` and the account section's `users`/`user_tags`/
   `user_teams`/`account_activity_items` seeds are now neutral/key-based and
   translated into EN/DE/ES — see "New section: Account (settings/center)".)

10. Tests are destructive against the dev DB. Integration tests TRUNCATE the
    `test` database. CI must use an ephemeral/throwaway DB, not a shared one.

11. `fake_list` naming. The table backs `GET /api/users` but is named after the
    `fakeList.ts` mock — minor naming debt.

12. Integration tests share one DB and run serially. `fileParallelism:false` is
    set because the integration files re-seed the same database (TRUNCATE) and
    concurrent `CREATE TABLE IF NOT EXISTS` hit a Postgres catalog race
    (`pg_type_typname_nsp_index`). CI should give each run an isolated DB (or a
    schema-per-worker) so tests can parallelize — another nudge toward a real
    migration tool over `IF NOT EXISTS`.

13. Session = signed cookie, not JWT. Auth uses a `@fastify/cookie` signed,
    httpOnly cookie holding the `userid`. Simple and fine behind nginx same-origin,
    but for multi-service/stateless scaling consider JWT or a shared session store.
    `sameSite=lax` + `secure` must be revisited for the production domain/TLS.

14. `mobile` login type not implemented. The mock auto-succeeded mobile/captcha
    logins; the real API only does account (username/password). The dashboard's
    mobile login tab will not work until a real OTP/captcha flow is added.

15. Cache invalidation is wired but unexercised. Decorators expose `invalidate*()`,
    but none of the read-only endpoints write, so nothing calls them yet. When
    write endpoints land, they must invalidate on write.

16. `pino-pretty` is dev-only. Pretty logs use a worker-thread transport (disabled
    in tests/prod, which emit plain JSON). Logger fan-out uses `pino.multistream`
    (not `transport({targets})`, which silently dropped file writes when mixing
    pretty stdout + a JSON file). Prod ships JSON to stdout for the collector.
