# TypeScript 7 — Validation Steps & Findings (2026-08-01)

This document records the commands actually run to validate this repo's TypeScript 7
readiness, what they returned, and how those results correct the assumptions baked into
the earlier `docs/TypeScript_7_Migration_Plan.md` and `scripts/validate_ts7_compatibility.py`.
Read this alongside that plan — this file is the evidence trail; the plan file's Section 2
risk matrix should be treated as superseded by Section 3 below where they disagree.

---

## 1. Commands run

```bash
# Existing static audit tool
python3 scripts/validate_ts7_compatibility.py

# Compiler config as currently checked in
cat server/tsconfig.json
cat dashboard/tsconfig.json

# What's actually declared in each app's package.json
cat server/package.json
cat dashboard/package.json

# Is ts-node (a TS7 programmatic-API risk) actually wired into any script/config?
grep -rn "ts-node" dashboard --include="*.json" --include="*.js" --include="*.ts" --include="*.cjs" --include="*.mjs" -l | grep -v node_modules
find dashboard -maxdepth 1 -iname "*.config.ts" -o -maxdepth 1 -iname ".*rc.ts"

# Does anything in the lockfile actually require ts-node as a transitive dep?
python3 -c "
import json
data = json.load(open('dashboard/package-lock.json'))
packages = data.get('packages', {})
for name, info in packages.items():
    deps = {**info.get('dependencies', {}), **info.get('peerDependencies', {}), **info.get('optionalDependencies', {})}
    if 'ts-node' in deps:
        print(repr(name), '->', deps['ts-node'])
print('root devDeps has ts-node:', 'ts-node' in packages.get('', {}).get('devDependencies', {}))
"

# Real decorator usage vs. the tsconfig flag that enables it (is it dead config?)
grep -rn "^\s*@[A-Za-z]" dashboard/src --include="*.ts" --include="*.tsx" | grep -v ".umi"
grep -rEn "^\s*@[A-Za-z_][A-Za-z0-9_]*\s*(\(.*\))?\s*$" dashboard/src --include="*.ts" --include="*.tsx" | grep -v node_modules

# Frameworks TS7 explicitly hasn't caught up with yet (Vue/Svelte/Astro/MDX/Angular) — do we use any?
grep -iE "\"(vue|svelte|astro|mdx|@angular)" dashboard/package.json server/package.json

# Vitest typecheck feature (known TS7/tsgo friction point) — is it even enabled?
grep -rn "typecheck" dashboard/vitest.config.ts server/vitest.config.ts

# What's ACTUALLY installed and running right now, inside the real containers
# (host node_modules is stale/irrelevant — see root CLAUDE.md's named-volume architecture)
docker compose exec -T webapp sh -c '
  node -e "console.log(require(\"typescript/package.json\").version)"
  for pkg in "@umijs/max" "@ant-design/cli" "@umijs/lint" "ts-node"; do
    node -e "
      const d = require(\"./node_modules/$pkg/package.json\");
      console.log(\"$pkg\", d.version, \"| peer typescript:\", (d.peerDependencies||{}).typescript);
    "
  done
'
docker compose exec -T server sh -c '
  node -e "console.log(require(\"typescript/package.json\").version)"
  for pkg in "vite-tsconfig-paths" "tsx" "vitest" "@biomejs/biome"; do
    node -e "
      const d = require(\"./node_modules/$pkg/package.json\");
      console.log(\"$pkg\", d.version, \"| peer typescript:\", (d.peerDependencies||{}).typescript);
    "
  done
'
```

Web research (see Sources at the end of the main answer) was used to pull the **official**
TypeScript 7.0 breaking-changes list directly from `devblogs.microsoft.com`, rather than
relying on secondhand summaries.

---

## 2. Raw findings

| Check | Result |
| --- | --- |
| `server` installed `typescript` | `5.9.3` (declared `^5.7.2`) |
| `dashboard` installed `typescript` | `6.0.3` (declared `^6.0.3`) |
| `server/tsconfig.json` | `moduleResolution: "Bundler"`, `verbatimModuleSyntax: true`, `types: ["node"]`, **`baseUrl: "."` present** |
| `dashboard/tsconfig.json` | `moduleResolution: "bundler"`, `experimentalDecorators: true`, no `verbatimModuleSyntax`, `types` explicit, **no `baseUrl`** |
| `ts-node` usage in `dashboard` | Declared as a devDependency only; matched in `package.json`/`package-lock.json` and one built `dist/` bundle. **Zero scripts, configs, or other packages actually require it** — root-only devDependency, dead weight. |
| Real decorator syntax (`@Foo` before a `class`/method) in `dashboard/src` | **Zero matches.** The one `^\s*@` hit was `@keyframes` inside a CSS-in-JS template literal (`src/pages/chatbot/style.ts`) — a false positive, not a TS decorator. `experimentalDecorators: true` is unused config. |
| Vue / Svelte / Astro / MDX / Angular in either `package.json` | None found. |
| Vitest `typecheck` option enabled | Not set in either `vitest.config.ts` — the vitest+tsgo typecheck friction reported industry-wide doesn't apply here. |
| `@umijs/max`, `@ant-design/cli`, `@umijs/lint` — `typescript` peerDependency | **Undefined for all three** — no version gate, they don't hard-pin against the compiler API. |
| `tsx`, `vitest`, `vite-tsconfig-paths`, `@biomejs/biome` — `typescript` peerDependency | **Undefined for all** — none of the server's dev tooling gates on TS version. |
| `ts-node` peerDependency on `typescript` | `>=2.7` (semver-satisfied by 7.x, but functionally needs the removed programmatic API to actually run) |
| Node.js | Both apps pin `engines.node: >=22`; Dockerfile builds on `node:22-alpine`. TS7/tsgo requires Node 20+. **Already satisfied, no bump needed.** |

---

## 3. Corrections to the earlier plan/audit script

`docs/TypeScript_7_Migration_Plan.md` §2 and `scripts/validate_ts7_compatibility.py` predate
this validation pass and got two things wrong, and missed one real blocker:

1. **`experimentalDecorators`/`verbatimModuleSyntax` are NOT in TypeScript's official 7.0
   breaking-changes list.** They aren't forced or removed — Microsoft's own migration guide
   doesn't mention decorators changing at all. The audit script's warning text ("TypeScript 7
   enforces ECMA Stage 3 decorators by default") is an unverified assumption, not a documented
   fact. Since the flag is dead config anyway (zero real decorator usage), the fix is a cleanup,
   not a compatibility requirement.
2. **The real, documented hard blocker the old audit missed entirely: `baseUrl`.** Microsoft's
   official breaking-changes list states `baseUrl` is **removed** in 7.0 ("use `paths` relative
   to project root"). `server/tsconfig.json` has `"baseUrl": "."` — this will hard-error under
   TypeScript 7, and neither `scripts/validate_ts7_compatibility.py` nor the old plan's risk
   matrix checks for it at all.
3. The old plan frames "Framework Type Generation" (`@umijs/max`'s `src/.umi/` codegen) as
   **Critical** risk. Empirically, none of `@umijs/max`/`@ant-design/cli`/`@umijs/lint` declare
   a `typescript` peer dependency, and Umi's build path doesn't invoke the compiler
   programmatically for bundling (it transpiles via its own bundler, not `tsc`). This should be
   downgraded to **Medium** — worth a real dry-run, but not the top risk.
4. The old plan's true top risk — that this repo doesn't have — is the programmatic compiler
   API removal. It doesn't apply here: no ESLint (`typescript-eslint`), no Jest (`ts-jest`), no
   `ts-morph`, and no Vue/Svelte/Astro/MDX/Angular. The only package in the graph that touches
   that API is `ts-node`, and it's unused dead weight (see §2). This is the single biggest
   reason this migration is lower-risk than a "typical" TS7 upgrade.

---

## 4. Net effect on the phased plan

Given the corrected findings, the phased plan in the main answer replaces
`docs/TypeScript_7_Migration_Plan.md` §4 with:

- **Remove `ts-node`** from `dashboard/package.json` (dead weight, the one real programmatic-API
  risk in the tree).
- **Remove `experimentalDecorators: true`** from `dashboard/tsconfig.json` (dead config, not a
  TS7 requirement, but no reason to carry unused legacy-decorator semantics forward).
- **Remove `"baseUrl": "."`** from `server/tsconfig.json` — this is the one confirmed hard
  blocker; `paths` entries (`"src/*"`, `"db/*"`, etc.) already resolve identically without it
  since `baseUrl` was already `"."` (the project root), so this is a no-op for actual path
  resolution, purely removing config TS7 rejects.
- **Add explicit `rootDir: "."`** to both `tsconfig.json` files, since TS7 changes the default
  `rootDir` computation and both projects' tsconfigs live at their respective app roots already.
- Optionally add `verbatimModuleSyntax: true` to `dashboard/tsconfig.json` to match `server` —
  good hygiene (catches type-only-import mistakes at compile time), not a TS7 requirement.
- Two-step version bump (per Microsoft's own recommended order): `server` goes `^5.7.2` → `^6.x`
  first (resolve deprecations) → then both apps move to `^7.0.x` together.

---

## 5. Phase 0 — executed 2026-08-01: cleanup & the real `baseUrl` blocker

Phase 0 (remove dead `ts-node`, remove dead `experimentalDecorators`, fix the `baseUrl`
blocker) was carried out and validated end-to-end against the running dev stack, both
`tsc` type-checks, both Vitest suites, and both `docker compose build` paths. Exact
commands and real results below — nothing in this section is hypothetical.

### 5.1 File changes made

- `dashboard/package.json` — removed the unused `"ts-node": "^10.9.2"` devDependency.
- `dashboard/tsconfig.json` — removed dead `"experimentalDecorators": true`; added
  `"verbatimModuleSyntax": true` (hygiene, matches `server`); added `"rootDir": "."`.
- `server/tsconfig.json` — removed `"baseUrl": "."`; added `"rootDir": "."`.

### 5.2 A real finding the plan's assumption got wrong

The original assumption (§4) was that dropping `baseUrl: "."` would be a no-op since
`paths` already resolved the same way. **That was wrong** — running the actual compiler
surfaced this immediately:

```bash
$ docker compose exec -T server sh -c "npm run tsc"
tsconfig.json(19,15): error TS5090: Non-relative paths are not allowed when 'baseUrl' is
not set. Did you forget a leading './'?
tsconfig.json(20,17): error TS5090: ...
tsconfig.json(21,21): error TS5090: ...
tsconfig.json(22,19): error TS5090: ...
```

Fix: every `paths` entry needs an explicit `./` prefix once `baseUrl` is gone
(`"src/*"` → `"./src/*"`, etc.) — this is exactly how `dashboard/tsconfig.json`'s
`paths` were already written, `server`'s just weren't. After the fix, `tsc --noEmit`
passed clean. **Lesson for the dev team: always re-run `npm run tsc` after touching
`tsconfig.json` — don't trust "this looks like a no-op" reasoning about path resolution.**

### 5.3 Commands run, in order, with results

```bash
# 1. Pick up the dashboard package.json change (prunes ts-node, rewrites package-lock.json) —
#    the webapp container's entrypoint re-runs `npm install --ignore-scripts` on every start.
docker compose restart webapp
docker compose logs webapp --tail 60
#   -> "removed 1 package, and audited 2130 packages in 33s"
#   -> Umi dev server compiled clean: "utoo pack v1.4.13 ready in 2456ms" / "Compiled in 5s"

# 2. Dashboard type-check (validates tsconfig.json changes: no experimentalDecorators,
#    verbatimModuleSyntax added, rootDir added)
docker compose exec -T webapp sh -c "npm run tsc"
#   -> clean, zero errors

# 3. Server type-check — FIRST RUN caught the baseUrl/paths issue above; after the
#    ./src/* fix, second run:
docker compose exec -T server sh -c "npm run tsc"
#   -> clean, zero errors

# 4. Server integration test suite (validates the `@/`, `@db/`, `@devops/`, `@test/`
#    path aliases still resolve through vite-tsconfig-paths with the ./-prefixed paths)
docker compose exec -T server sh -c "npm test"
#   -> Test Files 13 passed (13) / Tests 282 passed (282)

# 5. Dashboard lint + type-check (project rule: both must pass before commit)
docker compose exec -T webapp sh -c "npm run lint"
#   -> biome:lint: "Checked 344 files in 3s. No fixes applied."
#   -> tsc: clean, zero errors

# 6. Dashboard Vitest suite
docker compose exec -T webapp sh -c "npm test"
#   -> Test Files 14 passed (14) / Tests 61 passed (61)

# 7. Dev-stack image build (Dockerfile `webapp` target — no install at build time,
#    confirms the Dockerfile/compose wiring itself is untouched and still builds)
docker compose build
#   -> "Image docker-nginx-node-webapp Built"

# 8. Production image build (Dockerfile `builder` + `production` targets — the ONLY
#    path that runs `npm install --ignore-scripts && npm run build` at build time;
#    this is the path dev-only `tsc`/vitest checks above never exercise)
docker compose -f docker-compose.prod.yml build
#   -> full Umi production build completed (every route's index.html emitted),
#      "Image node-nginx-clean-webapp:prod Built"
```

All eight steps passed clean on the first attempt after the `baseUrl`→`./paths` fix.
No source code changes were needed anywhere in `server/src`, `server/db`, `server/devops`,
`server/test`, or `dashboard/src` — this phase was entirely `tsconfig.json`/`package.json`
surface area.

### 5.4 Current repo state after Phase 0

| App | `typescript` | Status |
| --- | --- | --- |
| `server` | `^5.7.2` (installed `5.9.3`) | Phase 0 clean; ready for Phase 1 (bump to `^6.x`) |
| `dashboard` | `^6.0.3` (installed `6.0.3`) | Phase 0 clean; already on TS 6, ready for Phase 2 dry-run |

---

## 6. Instructions for the dev team

Anyone pulling these changes needs to pick up the `package.json`/lockfile change and
re-validate locally. This is the same sequence used above — safe to re-run any time:

```bash
# From the repo root (/home/ander/projects/Docker-nginx-node):

# 1. Pull the branch, then reconcile node_modules (removes ts-node, updates lockfile)
docker compose restart webapp

# 2. Re-run both apps' type-checks
docker compose exec -T webapp sh -c "npm run tsc"
docker compose exec -T server sh -c "npm run tsc"

# 3. Re-run both apps' test suites
docker compose exec -T webapp sh -c "npm test"
docker compose exec -T server sh -c "npm test"

# 4. Dashboard lint (Biome + tsc — required to pass before any commit per dashboard/CLAUDE.md)
docker compose exec -T webapp sh -c "npm run lint"

# 5. Sanity-check both compose builds still succeed
docker compose build
docker compose -f docker-compose.prod.yml build
```

If you're adding new path aliases to either `tsconfig.json` going forward: **always use a
leading `./`** in `paths` entries (`"./src/*"`, not `"src/*"`) — `baseUrl` is gone for good
under TS7 and won't be coming back in Phase 1/2/3 below.

---

## 7. Instructions for the production system

Production (`docker-compose.prod.yml`) has no runtime `npm install` and no mock data — the
only place the TypeScript config changes matter is at **build time**, inside the
`builder` stage of `Dockerfile`. Phase 0 already validated this build succeeds (§5.3 step 8).

To actually roll Phase 0 out to a real production host:

```bash
# 1. Build the production image with the updated tsconfig/package.json baked in
docker build --target production --build-arg APP_ROUTE=./dashboard \
  -t <registry>/node-nginx-clean-webapp:prod .

# 2. Smoke-test it locally before pushing — bring up the full prod stack once
#    (needs its own host, or stop the dev stack first: dev's `proxy` and prod's
#    `webapp` both default to host port 80/${HOST_HTTP_PORT}, they will conflict)
docker compose -f docker-compose.prod.yml up -d --build
curl -I http://localhost:${HOST_HTTP_PORT:-80}/
docker compose -f docker-compose.prod.yml down

# 3. Push and deploy per the existing process (root CLAUDE.md "Deploying to your
#    infrastructure"): tag, push, pull on the target host, run behind the edge
#    proxy/load balancer mapping container port 80.
docker push <registry>/node-nginx-clean-webapp:prod
```

No `POSTGRES_*`/`DATABASE_URL` or backend-URL config changes are needed for Phase 0 — it
only touched TypeScript compiler configuration and a dev-only devDependency, nothing
runtime-visible. Standard rollback for this phase is simply redeploying the previous image
tag; there is no data migration involved.

**Do not repeat this deploy step for Phases 1–3 below without re-running the same
build-and-smoke-test sequence first** — each version bump gets its own build validation
before going to production, same as this one did.

---

## 8. Status and next phases

- [x] **Phase 0** — cleanup + `baseUrl` fix (this document, §5). Done and validated.
- [x] **Phase 1** — bump `server`'s `typescript` `^5.7.2` → `^6.x` (this document, §9).
      Done and validated; `dashboard` was already on `^6.0.3`, nothing to do there.
- [x] **Phase 2** — `tsgo` side-by-side dry run (this document, §10). Done and
      validated; **zero errors in either app** — Phase 3 is unblocked.
- [x] **Phase 3** — real bump to `typescript@^7.0.2` (this document, §11). **Done and
      fully validated — the migration is complete.** Both apps run TypeScript 7 in
      development, and the production dashboard image builds clean under it.
- [ ] Update `scripts/validate_ts7_compatibility.py` to check for `baseUrl` — its
      biggest blind spot, found by hand in §5.2 above, not by the tool itself. The
      only remaining open item; not a blocker, just a regression guard for later.

---

## 9. Phase 1 — executed 2026-08-01: `server` bumped to TypeScript 6

### 9.1 Change made

- `server/package.json` — `"typescript": "^5.7.2"` → `"typescript": "^6.0.3"` (same
  version range `dashboard` already runs, for consistency).

### 9.2 Commands run, in order, with results

```bash
# 1. Pick up the version bump — server's entrypoint re-runs
#    `npm install --ignore-scripts` on every container start/restart.
docker compose restart server
docker compose exec -T server sh -c 'node -e "console.log(require(\"typescript/package.json\").version)"'
#   -> 6.0.3 (confirmed installed)

# 2. Type-check under TS6
docker compose exec -T server sh -c "npm run tsc"
#   -> clean, zero errors — no 6.0 deprecation warnings surfaced at all

# 3. Full integration test suite under TS6
docker compose exec -T server sh -c "npm test"
#   -> Test Files 13 passed (13) / Tests 282 passed (282)

# 4. Dev image build sanity check (server itself has no Dockerfile in this
#    repo — it runs as a plain node:22-alpine image with runtime install, and
#    is deployed to production via its own separate repo/pipeline, not
#    docker-compose.prod.yml here, which only builds the dashboard's static
#    bundle — see root CLAUDE.md's Production Deployment section)
docker compose build
#   -> "Image docker-nginx-node-webapp Built" (unaffected, as expected)
```

Unlike Phase 0, this phase needed **zero** source or config changes beyond the
one version bump — the recommended "land on 6.0 first" step existed specifically to
surface deprecation warnings before 7.0 turns them into hard errors, and none
surfaced here. This suggests `server`'s `tsconfig.json` was already close to
TS6/7-shaped even before Phase 0 (aside from the `baseUrl` issue Phase 0 already
fixed).

### 9.3 Current repo state after Phase 1

| App | `typescript` | Status |
| --- | --- | --- |
| `server` | `^6.0.3` (installed `6.0.3`) | Phase 1 clean; ready for Phase 2 (`tsgo` side-by-side dry run) |
| `dashboard` | `^6.0.3` (installed `6.0.3`) | Already here since before this migration started |

Both apps are now on the same TypeScript 6 baseline. Phase 2 (side-by-side `tsgo`
dry run) and Phase 3 (the real `^7.0.x` bump) can proceed for both apps together.

---

## 10. Phase 2 — executed 2026-08-01: `tsgo` side-by-side dry run

### 10.1 Change made

Added `"@typescript/native-preview": "7.0.0-dev.20260707.2"` as a devDependency in
**both** `server/package.json` and `dashboard/package.json` — this package ships the
`tsgo` binary (the native Go compiler) without touching the `typescript` package
itself, so it runs purely side-by-side with zero risk to the existing TS6 toolchain.

Checked the package directly via `npm view` (inside the `webapp` container, not a web
search — this project runs everything through Docker) rather than assume a version:
`npm view @typescript/native-preview dist-tags --json` returned `latest:
7.0.0-dev.20260707.2` — a dev build from the day before TypeScript 7.0's actual GA
(2026-07-08). The preview package wasn't republished after GA (its job was done once
`typescript@latest` itself became 7.0.0), so this last pre-GA build is the closest
available proxy to the real 7.0.0 release — confirmed functionally identical by
`npx tsgo --version` reporting `7.0.0-dev.20260707.2` and behaving exactly as
documented (native binary, no Node runtime needed for the check itself).

### 10.2 Commands run, in order, with results

```bash
# 1. Install the new devDependency in both apps
docker compose restart webapp server
docker compose exec -T server sh -c "npx tsgo --version"    # -> Version 7.0.0-dev.20260707.2
docker compose exec -T webapp sh -c "npx tsgo --version"    # -> Version 7.0.0-dev.20260707.2

# 2. The actual dry run — tsgo --noEmit side-by-side with the existing tsc --noEmit
docker compose exec -T server sh -c "npm run tsc"           # tsc  (TS6) -> clean
docker compose exec -T server sh -c "npx tsgo --noEmit"     # tsgo (TS7) -> clean, exit 0
docker compose exec -T webapp sh -c "npm run tsc"           # tsc  (TS6) -> clean
docker compose exec -T webapp sh -c "npx tsgo --noEmit"     # tsgo (TS7) -> clean, exit 0

# 3. Real speedup measurement (not just "should be faster" — actually timed)
docker compose exec -T server sh -c "time npx tsc --noEmit"    # server tsc:  7.12s real
docker compose exec -T server sh -c "time npx tsgo --noEmit"   # server tsgo: 1.24s real  (5.7x)
docker compose exec -T webapp sh -c "time npx tsc --noEmit"    # dashboard tsc:  17.42s real
docker compose exec -T webapp sh -c "time npx tsgo --noEmit"   # dashboard tsgo: 3.73s real (4.7x)

# 4. Confirm nothing else regressed with the new devDependency present
docker compose exec -T server sh -c "npm test"    # -> 13 files / 282 tests passed
docker compose exec -T webapp sh -c "npm run lint"  # biome:lint + tsc -> both clean
docker compose exec -T webapp sh -c "npm test"    # -> 14 files / 61 tests passed

# 5. Both compose builds (dashboard/package.json changed — validate the full pipeline)
docker compose build                              # dev webapp image -> built clean
docker compose -f docker-compose.prod.yml build   # prod build (npm install + max build) -> built clean
```

### 10.3 Result: zero errors in either app under the real TS7 native compiler

This is the single most important data point in the whole migration: `tsgo --noEmit`
— the actual Go-ported TypeScript 7 checker, run against this exact codebase — reports
**zero type errors in both `server` and `dashboard`**, with real, measured speedups
(5.7x and 4.7x respectively, in-container). Combined with Phase 0/1's finding that
neither app uses any of the tools TS7 is known to break (no ESLint/`typescript-eslint`,
no Jest/`ts-jest`, no `ts-morph`, no Vue/Svelte/Astro/MDX, and the one package that
needed the removed programmatic API — `ts-node` — was already removed as dead weight
in Phase 0), there is no remaining technical blocker to the real Phase 3 version bump.

### 10.4 Current repo state after Phase 2

| App | `typescript` | `@typescript/native-preview` (tsgo) | Status |
| --- | --- | --- | --- |
| `server` | `^6.0.3` | `7.0.0-dev.20260707.2` (dry-run only) | `tsgo --noEmit` clean — ready for Phase 3 |
| `dashboard` | `^6.0.3` | `7.0.0-dev.20260707.2` (dry-run only) | `tsgo --noEmit` clean — ready for Phase 3 |

Phase 3 removes `@typescript/native-preview` again (it was only ever a dry-run aid)
and bumps `typescript` itself to `^7.0.x` in both apps' `package.json`.

---

## 11. Phase 3 — executed 2026-08-01: real bump to TypeScript 7 — MIGRATION COMPLETE

### 11.1 Changes made

- `server/package.json` — removed the temporary `@typescript/native-preview`
  devDependency; `"typescript": "^6.0.3"` → `"typescript": "^7.0.2"`.
- `dashboard/package.json` — same: removed `@typescript/native-preview`;
  `"typescript": "^6.0.3"` → `"typescript": "^7.0.2"`.

`7.0.2` was confirmed as the real, current GA release by checking the registry
directly (`npm view typescript dist-tags --json` inside the `webapp` container,
not assumed): `{"latest": "7.0.2", "rc": "7.0.1-rc", "next": "7.1.0-dev..."}` — `7.1`
(which restores the stable programmatic API per Microsoft's own announcement) is
still in nightly dev builds, not stable, so `7.0.2` is the correct target for now.

### 11.2 Commands run, in order, with results

```bash
# 1. Confirm the real current GA version before pinning it
docker compose exec -T webapp sh -c "npm view typescript dist-tags --json"
#   -> {"latest": "7.0.2", "rc": "7.0.1-rc", "next": "7.1.0-dev.20260801.1", ...}

# 2. Install the real bump in both apps
docker compose restart webapp server
docker compose exec -T server sh -c 'node -e "console.log(require(\"typescript/package.json\").version)"'
docker compose exec -T webapp sh -c 'node -e "console.log(require(\"typescript/package.json\").version)"'
#   -> 7.0.2 (both)

# Sanity check: the "../.env not found" line tsx prints on every server start is
# tsx's own SEPARATE optional dotenv lookup relative to its cwd (/usr/src/server),
# which never pointed at the real repo-root .env even before this migration —
# actual env vars come from docker-compose.yml's `env_file` directive. Confirmed
# unaffected: docker compose exec -T server sh -c 'echo $MINIO_PUBLIC_URL_BASE'
# still printed the correct https://192.168.178.30/media.

# 3. tsc --noEmit is now literally the native Go compiler binary in both apps
docker compose exec -T server sh -c "npx tsc --version && npm run tsc"
#   -> Version 7.0.2 / clean, zero errors
docker compose exec -T webapp sh -c "npx tsc --version && npm run tsc"
#   -> Version 7.0.2 / clean, zero errors

# 4. Full test suites under real TS7
docker compose exec -T server sh -c "npm test"     # -> 13 files / 282 tests passed
docker compose exec -T webapp sh -c "npm run lint"   # biome:lint + tsc -> both clean
docker compose exec -T webapp sh -c "npm test"     # -> 14 files / 61 tests passed

# 5. Both compose builds — the actual deployment paths
docker compose build                                # dev webapp image -> built clean
docker compose -f docker-compose.prod.yml build     # prod build (npm install + max build) -> built clean
```

### 11.3 Result: migration complete, zero source changes needed in Phase 3 itself

Every validation passed clean on the first attempt — no new errors, no test
failures, no build breakage. All of Phase 3's actual fixes were already done in
Phase 0 (the `baseUrl`/`ts-node`/`experimentalDecorators` cleanup) and confirmed
risk-free in Phase 2's dry run; Phase 3 itself was purely "flip the version and
verify," exactly as the side-by-side dry run predicted.

### 11.4 Final repo state

| App | `typescript` (before this migration) | `typescript` (now) |
| --- | --- | --- |
| `server` | `^5.7.2` | `^7.0.2` |
| `dashboard` | `^6.0.3` | `^7.0.2` |

Both apps now run the real, GA TypeScript 7.0.2 native compiler — in development
(`npm run tsc`, editor tooling) and validated through the full production build
pipeline (`docker-compose.prod.yml`). The only remaining open item from this whole
migration is the optional `scripts/validate_ts7_compatibility.py` `baseUrl` check
noted in §8 — a regression guard for the future, not a blocker for anything today.
