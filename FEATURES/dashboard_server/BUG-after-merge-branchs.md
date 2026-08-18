# Bug/Status Report: Branch Consolidation (serv-26) + Post-Merge Verification

**Document Target Path**: `/Users/nbarrera/projects/Docker/node-nginx-clean/FEATURES/dashboard_server/BUG-after-merge-branchs.md`
**Target Agent**: Claude
**Related task**: `BRING_ALL_THE_BRANCHES_IN_serv-26-website-blablarags-home.md`
**Date**: 2026-08-12
**Status**: Merge DONE and verified correct. One post-merge gap found and fixed. One environment/Docker issue still OPEN (not a code bug) — blocking the user's ability to actually confirm the fix via `npm run tsc`/`test` inside the `server` container.

---

## 1. What was asked

Consolidate three branches in the `server` repo
(`git@github.com:leonmex/server-blablaragsandrigs.git`) into one target
branch, per `BRING_ALL_THE_BRANCHES_IN_serv-26-website-blablarags-home.md`:

- Target: `serv-26-website-blablarags-home`
- Sources: `serv-24-add-shopping-carts`, `serv-25-website-shop`,
  `serv-26-website-blablarags-home`
- No data loss, careful conflict audit, verify build/lint/test, land
  everything cleanly on the target branch.

## 2. Branch topology found

All three branches share one common ancestor, commit `3687ee0` ("feat:
update erd until migration 52" — same commit as `serv-23-confirm-recibe-and-return-products`/`dev-stable`):

- **`serv-25-website-shop`** — turned out to be sitting exactly AT
  `3687ee0`, i.e. **zero unique commits**. Nothing to bring in from it.
- **`serv-26-website-blablarags-home`** — `3687ee0` + 4 commits (server
  security hardening: rate limiting, audit trail, telemetry, IDOR fix;
  real JWT auth; Seller Dashboard shell; PWA).
- **`serv-24-add-shopping-carts`** — `3687ee0` + 18 commits (Shopping
  Cart + Cart Reservation feature, this session's `smoketestsuit`
  pre-release test suite, and this session's own TS-interface/test fixes).

## 3. Merge performed

Local branch `serv-26-website-blablarags-home` created from
`origin/serv-26-website-blablarags-home`, then:

1. `git merge origin/serv-25-website-shop` → `Already up to date` (confirmed
   no-op, matches §2's finding).
2. `git merge serv-24-add-shopping-carts` → **one real conflict**:
   `db/schema.sql`. Every other file that both branches touched
   (`src/app.ts`, `src/index.ts`, `src/domain/privilege.types.ts`,
   `src/repositories/PgApparelRepository.ts`, `src/routes/systemSettings.ts`,
   `test/api.integration.test.ts`) auto-merged with **no** conflicts.

### `db/schema.sql` conflict — resolved

Both branches independently appended non-overlapping DDL/DML blocks to the
end of the folded schema snapshot (serv-26: `login_audit_logs` table +
`mobile_accounts.status` + security-settings rows; serv-24: `shopping_carts`/
`shopping_cart_items` tables + cart/payment-method settings rows). Kept both
blocks in full, in the order HEAD-then-serv-24, each with its own terminal
`ON CONFLICT ... DO NOTHING;`. No SQL was dropped or duplicated — verified by
re-reading the merged region afterward.

### The 6 auto-merged files — verified, not just trusted

Read each file's independent diff from both parents side by side, then
read the final merged result:

- **`src/app.ts` / `src/index.ts`**: serv-24 added shopping-cart deps/routes,
  serv-26 added rate-limit/login-audit/catalog deps/routes — different
  import blocks, different `AppDeps` fields, no collisions.
- **`src/domain/privilege.types.ts`**: serv-24 added
  `accounts_shopping_carts`/`shopping_cart_settings` privilege sections,
  serv-26 added `security_settings` — different keys, both present in the
  merged file, confirmed via grep.
- **`src/repositories/PgApparelRepository.ts`**: serv-24 added a
  `listing_status = 'active'` filter to the catalog queries (cart
  reservation), serv-26 added catalog facet params (brands/colors/price)
  to the SAME method signature — different parts of the same function,
  auto-merged correctly, read to confirm.
- **`src/routes/systemSettings.ts`**: serv-24 added Shopping Cart +
  Payment Methods (Mock) admin settings sections, serv-26 added Security
  Settings (rate-limit thresholds) — both present, in the right order, no
  duplicate `BASE`/`ADMIN_SYSTEM_BASE` declarations.
- **`test/api.integration.test.ts`**: the highest-risk file (600+ new lines
  from serv-26, 71 changed lines from serv-24). Confirmed structurally sound
  by comparing `describe(`/`it(`/`test(` counts across base/serv-24/serv-26/
  merged: serv-24 never added new blocks (same count as base, only edited
  assertions in place), so the merged file's counts match serv-26's exactly
  — no blocks lost or duplicated. Also confirmed the 7 IBAN/BIC-exposure
  test rewrites from earlier this session (asserting via a follow-up
  `GET /api/me` instead of an echoed `data` payload) are intact post-merge.

### Migration numbering — flagged, not changed

`db/migrations/0052`–`0054` now exist **twice**, once per branch, different
filenames (e.g. `0052_catalog_facets_and_campaign_cta.sql` next to
`0052_shopping_cart.sql`). Confirmed harmless: `db/executeMigration.ts`
tracks applied migrations by **full filename** in `schema_migrations`, not
by numeric prefix, and sorts+runs by filename — read all 8 migration files
in the merged set, none reference tables/columns created by the other set,
all are idempotent (`IF NOT EXISTS`/`IF EXISTS` guards). Deliberately left
un-renumbered: renaming would make the migration runner treat them as brand
new pending files on any environment that already has the old filename
recorded as applied, which could re-run non-transactional or already-applied
DDL. Purely a readability quirk if anyone scans `db/migrations/` by number.

### Docs cross-check (per the task's instruction to use `server/docs`)

`serv-26` never had `docs/doc_enpoints*_v4`/`_v5` (dated 10082026) — those
are serv-24/this-session additions, so they merged in clean with no
conflict. Spot-checked that the v5 docs actually reference the merged
shopping-cart routes (40+/48+ mentions of "cart" across the query/endpoint
v5 docs) — consistent with the 7+2 routes now live in
`shoppingCart.ts`/`adminShoppingCarts.ts`.

**Merge commit**: `7a29b37` — "merge: integrate serv-24-add-shopping-carts
into serv-26-website-blablarags-home". 53 files changed, +25502/-170.

## 4. Post-merge `npm run tsc` — user-run, 7 errors found

Per this repo's standing convention, `tsc`/`lint`/`test` were never run by
the agent — the user ran them and pasted results back. First run surfaced
7 errors in 3 files:

- **6 errors** (`Cannot find module '@fastify/rate-limit'` in `src/app.ts`,
  plus 5 downstream `FastifyContextConfig` type errors in
  `src/routes/accounts.ts`): **not a merge bug.** Confirmed
  `package.json`/`package-lock.json` already correctly list
  `@fastify/rate-limit` (untouched by the merge — only serv-26 ever touched
  those routes) and the lockfile already has 4 matching entries. Purely a
  stale local `node_modules` that hadn't been `npm install`ed yet. Resolved
  itself once the user ran `npm install`.
- **1 real gap**: `test/rateLimit.integration.test.ts:165` — `Property
  'shoppingCartRepo' is missing in type ... but required in type
  'AppDeps'`. This test file builds its own `AppDeps` object directly
  (same pattern as `test/api.integration.test.ts`, which the merge itself
  already handled), but it's a serv-26-only file written before Shopping
  Cart added `shoppingCartRepo` as a required field — so it was never part
  of the merge's own conflict set and got missed.

  **Fixed** (commit `de92f0c`): added the `PgShoppingCartRepository` import,
  instantiated it (`new PgShoppingCartRepository(db)`), and wired it into
  the `buildApp({...})` call — same pattern as `index.ts` and
  `api.integration.test.ts`. Confirmed via grep that these are the ONLY two
  files anywhere in `test/`/`devops/` that call `buildApp(`, so no other
  file has the same gap.

## 5. OPEN issue: container won't see the fix (Docker, not code)

After the fix above was committed, the user re-ran
`npm install && npm run lint && npm run tsc && npm run test` — lint passed,
the 6 `@fastify/rate-limit` errors were gone, but **the exact same
`shoppingCartRepo` error at line 165 still appeared**, unchanged.

Direct investigation on the host repo confirmed the fix is real and
committed:

```
$ git log --oneline -2
de92f0c fix: wire shoppingCartRepo into rateLimit.integration.test.ts's buildApp call
7a29b37 merge: integrate serv-24-add-shopping-carts into serv-26-website-blablarags-home
$ grep -n shoppingCartRepo test/rateLimit.integration.test.ts
131:  const shoppingCartRepo = new PgShoppingCartRepository(db);
207:    shoppingCartRepo,
```

So the discrepancy is environmental. Ruled in/out so far:

- **A second, unrelated clone exists** at
  `/Users/nbarrera/projects/Docker/node-nginx-clean-cv/server` (different
  remote, branch `server-main-step4`) — raised as a candidate explanation
  (wrong `docker compose` project directory), but ruled out: the
  diagnostic below shows the container's branch name IS
  `serv-26-website-blablarags-home`, so it's the right compose project.
- **Diagnostic run inside the container**
  (`docker compose exec server sh -c "git rev-parse HEAD; git branch
  --show-current; grep -n shoppingCartRepo test/rateLimit.integration.test.ts"`):
  returned `HEAD = 7a29b37` (one commit BEHIND the host's `de92f0c`),
  branch correctly `serv-26-website-blablarags-home`, and **zero** matches
  for `shoppingCartRepo` in the container's copy of the file. So the
  container is looking at the right branch, but a stale snapshot of it —
  specifically, missing exactly the one commit made after the container
  last read the mount.
- **`docker compose restart server` did NOT fix it** — re-ran the same
  diagnostic after the restart, identical result (`HEAD` still `7a29b37`,
  still no `shoppingCartRepo` match). This rules out a simple "process
  needs restarting to pick up new files" explanation.
- **Current leading hypothesis**: `docker-compose.yml`'s `server` service
  bind-mounts `./server:/usr/src/server` (a *relative* path, resolved
  against whatever directory `docker compose` was run from at container
  **creation** time — not re-evaluated on every command). A `restart`
  reuses the exact same container and therefore the exact same already-
  resolved mount; it does NOT re-resolve `./server`. If this container was
  originally created via `docker compose up` from a different working
  directory at some point, `/usr/src/server` could be bound to a
  completely different host path than today's
  `/Users/nbarrera/projects/Docker/node-nginx-clean/server`, and no
  amount of `restart`/`exec` from the right directory would change that
  for an already-running container.
- **Next diagnostic step, requested but not yet returned by the user**:
  ```
  docker ps --filter "name=server" --format "{{.ID}}\t{{.Names}}\t{{.CreatedAt}}"
  docker inspect $(docker ps --filter "name=server" -q) \
    --format '{{range .Mounts}}{{.Source}} -> {{.Destination}}{{"\n"}}{{end}}' \
    | grep "usr/src/server$"
  ```
  This will show the actual host path Docker has bound to
  `/usr/src/server` for the running container. If it doesn't match
  `/Users/nbarrera/projects/Docker/node-nginx-clean/server` exactly, that
  confirms the hypothesis, and the fix is a full **recreate** (not
  restart): `docker compose down && docker compose up -d` run from
  `/Users/nbarrera/projects/Docker/node-nginx-clean`, which forces Compose
  to re-resolve `./server` fresh from the current directory.

**This document was written before that `docker inspect` output was
returned** — the root cause is a strong hypothesis, not yet 100% confirmed.

## 6. Where things stand

- Code side: **done**. Merge is complete, verified file-by-file, committed
  (`7a29b37` + follow-up fix `de92f0c`) on local branch
  `serv-26-website-blablarags-home`. **Not pushed to origin yet** —
  awaiting the user's go-ahead once `tsc`/`lint`/`test` are confirmed green
  from inside a container that's actually reading the current code.
- Verification side: **blocked**, but by Docker container/mount state, not
  by anything wrong in the merge or the fix. Once the `docker inspect`
  question above is answered (and, if confirmed, the stack is recreated
  from the right directory), `npm run lint && npm run tsc && npm run test`
  should be re-run one more time inside the container to get a real,
  trustworthy result.
- No code should be touched further based on the still-failing
  `shoppingCartRepo` error until the container/mount question is resolved
  — the fix has already been verified correct twice against the actual
  file on disk; re-editing it again would not change anything and would
  only mask the real (environmental) problem.
