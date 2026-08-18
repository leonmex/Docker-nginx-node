# Docker Setup & Instructions

This project has two Docker workflows:

- **Development** (`docker-compose.yml`) — fast iteration with the Umi dev server + mock data.
- **Production** (`docker-compose.prod.yml`) — static build served by nginx, no Node runtime.

The dashboard is Ant Design Pro (Umi Max v4 / antd v6), restricted to **en-US**, **de-DE**, **es-ES**.

- **Learnings & Skills Log**: Before starting any task, read `.claude/learned_lessons.md` to avoid repeating past errors. Update the log with new resolutions or techniques.
- **Comments & Docs**: All new code, schema tables, and routes must be fully documented and commented in English.

## Development — Key Architecture Decisions

1.  **Fast Builds (No build-time `npm install`)**:
    The package installation is skipped during `docker compose build` to keep build times virtually instantaneous.
2.  **Runtime Package Installation**:
    When the container starts, it automatically runs `npm install --ignore-scripts` before starting the application. This ensures any new dependencies added to `package.json` are installed without rebuilding the Docker image.
3.  **Volume Caching (named volume)**:
    `node_modules` is isolated and cached inside a **named** Docker volume `webapp_node_modules` mounted at `/usr/src/app/node_modules`, overlaying the host directory bind mount. The named volume **persists across `docker compose down`/`up`**, so the runtime `npm install` becomes a near-instant no-op (~20s reconcile) instead of a full ~2m reinstall. `docker compose down -v` wipes it for a forced clean reinstall. This also prevents conflicts with host-side dependencies and ensures high filesystem performance.

## Commands

### Building and Running the Services

*   **Build the services** (extremely fast):
    ```bash
    docker compose build
    ```
*   **Start the application**:
    ```bash
    docker compose up
    ```
*   **Stop the application**:
    ```bash
    docker compose down
    ```
*   **Reset packages / clean volume cache**:
    If you need to force a clean reinstall of all node packages, destroy the anonymous volumes:
    ```bash
    docker compose down -v
    docker compose up --build
    ```

### Accessing the Services

*   **Web Dashboard**: `http://localhost:3000` (runs Umi dev server with mock data)
*   **Nginx Proxy**: `http://localhost:80` (or `HOST_HTTP_PORT`)
*   **Database (PostgreSQL)**: `localhost:5432`

### Database & Cache Administration

*   **Flush Redis Cache**:
    ```bash
    docker compose exec redis redis-cli flushall
    ```
*   **Reset & Seed Database**:
    ```bash
    docker compose exec server npm run db:seed
    ```
*   **Check Database & Cache Connections**:
    ```bash
    docker compose exec server npm run db:check
    ```
*   **Access PostgreSQL CLI**:
    ```bash
    docker compose exec dbPostgres psql -U postgres -d test
    ```

## Production Deployment

**This project has a real, live AWS production deployment already built —
don't treat the generic instructions below as hypothetical.** Master
reference: `docs/DEPLOY-TO-AWS-STEP-BY-STEP.md` (status table, full
Terraform/EC2/OIDC/observability/SES architecture, step-by-step commands,
changelog of every real incident hit and how it was fixed). Read it before
touching prod infra. Quick orientation:

- **Terraform**: `infra/terraform/bootstrap/` (S3 state + DynamoDB lock) →
  `infra/terraform/environments/prod/` (RDS Postgres, EC2 app instance,
  GitHub OIDC deploy roles, security groups, budget alert). Always
  `terraform plan` and get explicit approval before `apply` — never skip
  the plan/cost review, even for near-$0 resources.
- **Compute**: one EC2 instance (`t3.small`) runs `server` + `dashboard` +
  the full observability stack (Prometheus/Loki/Grafana, logs shipped to
  Cloudflare R2) via `docker-compose.prod.yml`, pulled from GHCR. No SSH —
  access is via AWS SSM only (`docs/UPDATE-DATABASE-IP-CONNECTION-TO
  AWS-.md` covers both the RDS tunnel and EC2 shell/log access). `shop` has
  its own not-yet-applied EC2 instance/Terraform, paused pending go-ahead.
- **Deploy trigger**: each app repo's GitHub Actions workflow builds →
  pushes to GHCR → assumes an OIDC-federated IAM role (no static AWS keys
  in GitHub) → `aws ssm send-command` pulls and restarts the target
  container on the instance.
- **Email**: AWS SES, still in sandbox (can send, but only to
  verified/domain-matched recipients until production access is granted).
  SMTP credentials live in `system_settings` (DB), restorable after a DB
  reset via `server/devops/restoreProductionSecrets.ts` — see
  `SECRETES/PRODUCTION-SYSTEM-SETTINGS-SECRETS.md`.
- **Secrets**: real credentials never get committed — AWS Secrets Manager
  for anything the running app/CI needs, plus a matching file in
  `SECRETES/` (gitignored) for every credential, per that directory's own
  `README.md`.
- **Gotchas already hit and fixed**: `.claude/learned_lessons.md` Issues
  18–21 (DB reset mechanics, RDS SSL-over-SSM-tunnel, Docker
  bridge-network vs. SSM tunnel networking, `schema.sql`'s settings-restore
  pattern) and the nginx `resolver`/request-time-DNS fix described in
  `docs/DEPLOY-TO-AWS-STEP-BY-STEP.md` §8 — check these before re-deriving
  a fix for something that already has one.

The rest of this section (generic "ship to your infrastructure" steps)
still applies conceptually but describes the base image/container
contract, not this project's actual deploy pipeline — use the AWS doc
above for anything touching the real, live environment.

Production compiles the dashboard to static assets and serves them with nginx — **no Node.js, no runtime `npm install`, no mock data**. This is the image you ship to your infrastructure.

### Architecture

Multi-stage `Dockerfile`:

1.  **`builder` stage** — `npm install --ignore-scripts` (the upstream lockfile drifts from `package.json`, so `npm ci` cannot be used) then `npm run build` → static assets in `/usr/src/app/dist`. `package.json`, `package-lock.json` and `.npmrc` are copied before the source so the dependency layer is cached across source-only changes. `.npmrc` (`legacy-peer-deps=true`) **must** be present or `@utoo/pack` fails to resolve and the build breaks.
2.  **`production` stage** — `nginx:alpine` serving `dist/` via `nginx/prod.conf` (SPA fallback to `index.html`, long-lived cache for hashed `/static/` assets, gzip).

### Commands

*   **Build & run production locally**:
    ```bash
    docker compose -f docker-compose.prod.yml up -d --build
    ```
    Serves on `http://localhost:80` (override with `HOST_HTTP_PORT`).
*   **Stop**:
    ```bash
    docker compose -f docker-compose.prod.yml down
    ```
*   **Build just the image** (e.g. to tag & push to a registry):
    ```bash
    docker build --target production --build-arg APP_ROUTE=./dashboard \
      -t <registry>/node-nginx-clean-webapp:prod .
    docker push <registry>/node-nginx-clean-webapp:prod
    ```

### Deploying to your infrastructure

1.  Build the `production` image in CI (or locally) with the command above.
2.  Tag it for your registry and `docker push`.
3.  On the target host, `docker pull` the image and run it behind your edge proxy / load balancer, mapping container port `80`. The image is self-contained static content — scale it horizontally with no shared state.
4.  Point the dashboard's API calls at your real backend (production has **no mock data**); configure the backend URL via `config/proxy.ts` / runtime config and rebuild.
5.  Provision PostgreSQL separately (the bundled `dbPostgres` service is for convenience; use a managed/external DB in real infra) and set `POSTGRES_*` / `DATABASE_URL` accordingly.
