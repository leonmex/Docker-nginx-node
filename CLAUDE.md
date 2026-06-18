# Docker Setup & Instructions

This project has two Docker workflows:

- **Development** (`docker-compose.yml`) — fast iteration with the Umi dev server + mock data.
- **Production** (`docker-compose.prod.yml`) — static build served by nginx, no Node runtime.

The dashboard is Ant Design Pro (Umi Max v4 / antd v6), restricted to **en-US**, **de-DE**, **es-ES**.

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

## Production Deployment

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
