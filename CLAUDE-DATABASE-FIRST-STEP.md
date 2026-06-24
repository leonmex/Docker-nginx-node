# AGENT PROMPT: Platform Modernization - Phase 1: PostgreSQL & API Integration (Database-First Step)

You are tasked with executing **Phase 1 (Database-First Step)** of the platform modernization plan. Your goal is to replace the frontend mock data with a persistent PostgreSQL database and a dedicated backend API service designed with senior-level architecture patterns using **Fastify v5.8**.

---

## 1. Context & Objectives

Currently, the React/UmiJS dashboard relies on hardcoded Chinese-language mock data (`dashboard/mock/` files) and mock authentication. You must:
1. Setup a PostgreSQL database container and define a relational schema mapping the mock data models.
2. Implement an abstracted, production-grade backend API service in TypeScript using **Fastify v5.8** to handle authentication, user profiles, and dashboard data.
3. Write a seeding script to extract the mock data from `dashboard/mock/` and load it into PostgreSQL.
4. Modify the Nginx configuration to route `/api/*` requests to your new backend API service instead of the Umi dev server mock middleware.
5. Create a `migration_progress.md` file tracking completed and pending migration tasks to make subsequent phases easy to carry out.

---

## 2. Technical Stack & Environment

*   **Database**: PostgreSQL 18.4 (using the existing `dbPostgres` container).
*   **Cache Service**: Redis (add service to `docker-compose.yml` to support caching).
*   **Backend API**: Node.js v22 + TypeScript (**Fastify v5.8** framework).
*   **Frontend**: React (Umi Max v4 / Ant Design Pro) located in `dashboard/`.
*   **Orchestration**: Docker Compose, using Nginx to reverse-proxy the services.
*   **Security & Linters**: Strict Biome linting and TypeScript guidelines. No ESLint, no Prettier.
*   **Observability**: Structured logging via `pino` (JSON logs) behind an `ILogger` abstraction, designed to scale into an **OpenTelemetry** pipeline (traces/metrics/logs) later. No `console.log` in application code.
*   **No emojis**: Do not use emojis anywhere — not in docs, code, comments, log messages, or commit messages. Use plain-text status markers (Done / Pending / [x] / [ ]).

---

## 3. Core Architectural Abstractions (Senior Design Requirements)

To ensure the backend is secure, scalable, and maintainable, you must implement clean abstractions and interfaces. The application layer must not be coupled directly to database drivers or network topologies.

### A. Repository & Data Source Abstraction
*   **Interfaces First**: Define clear TypeScript interfaces for data access layers (e.g., `IUserRepository`, `INoticeRepository`, `IFakeListRepository`).
*   **Dependency Injection**: Fastify routes/services must request repositories through their interfaces, decoupling the controller logic from PostgreSQL.

### B. Connection & Read/Write Splitting Strategy
*   **Topology Abstraction**: Abstract the database connection pool using a client manager that supports read-write splitting:
    *   **Writes** (`insert`, `update`, `delete`) must route to the **Primary Database Master**.
    *   **Reads** (`select`) must route to a configurable **Read-Replica Slave** or the Cache layer.
*   **Interface Design**: Design connection interfaces (e.g., `IDatabaseConnectionManager`) that wrap separate read and write pools (e.g., `writeClient` vs `readClient`) to easily configure multi-node database clusters in production without modifying business queries.

### C. Cache-Aside & Technology-Agnostic Caching
*   **Cache Interface**: Define an `ICacheManager` interface containing methods like `get<T>`, `set`, `delete`, and `flush`.
*   **Decorator / Proxy Pattern**: Wrap your repositories with a cached implementation (e.g., `CachedUserRepository` implementing `IUserRepository`).
*   **Cache Strategy**:
    *   On a **Read Request**: Intercept with the Cache Manager, check Redis. On cache hit, return immediately. On cache miss, fetch from the PostgreSQL Read Replica, populate Redis, and return.
    *   On a **Write Request**: Write to the PostgreSQL Master, then invalidate/remove the corresponding cache keys in Redis.
*   **Flexibility**: The system must be configurable via environment variables (`USE_CACHE=true`, `CACHE_PROVIDER=redis`) and degrade gracefully if Redis is unavailable (falling back directly to database queries).

### D. Observability & Structured Logging
*   **Vendor-Agnostic Logger Abstraction**: Define an `ILogger` interface (`debug`, `info`, `warn`, `error`, `child`). Application code depends on `ILogger`, never on `console` or a concrete logger — so the observability backend (OpenTelemetry collector, Datadog, Grafana/Loki, plain stdout, …) can be swapped without touching business code.
*   **Structured JSON by Default**: Implement it with `pino` — JSON logs carrying a stable schema (`service`, `level`, `time`, `msg`, plus contextual fields: request id, user id, cache hit/miss, db role). Pretty-print only in development. A consistent JSON contract is what lets any collector ingest the logs.
*   **Pluggable Transport / Extension Point**: Keep output behind a transport seam (the concrete logger config), so a destination — vendor exporter, log shipper, file, stdout — can be added later without changing call sites.
*   **Correlation-Ready**: The logger must support `child()` bindings so per-request correlation context (request id, and later trace/span ids from whichever tracing system is chosen) can be attached. The Fastify server uses the same `pino` instance so every HTTP request/response is logged with a correlation id.

---

## 4. Strict Step-by-Step Execution & Testing Policy

To maximize token efficiency and prevent compilation/debugging loops, you must strictly adhere to the following development and testing workflow:

### A. Incremental Execution Checkpoints
*   Do **NOT** implement the entire database, repositories, caching, and controllers in one single pass. Implement them module by module.
*   Validate each milestone using tests and container status checks before moving to the next.

### B. Test-Driven Development (TDD) Preference
*   For all abstract interfaces (e.g., `ICacheManager`, `IDatabaseConnectionManager`, Repositories), write unit tests alongside the concrete implementations.
*   Setup a lightweight test runner (e.g., `Vitest` or `Jest`) inside the `server/` directory.
*   Test suites should include:
    *   **Unit Tests**: Mocking database and Redis responses to verify interfaces and caching logic.
    *   **Integration Tests**: Validating routing, validation middleware, and database connectivity.
*   Ensure that all tests compile and pass. If any test fails or TypeScript error occurs, **stop immediately and fix it**. Never write new code on top of a failing test suite.

### C. Step-by-Step Verification Flow
1.  **Step 1**: Start Postgres/Redis container and verify database connectivity with a basic connection test script.
2.  **Step 2**: Create repository interfaces and implement simple mock repositories. Run unit tests to check interface compliance.
3.  **Step 3**: Implement the database queries (DDL, seed script) and run database repository tests against a real/mocked Postgres instance.
4.  **Step 4**: Implement caching decorators and verify cache hit/miss behavior (with mocked Redis client).
5.  **Step 5**: Register routes in Fastify plugins and run API endpoint validation tests (using `fastify.inject` or equivalent).

### D. Observability Coverage (All Milestones)
*   **Every milestone must ship with basic observability** — structured logs through the `ILogger` abstraction (Section 3D), no `console.*` in application code.
*   Log the meaningful events per layer: startup/shutdown and config (sanitized), DB connectivity and which role (master/replica) served a query, cache hit/miss and degradation, request/response with a correlation id, and errors with stack context.
*   New modules added in a milestone are not "done" until their key paths emit logs and the logger remains swappable (no vendor lock-in).

---

## 5. Step-by-Step Implementation Roadmap

### Milestone 1: Database Setup & Seeding

1.  **Postgres & Redis Containers**:
    *   Add a Redis service to `docker-compose.yml`.
    *   Expose port `6379` internally to the network only.
2.  **Define DDL Schema**:
    Create a SQL schema file `server/db/schema.sql` containing:
    *   `users`: User profile details.
    *   `user_tags`: Relational table mapping tags to users.
    *   `dashboard_notices`: Notifications, activities, and counts.
    *   `fake_list`: Dashboard table lists.
3.  **Seeding Tooling**:
    Write a script `server/db/seed.ts` that parses raw mock data arrays from `dashboard/mock/` files, hashes passwords (using `bcrypt` or `Argon2id`), and seeds the tables.

### Milestone 2: Backend API Service (`server/`)

1.  **Initialize TypeScript API Server**:
    Initialize a TypeScript-configured **Fastify v5.8** server with Biome formatting. Install dependencies:
    ```bash
    npm install fastify@^5.8.0 @fastify/cors@^10.0.0 @fastify/cookie@^11.0.0
    ```
2.  **Apply Abstractions**:
    Develop connection pools, interfaces, and caching strategies outlined in Section 3.
3.  **Implement REST API Endpoints**:
    Register routes using Fastify plugins for:
    *   `POST /api/login/account`
    *   `POST /api/login/outLogin`
    *   `GET /api/currentUser`
    *   `GET /api/users`
    *   `GET /api/notices`

### Milestone 3: Docker & Proxy Integration

1.  **Adjust `docker-compose.yml`**:
    *   Add the `server` backend container.
    *   Ensure the Node debugger port `9229` is **not** exposed publicly to `0.0.0.0` (bind to `127.0.0.1:9229` or remove).
2.  **Adjust `nginx/default.conf`**:
    *   Update the `/api/` locations to point to your new backend API container:
        ```nginx
        location /api/ {
          proxy_pass http://server:5000;
          proxy_http_version 1.1;
          proxy_set_header Upgrade $http_upgrade;
          proxy_set_header Connection 'upgrade';
          proxy_set_header Host $host;
          proxy_read_timeout 86400s;
          proxy_send_timeout 86400s;
        }
        ```
    *   Clean up the unused ports `6277` and MCP/SSE location mappings.

### Milestone 4: Frontend Connector & Progress Logs

1.  **Disable Umi Mock Middleware**:
    Disable local dev server mocks.
2.  **Create Migration Progress File**:
    Initialize `migration_progress.md` in the project root documenting:
    *   Database schema status.
    *   API Endpoint migration checklist.
    *   List of remaining files inside `dashboard/mock/` that need to be transitioned in subsequent milestones.

---

## 6. Security & Hardening Rules for Execution

When implementing this task, you must strictly follow these security rules:
*   **No Hardcoded Secrets**: Load database credentials (`POSTGRES_USER`, `POSTGRES_PASSWORD`, `DATABASE_URL`, `REDIS_URL`) from environment variables (`.env`).
*   **Exfiltration Prevention**: Disable Google Analytics tracking in `dashboard/config/config.ts` (remove `analytics` block) and point the chatbot API in `dashboard/src/pages/chatbot/service.ts` to a local endpoint instead of `api.x.ant.design`.
*   **Secure Docker Network**: Ensure database and caching ports are not exposed on external interfaces.

---

## 7. Expected Deliverables

Provide the following directory structure:
```
├── migration_progress.md    # Migration tracking log
├── server/
│   ├── package.json
│   ├── tsconfig.json
│   ├── src/
│   │   ├── index.ts        # Server entrypoint and Fastify config
│   │   ├── config.ts       # Env configuration
│   │   ├── core/           # Interfaces, connections, cache & logging
│   │   │   ├── IDatabase.ts
│   │   │   ├── ICache.ts
│   │   │   ├── ILogger.ts   # Vendor-agnostic logging interface
│   │   │   └── logger.ts    # pino implementation + factory
│   │   ├── repositories/   # Abstracted repositories
│   │   ├── routes/         # Fastify route plugins
│   │   └── plugins/        # Custom Fastify plugins
│   └── db/
│       ├── schema.sql      # DDL SQL
│       └── seed.ts         # Mock-to-DB migration script
├── docker-compose.yml       # Updated Postgres, Redis, and Server services
└── nginx/
    └── default.conf        # Updated Nginx dev configuration
```

---

## 8. Communication & Validation

*   Validate PostgreSQL and Redis connectivity and verify that interface routing is operational before modifying frontend code.
*   Once finished, verify that the dashboard loads the user profile, lists, and notifications correctly from the PostgreSQL database through the caching layers, and document the remaining migration tasks in `migration_progress.md`.
