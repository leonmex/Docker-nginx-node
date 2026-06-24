# Migration Progress — Mock to PostgreSQL + Fastify Backend

Tracking log for the **Database-First** modernization (`CLAUDE-DATABASE-FIRST-STEP.md`).
Last updated: **2026-06-19**.

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
  - `POST /api/llm-performance/suggestions/:id/review` (admin: approve/reject/merge)
  - `GET /api/llm-performance/logs` (override/misclassification log)
  - `POST /api/llm-performance/logs/:id/flag` (admin: flag for retraining)
  Write actions are admin-gated (401 without session, 403 for non-admins).
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

9. Seed data is still Chinese (zh-CN). Notices, signatures, etc. carry the original
   mock content, which conflicts with the EN/DE/ES-only product constraint (see
   `dashboard-project.md`). Localize or replace seed content before release.
   (The new `dashboard_tags` seed uses neutral English terms.)

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
