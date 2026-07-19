# Project-Specific Agent Learnings & Skills

This document acts as a persistent memory and skill log for AI agents working on this project. 
Before starting work, read this log to avoid repeating past mistakes. After resolving an error or implementing a new technique, document it here to help future runs.

---

## Core Guidelines & Quality Checks

### 1. Comments & Documentation Requirement
- **Code Comments**: Every new function, repository, route, and database schema must be clearly commented in English. Explain the "why" and any non-obvious business logic, not just what the code does.
- **Documentation**: Keep `migration_progress.md` and `README.md` updated as new endpoints or configurations are added.

### 2. No Chinese / Unlocalized Text
- **Source of Error**: Ant Design Pro template scaffolding contains legacy Chinese mock files, labels, and comments.
- **Verification Rule**: Proactively run `grep -rIno "[一-鿿]" src/pages/<section>` to ensure zero Chinese characters are added. Every user-visible string must be wrapped in `intl.formatMessage` and registered in `en-US`, `de-DE`, and `es-ES`.

---

## Log of Detected Errors & Solutions

### 🔴 Issue 1: PostgreSQL Updates Not Showing in Dashboard UI
- **Description**: Directly modifying tables (e.g. `user_tags`) in PostgreSQL does not update the frontend dashboard immediately.
- **Root Cause**: The backend application caches database results (like user profiles) in Redis (under `user:profile:<userid>` keys with a 60-second default TTL). Direct database writes bypass cache invalidation.
- **Solution/Skill**: Flush the Redis cache or delete the specific key after manual DB edits:
  ```bash
  # Flush all caches
  docker compose exec redis redis-cli flushall
  
  # Or delete specific user profile cache
  docker compose exec redis redis-cli del user:profile:00000001
  ```

### 🔴 Issue 2: Command Executed on Host Fails
- **Description**: Running `npm install`, testing, or migrations directly on the host machine leads to dependency conflicts or database connection failures.
- **Root Cause**: The workspace relies completely on Docker orchestration for package isolation, PostgreSQL, and Redis networks.
- **Solution/Skill**: Always run commands using their containerized equivalent:
  ```bash
  docker compose exec -T webapp sh -c "<cmd>"
  docker compose run --rm server npm run <script>
  ```

### Issue 3: React 19 useRef requires an initial argument
- **Description**: `const actionRef = useRef<ActionType>();` fails TS with "Expected 1 arguments, but got 0".
- **Root Cause**: React 19 type definitions removed the zero-argument `useRef` overload.
- **Solution/Skill**: Pass an initial value: `useRef<ActionType | undefined>(undefined)`. Verify with `docker compose exec -T webapp sh -c "npm run tsc"`.

### Issue 4: umi `useRequest` unwraps the response `data` field
- **Description**: With a service returning `{ data: T }`, `const { data } = useRequest(fn)` gives `T` directly, so `data?.data` is a type error.
- **Root Cause**: `@umijs/max` `useRequest` applies a default formatter that returns `response.data`.
- **Solution/Skill**: Use `const { data: metrics } = useRequest(fetchMetrics)` and treat it as the unwrapped payload. Plain `request(...)` is NOT unwrapped — only the `useRequest` hook is.

### Issue 5: New SeedCounts field breaks exact-count test assertions
- **Description**: Adding tables to `db/seed.ts` `SeedCounts` made `test/db.integration.test.ts` and `test/reset.integration.test.ts` fail on `toEqual({...})`.
- **Root Cause**: Those tests assert the full counts object.
- **Solution/Skill**: When a new section adds seed tables, update those two assertions. Integration files run serially (`fileParallelism: false`) because they share one DB.

### Issue 6: Login blocked by CORS to the external Ant Design demo API
- **Description**: Login POSTed to `https://pro-api.ant-design-demo.workers.dev/api/login/account` and was blocked by CORS, so users could not authenticate.
- **Root Cause**: Two things. (1) `dashboard/src/app.tsx` set the request `baseURL` to the external demo worker for any non-dev build (`isDev ? '' : 'https://pro-api...'`). (2) A stale workbox **service worker** (from an earlier prod preview) kept serving the cached production bundle even on the dev server, so the non-dev branch was used.
- **Solution/Skill**: This app always serves `/api/*` on the same origin via nginx, so set `baseURL: ''` unconditionally in `app.tsx`. After a stale SW is suspected, clear it in the browser: DevTools -> Application -> Service Workers -> Unregister (or "Clear site data"), then hard reload (Cmd+Shift+R). Verify backend independently: `curl -s -o /dev/null -w "%{http_code}" -X POST http://localhost/api/login/account -H 'Content-Type: application/json' -d '{"username":"admin","password":"ant.design"}'`.

### Issue 7: ALTER COLUMN ... TYPE enum fails on a column with a DEFAULT
- **Description**: Migrating `pending_category_suggestions.status` from `VARCHAR(32) DEFAULT 'PENDING'` to a custom enum (`suggestion_status_enum`) with a bare `ALTER COLUMN ... TYPE ... USING` can error/keep a stale default, because Postgres still holds the old `'PENDING'::varchar` default expression.
- **Root Cause**: The column default is typed against the old column type. Changing the type does not re-parse the default, so it can be left as a `varchar` literal incompatible with the enum.
- **Solution/Skill**: In the same `ALTER TABLE`, `DROP DEFAULT` first, then `TYPE ... USING col::new_enum`, then `SET DEFAULT 'PENDING'` so the literal is parsed as the enum. Define the enum idempotently (`DO $$ ... IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname=...) THEN CREATE TYPE ... END $$`) since `CREATE TYPE` has no `IF NOT EXISTS`. Note `schema.sql` uses `CREATE TABLE IF NOT EXISTS`, so it will NOT migrate an existing dev/test DB — apply the migration explicitly: `docker compose exec -T dbPostgres psql -U postgres -d test -v ON_ERROR_STOP=1 < server/db/migrations/000N_*.sql`, then `docker compose exec -T server npm run db:seed`. Bound params (node-postgres) sent with unspecified type are inferred to the enum, so `WHERE col = $1` and string inserts keep working without explicit casts.

### Issue 8: Sorting + pagination — pick the model deliberately (React client-side vs DB)
- **Description**: "Make the table sortable" is ambiguous and the wrong default wastes DB round-trips or silently sorts the wrong scope.
- **Root Cause**: Three distinct models exist: (a) **server-side sort** — each header click re-queries with `sortBy`/`sortOrder`; correct across the full dataset but a DB call per sort and needs a column allow-list to avoid SQL injection; (b) **full client-side** — load all rows once, React sorts + paginates in-browser; snappy but heavy initial load; (c) **hybrid** — server-side pagination + client-side sort of the loaded page only.
- **Solution/Skill**: For small/bounded queues (tens of rows, e.g. review queues), prefer the **hybrid** model: keep server pagination (`defaultPageSize: 20`, `pageSizeOptions: [20, 50, 100]`) and make every column sortable client-side by giving the antd/ProTable column a **compare function** (`sorter: (a, b) => a.x - b.x` for numbers, `localeCompare` for strings, `?? ''`/`?? 0` for nullables). A `sorter` *function* sorts in memory with NO refetch; `sorter: true` would instead delegate to the backend `request`. Be explicit that this reorders only the current page. Always confirm the desired model with the user before coding when pagination is involved, and run `npx antd info Table` to confirm the `sorter` signature.

### Issue 9: Fastify `app.decorate()` inside a plugin is invisible to sibling plugins
- **Description**: Adding a shared `authenticate` preHandler via `app.decorate('authenticate', ...)` inside one route plugin (e.g. `routes/auth.ts`'s `authRoutes`) works for that plugin's own routes but breaks route registration in a sibling plugin (e.g. `routes/users.ts`'s `userRoutes`) that references `{ preHandler: app.authenticate }`.
- **Root Cause**: Fastify plugins are encapsulated by default — a decorator added to the `app` instance passed into a plugin function only exists on that plugin's own child context, not on the parent or on sibling plugins registered separately via `app.register(...)`. Only decorators added to the *root* instance (or via a plugin wrapped with `fastify-plugin`, which this project doesn't depend on) are visible everywhere.
- **Solution/Skill**: Keep the actual check logic as a plain exported function in the file that "owns" it (e.g. `export async function authenticateHandler(req, reply) {...}` in `routes/auth.ts`), but call `app.decorate('authenticate', authenticateHandler)` once on the root instance in `app.ts`'s `buildApp()`, before registering any route plugins. A `declare module 'fastify' { interface FastifyInstance { authenticate: ... } }` augmentation (co-located with the handler) gives every plugin's `app.authenticate` the right type. Verify by hitting a newly-gated route in a plugin other than the one that "defines" the check — a 500/`undefined is not a function` at startup means the decorator registration is in the wrong place.

### Issue 10: `server` container runs `npm start` (no watch) — code edits need a manual restart
- **Description**: After editing `server/src/**` or `server/db/**`, hitting the API through nginx still served the old behavior (e.g. new routes 404'd) even though `tsc`/tests against the edited files passed and the bind mount (`./server:/usr/src/server`) was correctly reflecting the new file contents inside the container.
- **Root Cause**: `docker-compose.yml`'s `server` service entrypoint runs `npm run start` (`tsx --env-file-if-exists=../.env src/index.ts`), not `npm run dev` (`tsx watch ...`). Without `watch`, the Node process never restarts on file changes — only `docker compose exec ... npm run tsc`/`npm test` (which spawn a fresh process) pick up edits; the long-running server process does not.
- **Solution/Skill**: After backend source changes, restart the service to load them: `docker compose restart server`. If the DB schema changed, re-seed afterward: `docker compose exec -T server npm run db:seed`, and flush Redis if cached responses might be stale: `docker compose exec -T redis redis-cli flushall`. Verify with a live curl through nginx (not just `fastify.inject` in tests), e.g. `curl -s -b cookies.txt http://localhost/api/<new-route>`.

### Issue 11: `npm install` succeeding does not mean the app can start — undeclared imports crash-loop silently
- **Description**: `server` crash-looped for ~30+ minutes (`npm install` → `npm start` → `ERR_MODULE_NOT_FOUND` → restart) with real users unable to log in (`502`/`No route to host` on `/api/login/account`), while `dbPostgres`/`redis`/`minio`/`proxy` all reported healthy so nothing else looked wrong.
- **Root Cause**: `server/src/index.ts`, `server/src/services/MinioObjectStorage.ts`, and `server/src/app.ts` imported `minio`, `@fastify/multipart`, and `jsonwebtoken` — none of which were ever added to `server/package.json`. The runtime `npm install --ignore-scripts` pattern (see root `CLAUDE.md`) only installs what's *listed* in `package.json`; it never cross-checks that against what `src/` actually imports, so it exits `0` even when a runtime import is guaranteed to fail. Separately, `server/package.json` briefly had a stray trailing `}` (`npm error EJSONPARSE`) from a hand-edit, which is just as fatal and just as invisible on a quick read-back.
- **Solution/Skill**: Use the `validate-node-packages` skill (`.claude/skills/validate-node-packages/SKILL.md`) any time a dependency is added, removed, or upgraded in `server/` or `dashboard/`. It cross-checks every external `import`/`require` in `src`/`db` against `package.json`'s `dependencies`/`devDependencies` with a `grep`-based diff, validates `package.json` is syntactically valid JSON, checks Node-engine/peer-dep compatibility before installing, and — critically — requires restarting the actual container and reading the startup log line (not just a clean `npm install`) before calling the change done: `docker compose restart server && docker compose logs server --tail 40`.

---

## Template for Logging New Learnings
If you encounter a new build failure, a tricky database/cache bug, or an integration issue, append it here using this format:

```markdown
### 🔴 Issue N: [Brief Title]
- **Description**: [What happened?]
- **Root Cause**: [Why did it happen?]
- **Solution/Skill**: [How to fix it and verify it, including CLI commands]
```
