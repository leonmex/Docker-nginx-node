# PROMPT: Add New Full-Stack Section
Build a complete dashboard section (menu, form-driven data model, charts, tabs, DB-backed API, tests, migration). Strict rule: NO emojis anywhere in code, comments, or docs.

---

## Required Inputs
1. **Section slug** (kebab/camel id, e.g., `reports`)
2. **Menu label** (human menu text, e.g., "Reports")
3. **Description** (data, form fields, charts, sub-sections)

If missing, ASK. If provided, DERIVE entities, fields, charts, and state assumptions briefly before starting. Optional inputs to clarify if needed: menu parent/placement, access (`admin` vs `user`), read/write, chart types.

---

## Codebase Rules & Standards
- **Comments & Docs**: Document new pages, endpoints, and schema tables. Write comments in code to explain non-obvious business logic, parameters, and design details.
- **Learnings & Skills Log**: Before starting, read `.claude/learned_lessons.md` to avoid repeating documented errors. If you encounter and resolve new build, test, or runtime errors, document them in `.claude/learned_lessons.md` at the end of your run.
- **Container-first**: Run everything inside containers (`docker compose run --rm server npm run <script>`, `docker compose exec -T webapp sh -c "<cmd>"`). No host-side node execution.
- **No Mocks**: No Umi mocks (`_mock.ts`). API requests route via Nginx (`/api/*` -> `server:5000`).
- **i18n**: All UI strings must use `intl.formatMessage` and exist in `en-US`, `de-DE`, and `es-ES` per `CLAUDE-I18N-GUIDE.md`.
- **Observability**: Use `ILogger` (`src/core/logger.ts`), never `console.*`. Log requests, cache hits/misses, and database writes.
- **Architecture**: Repositories must hide behind interfaces. Reads query replica (`db.read`); writes hit master (`db.write`) and invalidate cache (delete `<section>:all` & `<section>:<id>`).
- **Security**: Use parameterized SQL queries. Validate all dynamic table/column identifiers against allowlists.
- **Quality**: Server `tsc` + `test` must pass. Dashboard `tsc`, `@biomejs/biome check`, `antd lint`, and `build` must pass.
- **No Emojis**: Forbidden in commits, comments, logs, or code.
- **Naming Conventions**:
  - Tables: `<section>` (or `<section>_<entity>`) with serial `id` PK and `created_at TIMESTAMPTZ DEFAULT now()`.
  - API Routes: `GET /api/<section>` (list), `POST /api/<section>` (create), etc.
  - i18n: `menu.<section>`, `pages.<section>.*`.
  - Cache: `<section>:all`, `<section>:<id>`.

---

## Deliverables
- **Backend (`server/`)**:
  - `db/migrations/<NNN>_<section>.sql` & `db/schema.sql` (forward DDL, idempotent).
  - `db/fixtures.ts` (typed seeds) & `db/seed.ts` (truncate list + insert + counts).
  - `db/reset.ts` (added to `ALL_TABLES`, restore, and `ID_RANGE_TABLES` if serial PK).
  - `src/domain/types.ts` (entities/DTOs), `src/repositories/types.ts` (`I<Section>Repository`).
  - `Pg<Section>Repository.ts` & `Cached<Section>Repository.ts` (cache-aside + invalidation).
  - `src/routes/<section>.ts` (Fastify routes + body schema validation).
  - `src/app.ts` & `src/index.ts` (register routes & wire repository).
- **Frontend (`dashboard/`)**:
  - `src/pages/<section>/` (`index.tsx` with Tabs, `service.ts` API requests, `data.d.ts` DTOs, components for forms/charts).
  - `config/routes.ts` (menu route entry).
  - `src/locales/{en-US,de-DE,es-ES}/{menu,pages}.ts` (i18n translations).
- **Tests**:
  - Unit (cache decorator hit/miss/invalidation), Integration (`PgRepository` CRUD), API (`fastify.inject` for routes).
- **Docs**:
  - Update `migration_progress.md` (section row, endpoints, and test count).

---

## Build order (do backend first, verify each step)

### Step 0 — Confirm & plan
State the derived entities, table columns, form fields, chart(s), sub-sections, and route shape. Confirm assumptions. Keep it short.

### Step 1 — Migration & Database Schema
1. Create `server/db/migrations/<NNN>_<section>.sql` containing forward DDL (CREATE TABLE, indexes).
2. Add the exact same DDL (`CREATE TABLE IF NOT EXISTS...`) to `server/db/schema.sql`. Use serial `id` PK and `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`.
3. Verify by running: `docker compose run --rm server npm run db:seed`.

### Step 2 — Seed Data & Resets
1. Define typed fixture seeds in `db/fixtures.ts`.
2. Update `db/seed.ts` (add table to `TRUNCATE`, insert records, increment `SeedCounts`).
3. Update `db/reset.ts` (add table to `ALL_TABLES` list, add range check to `ID_RANGE_TABLES`, and handle restore).
4. Verify with `docker compose run --rm server npm run db:seed`.

### Step 3 — Domain & Repository Layer
1. Add entity + DTO schemas to `src/domain/types.ts`.
2. Define repository interface in `src/repositories/types.ts`.
3. Implement `Pg<Section>Repository.ts` (`db.read` for reads, `db.write` for writes; parameterized queries only; wrap multi-write queries in `db.withTransaction`).
4. Implement `Cached<Section>Repository.ts` (caching reads; invalidating `<section>:all` and `<section>:<id>` on write operations).

### Step 4 — Fastify Routes & Wiring
1. Implement `src/routes/<section>.ts` Fastify plugin. Validate inputs via `schema.body`. Match frontend format (e.g. `{ data }` or `{ data, total }`). Use `req.log`.
2. Register dependency `<section>Repo` in `src/app.ts` under `AppDeps` and register the routes.
3. Instantiate and inject the repository chain in `src/index.ts`.

### Step 5 — Backend Testing
- Create `test/<section>.repo.integration.test.ts` (test DB CRUD and read/write splitting).
- Add endpoint testing using `fastify.inject` (test status codes, response envelopes, validation errors).
- Unit test cache hits, misses, and invalidations.
- Verify: `docker compose run --rm server sh -c "npm run tsc && npm test"`.

### Step 6 — Frontend Components & i18n
1. Create page structure under `src/pages/<section>/` using `PageContainer` and `Tabs` for sub-sections.
2. Build Form using `@ant-design/pro-components` or antd `Form`. Connect submit to `service.ts`.
3. Add charts using `@ant-design/plots`.
4. Render lists using Ant Design ProTable.
5. Translate all strings using `intl.formatMessage` keys mapped in `en-US`, `de-DE`, and `es-ES` locale files.
6. Register the route in `config/routes.ts`.

### Step 7 — Quality Gate Verification
Execute and verify:
```bash
docker compose exec -T webapp sh -c "npm run tsc"
docker compose exec -T webapp sh -c "npx @biomejs/biome check src/pages/<section> src/locales" # use --write to auto-fix
docker compose exec -T webapp sh -c "npx antd lint ./src"
docker compose exec -T webapp sh -c "npm run build"
grep -rIno "[一-鿿]" src/pages/<section>  # MUST return zero Chinese character matches
```
- Open `http://localhost/<route>`, verify functional CRUD, locale translation (EN/DE/ES), and backend communication.

### Step 8 — Documentation
- Document new endpoints, the migration file, and test coverage inside `migration_progress.md`.

---

## Acceptance Criteria
- Table exists in migration & schema; fully handled by `db:seed` and `db:reset`.
- API endpoints expose CRUD; replica is read, master is written; write invalidates cache; actions are logged.
- Dashboard renders correctly without mock data, and handles EN/DE/ES translation cleanly.
- Quality gates (TypeScript, Biome, Antd Lint, tests, build) all pass on front & back.
- `migration_progress.md` is updated.

---

## Example Invocation
> Build new section. Slug: `reports`. Menu: "Reports". Description: sales reports CRUD page. Fields: title, period (month), amount, channel. Charts: Column (amount by month) & Pie (amount by channel). Tabs: "Overview" (charts) & "Records" (ProTable with create).

**Agent Action**: Confirm entity definition, create migrations, wire seeders/resets, implement backend (repo/cache/endpoints/tests) and frontend (i18n translations, form, charts, tabs), pass all quality checks, and log progress in `migration_progress.md`.
