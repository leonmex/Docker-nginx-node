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
