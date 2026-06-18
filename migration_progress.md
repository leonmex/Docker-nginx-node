# Migration Progress — Mock → PostgreSQL + Fastify Backend

Tracking log for the **Database-First** modernization (`CLAUDE-DATABASE-FIRST-STEP.md`).
Last updated: **2026-06-18**.

## Status at a glance

| Milestone | Scope | Status |
|-----------|-------|--------|
| **1** | Database setup, schema, seeding, connection abstractions, tests | ✅ **Done** |
| 2 | Repositories, cache-aside layer, Fastify API endpoints | ⬜ Pending |
| 3 | `server` container wired into the app + nginx `/api/` proxy | 🟡 Partial (dev container added; nginx/app start pending) |
| 4 | Disable Umi mocks, finalize this progress log | ⬜ Pending |

Everything runs **container-first** — no host `npm install`. Tooling runs via
`docker compose run --rm server npm run <script>`.

---

## Milestone 1 — Done ✅

### Database schema (`server/db/schema.sql`)
| Table | Source mock | Backs endpoint | Status |
|-------|-------------|----------------|--------|
| `users` | `dashboard/mock/utils.ts` (`defaultUser`) | `POST /api/login/account`, `GET /api/currentUser` | ✅ |
| `user_tags` | `defaultUser.tags` | `GET /api/currentUser` | ✅ |
| `dashboard_notices` | `dashboard/mock/notices.ts` (12 rows) | `GET /api/notices` | ✅ |
| `fake_list` | `dashboard/mock/user.ts` (raw `GET /api/users` array, 3 rows) | `GET /api/users` | ✅ |

### Infrastructure (`docker-compose.yml`)
- ✅ `redis` (7-alpine), reachable in-network as `redis://redis:6379`.
- ✅ `dbPostgres` pinned to `postgres:18.4`, bound to `127.0.0.1` (not public).
- ✅ `server` dev service (`node:22-alpine`) with named volume `server_node_modules` and runtime `npm install` (mirrors `webapp`).
- ✅ `.env` extended with `REDIS_URL`, `USE_CACHE`, `CACHE_PROVIDER`.

### Backend foundation (`server/`)
- ✅ TS project: `package.json`, `tsconfig.json` (path aliases `@/*`, `@db/*`, `@test/*`), `biome.json`, `vitest.config.ts`.
- ✅ `src/config.ts` — pure `process.env`; connection URLs assembled from parts (host=`localhost`, container=`dbPostgres`/`redis`).
- ✅ `src/core/IDatabase.ts` + `src/core/PgConnectionManager.ts` — **read/write splitting** (master `write` / replica `read` with single-node fallback) and `withTransaction` **and** `withoutTransaction` (autocommit/DDL).
- ✅ `db/fixtures.ts` — mock data extracted into `server/` (DB is now the source of truth).
- ✅ `db/seed.ts` — DDL via `withoutTransaction`, data via `withTransaction`, bcrypt-hashed passwords, idempotent (TRUNCATE + reload).
- ✅ `db/connection.ts` — `npm run db:check` health probe.

### Tests (14 passing — `npm test`)
- ✅ `test/fixtures.test.ts` — pure unit (no infra).
- ✅ `test/db.integration.test.ts` — connectivity, seed row counts, idempotency, bcrypt verification, FK join, and **read-via-replica / INSERT·UPDATE·DELETE-via-master** routing. Runtime-skips when DB/Redis are unreachable.

### Verified
```
db:check → PostgreSQL 18.4 OK · Redis PONG
npm test → 14/14 passing
db:seed  → { users: 2, userTags: 12, notices: 12, fakeList: 3 }  (confirmed via psql)
```

---

## Pending milestones

### Milestone 2 — Repositories, cache, API
- [ ] Repository interfaces: `IUserRepository`, `INoticeRepository`, `IFakeListRepository`.
- [ ] Postgres implementations (reads → `db.read`, writes → `db.write`).
- [ ] `ICacheManager` (`get/set/delete/flush`) + Redis impl + no-op fallback when `USE_CACHE=false` / Redis down.
- [ ] Cache-aside decorators (e.g. `CachedUserRepository`).
- [ ] Fastify v5.8 server (`src/index.ts`) + route plugins:
  - [ ] `POST /api/login/account`
  - [ ] `POST /api/login/outLogin`
  - [ ] `GET /api/currentUser`
  - [ ] `GET /api/users`
  - [ ] `GET /api/notices`
- [ ] Unit tests (mocked DB/Redis) + integration tests (`fastify.inject`).

### Milestone 3 — Docker & proxy
- [x] `server` dev container added to `docker-compose.yml`.
- [ ] Give `server` a real start command (Fastify on `:5000`); keep debugger `9229` off `0.0.0.0`.
- [ ] `nginx/default.conf`: route `/api/` → `http://server:5000`; remove unused `6277` / MCP-SSE blocks.

### Milestone 4 — Frontend cutover & logs
- [ ] Disable Umi mock middleware (`npm run dev` instead of `npm start`, or config).
- [ ] Security hardening: remove `analytics` from `dashboard/config/config.ts`; repoint `dashboard/src/pages/chatbot/service.ts` off `api.x.ant.design`.
- [ ] Keep this file current.

### Remaining `dashboard/mock/` files to transition
| File | Endpoint(s) | Plan |
|------|-------------|------|
| `user.ts` | login / currentUser / users | Milestone 2 (backed by `users`, `user_tags`, `fake_list`) |
| `notices.ts` | `GET /api/notices` | Milestone 2 (backed by `dashboard_notices`) |
| `fakeList.ts` | `GET /api/fake_list` (card list) | Later — dynamically generated; needs a generated/seeded table |
| `listTableList.ts` | `GET/POST /api/rule` | Later — dynamically generated; full CRUD table |
| `route.ts` | dynamic routes | Evaluate; may stay static |

---

## Production deployment trade-offs (found while building Milestone 1)

These are **deliberate dev-time shortcuts** that must be revisited before shipping.

1. **Read/write splitting & replication lag.** The abstraction routes reads to a
   replica, but in dev the replica *is* the master (same pool), so the
   "INSERT-on-master visible on replica read" test passes only because there's no
   lag. With a real replica (`DB_REPLICA_HOST`), reads can be **stale right after a
   write**. Mitigate: read-after-write goes to master, or rely on the cache layer,
   or accept eventual consistency per endpoint.

2. **`schema.sql` is not a migration system.** `CREATE TABLE IF NOT EXISTS` has no
   versioning, no `ALTER`, no rollback. The seed **`TRUNCATE`s and reloads** — fine
   for dev/first load, **destructive in production**. Adopt a real migration tool
   (node-pg-migrate / drizzle-kit / prisma migrate) and make seeds idempotent
   (`ON CONFLICT`) before prod.

3. **bcryptjs over native bcrypt/argon2id.** Pure-JS bcryptjs avoids native builds
   in alpine but is **slower**. For real auth load, prefer `argon2` (needs a build
   toolchain in the image) and raise the cost factor (currently `SALT_ROUNDS=10`).

4. **Runtime `npm install` + `tsx`.** Dev favors fast iteration (install at
   container start, run TS directly). Production needs a **multi-stage build**:
   `npm ci` against a committed `package-lock.json`, then either compile to JS or
   run a pinned `tsx`. *No lockfile is committed yet* — reproducibility risk.

5. **Path aliases need build-time resolution.** `@/*` aliases are clean and work
   under `tsx`/vitest, but **`tsc` does not rewrite them** in compiled output. The
   prod build must use a bundler or `tsc-alias`, otherwise compiled JS fails to
   resolve `@/...`.

6. **Secrets live in `.env`.** Dev DB credentials are committed for convenience.
   Production must pull `POSTGRES_*`, `DATABASE_URL`, `REDIS_URL` from a secrets
   manager and never commit them.

7. **Host-exposed data ports.** Postgres is bound to `127.0.0.1` (better than
   `0.0.0.0`) and Redis to loopback; in production neither should be host-exposed
   at all — internal network only (`expose`).

8. **Connection pool defaults.** Using `pg` defaults (max 10 per pool). Production
   needs tuned pool sizes and likely **PgBouncer** in front of Postgres.

9. **Seed data is still Chinese (zh-CN).** Notices, signatures, etc. carry the
   original mock content, which conflicts with the **EN/DE/ES-only** product
   constraint (see `dashboard-project.md`). Localize or replace seed content before
   release.

10. **Tests are destructive against the dev DB.** Integration tests `TRUNCATE` the
    `test` database. CI must use an **ephemeral/throwaway DB**, not a shared one.

11. **`fake_list` naming.** The table backs `GET /api/users` but is named after the
    `fakeList.ts` mock — minor naming debt to reconcile in Milestone 2.
