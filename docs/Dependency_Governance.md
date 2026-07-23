# Dependency Governance & Zero-Breakage Build Strategy

## Goal Description
Establish a robust, enterprise-grade dependency management strategy for `node-nginx-clean` across the `server` (Fastify / Node.js backend) and `dashboard` (React / UmiJS frontend) TypeScript applications. 

Currently, both Docker containers execute `npm install --ignore-scripts` dynamically at container startup or build time because the lockfiles have drifted from `package.json`. This introduces serious engineering risks:
1. **Non-deterministic Builds**: Every `docker-compose up` or rebuild dynamically pulls floating semver updates from the npm registry, risking silent runtime breakages.
2. **Container Boot Overhead**: `npm install` runs on every container startup, drastically slowing down developer feedback loops.
3. **Dependency Version Drift**: Incompatibilities between shared toolchains (e.g., `typescript`, `@types/node`, `@biomejs/biome`, `vitest`) across `server` and `dashboard`.
4. **Supply Chain Security Risk**: Unpinned dynamic installations bypass strict lockfile integrity verification (`npm ci`).

This strategy eliminates dynamic container installs, synchronizes lockfiles, introduces strict build immutability, and establishes a safe dependency upgrading pipeline.

---

## Strategic Operational Options

> [!IMPORTANT]
> **Option Decision: Root NPM Workspaces Monorepo vs. Independent Locked Applications**
> Two operational models are evaluated for long-term dependency management:
> 
> - **Option A (Recommended: Integrated NPM Workspaces Monorepo)**: Convert the repository root into a unified NPM Workspace containing `server` and `dashboard` as packages. This creates a single root `package-lock.json`, deduplicates shared dependencies (e.g., TypeScript, Biome, Vitest), enforces atomic upgrades across the entire system, and guarantees 100% deterministic builds.
> - **Option B (Independent Synchronized Lockfiles)**: Keep `server` and `dashboard` as distinct packages with independent `package-lock.json` files, but mandate pre-commit lockfile synchronization and enforce strict `npm ci` inside Docker builds without workspaces.

> [!WARNING]
> Switching from `npm install` to `npm ci` inside Docker requires an immediate one-time audit and regeneration of `package-lock.json` for both `server` and `dashboard` so that `package.json` and `package-lock.json` are strictly aligned.

---

## Technical Strategy & Architecture

```
+-----------------------------------------------------------------------------------+
|                     DEVELOPER / CI PIPELINE ENVIRONMENT                           |
|  1. Developer locks deps locally via `npm install` (generates sync'd lockfile)    |
|  2. Git pre-commit check validates package.json <-> package-lock.json parity      |
|  3. Automated Vitest suite (>89% unit tests) & smoke tests run on PR update       |
+------------------------------------------+----------------------------------------+
                                           |
                               Git Commit & Push
                                           |
+------------------------------------------v----------------------------------------+
|                     DOCKER & CONTAINER EXECUTION (DEV & PROD)                      |
|  1. Dockerfile / docker-compose uses `npm ci --ignore-scripts`                    |
|  2. Dynamic runtime `npm install` removed from docker-compose startup             |
|  3. Pre-installed node_modules cached in Docker layers / persistent volumes       |
+-----------------------------------------------------------------------------------+
```

---

## Proposed System Modifications

### Component 1: Lockfile Synchronization & Deterministic Installs

#### 1. Server Package Lockfile
- Synchronize `server/package-lock.json` against `server/package.json` to eliminate version drift and allow clean `npm ci` runs.

#### 2. Dashboard Package Lockfile
- Synchronize `dashboard/package-lock.json` against `dashboard/package.json` to eliminate version drift and allow clean `npm ci` runs.

---

### Component 2: Docker Build & Compose Strategy

#### 1. Dockerfile Update
- Replace `RUN npm install --ignore-scripts` in `builder` stage with `RUN npm ci --ignore-scripts`.
- Add an explicit `npm ci` build stage for `webapp` dev image so runtime container startup does not execute network downloads.

#### 2. Docker Compose Update
- Change container startup commands from:
  `command: sh -c "npm install --ignore-scripts && npm run dev"`
  to:
  `command: npm run dev` (for webapp)
  and:
  `command: npm start` (for server).
- Rely on cached Docker image `node_modules` or pre-built volume images using `npm ci`.

---

### Component 3: NPM Workspaces Monorepo Setup (Option A Target)

#### Root Package Definition (`package.json`)
- Define root workspace configuration:
```json
{
  "name": "blablarags-monorepo",
  "private": true,
  "workspaces": [
    "server",
    "dashboard"
  ],
  "scripts": {
    "dev:server": "npm run dev --workspace=server",
    "dev:dashboard": "npm run dev --workspace=dashboard",
    "test": "npm run test --workspaces --if-present",
    "lint": "npm run lint --workspaces --if-present",
    "tsc": "npm run tsc --workspaces --if-present"
  }
}
```

---

### Component 4: Pre-Commit Lockfile Guard & CI Safety Net

#### Lockfile Parity Script (`scripts/check-lockfile-sync.sh`)
- Shell script for Git hook / CI pipeline that verifies `npm ci --dry-run` or checks if `package.json` was modified without updating `package-lock.json`.

---

## Verification Plan

### Automated Verification
1. **Lockfile Alignment Check**:
   Run `npm ci` inside `server` and `dashboard` locally to verify 0 exit code without drift warnings.
2. **Container Build Verification**:
   Run `docker compose build --no-cache` to ensure images compile deterministically offline without network drift.
3. **Regression Test Suite**:
   Run `npm run test` (Vitest unit test suite) in `server` and `dashboard` to ensure all existing functionality and unit tests pass.
4. **Smoke Test Execution**:
   Run `./server/scripts/smoke-test-your-products.sh` against running containers to verify API & product listing endpoints.

### Manual Verification
1. Verify container startup time before and after removing runtime `npm install` (target reduction: from ~15-30s down to <2s).
2. Validate frontend SPA loading at `http://localhost:3000` and API endpoint `/health` at `http://localhost:5000`.
