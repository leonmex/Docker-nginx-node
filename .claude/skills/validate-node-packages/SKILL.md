---
name: validate-node-packages
description: Validate npm package changes in this repo (server/ and dashboard/) before considering the work done — catches imports with no matching package.json entry, Node engine / peer-dep mismatches, and malformed package.json. Use whenever a task adds/removes/upgrades an npm dependency, adds a new `import`/`require` of an external package, or touches package.json/.npmrc in either workspace — e.g. "add package X", "install a new dependency", "upgrade Y", "npm install Z". Also use as a first check when a container is crash-looping with ERR_MODULE_NOT_FOUND or EJSONPARSE.
metadata:
  author: infra-team
  version: "1.0.0"
---

# Validate Node Packages

This repo runs `npm install` **at container start**, not at image build time (see root `CLAUDE.md`). That means a
missing or malformed dependency is never caught by `docker compose build` — it only surfaces when the process
actually tries to `import` it, inside a crash-restart loop that can run silently for a long time before anyone
notices (see Incident below). `npm install` exits `0` even when `package.json` is missing a package that the
source code imports — it only installs what's *listed*, it never reads `src/` to check what's *used*. Treat every
dependency change as incomplete until you've done the checks below, not just "I ran npm install and it printed no
errors."

There are two independent workspaces, each with their own `package.json` / `.npmrc` / runtime install:
- `server/` — Fastify API, `type: module`, ESM (`Cannot find package 'X' imported from ...`), `engines.node: >=22`.
- `dashboard/` — Ant Design Pro / Umi Max frontend, `engines.node: >=22.0.0`, requires `.npmrc` with
  `legacy-peer-deps=true` (the upstream lockfile drifts from `package.json`, so `npm ci` cannot be used — only
  `npm install`).

## Incident this skill exists for

2026-07-19: `server/src/index.ts` and `server/src/services/MinioObjectStorage.ts` imported `minio`, and
`server/src/app.ts` imported `@fastify/multipart` and `jsonwebtoken` — none of the three were ever added to
`server/package.json`. The container crash-looped (`npm install` succeeds → `npm start` → `ERR_MODULE_NOT_FOUND`
→ restart) for **~30+ minutes** while `dbPostgres`/`redis`/`minio`/`proxy` all reported healthy, so nothing else
looked wrong. The only user-visible symptom was `502`/`No route to host` on `/api/login/account` — real users
could not log in the entire time. Separately, `server/package.json` briefly had a stray trailing `}` (EJSONPARSE)
from a hand-edit. Both classes of bug are mechanically preventable — that's what the steps below check for.

## Step 1: Before adding a package — check compatibility

```bash
npm view <package> version                # latest version
npm view <package> engines                # does it require a newer Node than "engines.node" in this workspace?
npm view <package> peerDependencies        # peer deps this workspace's other packages must satisfy
npm view <package> types 2>/dev/null || echo "no bundled types — check @types/<package> exists"
```

- If `engines.node` for the candidate package exceeds the workspace's own `engines.node` (`>=22` for `server/`,
  `>=22.0.0` for `dashboard/`) or the Node version baked into the Dockerfile/compose (`node:22-alpine`), flag it —
  don't silently install and hope `EBADENGINE` is just a warning (it usually is, but confirm — a hard-incompatible
  native binding will not just warn).
- `dashboard/` already runs with `legacy-peer-deps=true`; that suppresses peer-dep *install* failures but not
  runtime incompatibility, so peer-dep warnings from `npm view` still matter.

## Step 2: Add the package to the right place

- Runtime import → `dependencies`. Only used in build tooling / tests → `devDependencies`.
- TypeScript workspace (`server/` is fully TS) and the package ships no bundled types → also add
  `@types/<package>` to `devDependencies` (mirror the existing `@types/bcryptjs`, `@types/pg` pattern in
  `server/package.json`).
- Pin the same way neighboring entries in that `package.json` are pinned (this repo uses `^x.y.z` caret ranges
  throughout both workspaces — don't switch styles).

## Step 3: Validate package.json is syntactically valid JSON

Do this after every manual edit, before moving on — a stray brace is invisible on read-back but breaks `npm
install` outright (`EJSONPARSE`) and every restart until fixed:

```bash
python3 -c "import json; json.load(open('server/package.json')); print('VALID JSON')"
python3 -c "import json; json.load(open('dashboard/package.json')); print('VALID JSON')"
```

## Step 4: Cross-check source imports against declared dependencies

This is the check that would have caught the `minio` / `@fastify/multipart` / `jsonwebtoken` gap immediately,
instead of 30 minutes into a crash loop. Run it for whichever workspace changed:

```bash
# server/ (run from server/)
grep -rhoE "from ['\"][a-zA-Z@][^'\"]*['\"]" src db 2>/dev/null \
  | sed -E "s/from ['\"]//; s/['\"]//" \
  | grep -vE "^(node:|@/|@db/)" \
  | sed -E 's#(@[^/]+/[^/]+|[^/@][^/]*).*#\1#' \
  | sort -u
```

Compare the output against `dependencies` + `devDependencies` in `package.json`. Anything present in the grep
output but absent from `package.json` **will** crash the process at runtime — it just hasn't tried to load that
code path yet. (`node:*` builtins and `@/`, `@db/` path aliases are filtered out — those aren't npm packages.)

For `dashboard/`, adjust the `grep` paths to `src` (Umi convention) and re-run the same comparison.

## Step 5: Prove it, don't assume it — restart and read the logs

A clean `npm install` is not evidence the app runs. Restart the actual service and tail logs until you see the
real startup line (e.g. `Server listening at http://...` for `server/`, or the Umi dev server URL for
`dashboard/`), not just "up to date, audited N packages":

```bash
docker compose restart server        # or: webapp
docker compose logs server --tail 40
```

If you see `ERR_MODULE_NOT_FOUND`, `EJSONPARSE`, or a fatal stack trace instead of the startup line, the change
is not done — go back to Step 4.

## Step 6: Log it

If this surfaced a new failure mode not already covered in `.claude/learned_lessons.md`, add an entry there per
the template at the bottom of that file — that log is what keeps the next session from re-discovering the same
gap the hard way.
