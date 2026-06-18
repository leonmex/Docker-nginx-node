# Project Plan: Ant Design Pro Multi-Language Docker Deployment

## 1. Project Overview
**Objective:** Deploy a fully functional, enterprise-grade Ant Design Pro dashboard using existing local Docker configurations. 
**Core Constraint:** The application must strictly operate in **English (en-US)**, **German (de-DE)**, and **Spanish (es-ES)**. All other languages must be completely removed from the codebase, configuration, and UI.

## 2. Prerequisites
- Node.js (v18+) and Yarn/npm installed locally (for initial setup/translations if needed).
- Use our Docker compose .
- Existing Docker configuration (`Dockerfile`, `docker-compose.yml`, etc.) present in the root directory.
- 
---

## 3. Execution Phases

### Phase 1: Repository & Docker Integration
1. **Dashboard:**
The project is https://github.com/ant-design/ant-design-pro.git and is clone in the directory 
/Users/nbarrera/projects/Docker/node-nginx-clean/dashboard

### Phase 2: Integrate Docker Configuration:
Ensure the existing Dockerfile in the root directory is configured for a multi-stage React/UmiJS build.
Build Stage: Install dependencies (yarn install) and build the production assets (yarn build).
Serve Stage: Use an Nginx alpine image to serve the ./dist folder.
Ensure docker-compose.yml maps the correct ports (e.g., 80:80) and mounts any necessary environment variables.
Phase 2: Internationalization (i18n) Overhaul (Strict EN, DE, ES)
Ant Design Pro uses UmiJS for routing and @umijs/plugin-locale for internationalization.
Update Umi Configuration (config/config.ts or .umirc.ts):
Locate the locale configuration block and restrict it strictly to the three target languages.

### Phase 3: Clean Up Locale Directories:
Navigate to src/locales/.
DELETE on safe way search for dependencies for those languages that are not en-US, de-DE, or es-ES and can break the dashboard if not exist like ja-JP or zh-CN 
Target removals: zh-CN, zh-TW, pt-BR, it-IT, ja-JP, etc.
Ensure the folder structure remains intact

### HINT YOU CAN USE /Users/nbarrera/projects/Docker/node-nginx-clean/dashboard/AGENTS.md
### AFTER execute and made run the dashboard read the /Users/nbarrera/projects/Docker/node-nginx-clean/dashboard/CLAUDE.md

---

### Phase 4: Backend & Database (Database-First Step)

Replaces the dashboard mock data with **PostgreSQL + a Fastify v5.8 TypeScript API**
in `server/`. Full agent spec: [`CLAUDE-DATABASE-FIRST-STEP.md`](./CLAUDE-DATABASE-FIRST-STEP.md).
Live progress, endpoint checklist, and **production trade-offs**:
[`migration_progress.md`](./migration_progress.md).

**Done (Milestone 1):**
- PostgreSQL `18.4` + Redis added to `docker-compose.yml`; new container-first `server` service.
- Relational schema (`server/db/schema.sql`) mapping the mocks: `users`, `user_tags`, `dashboard_notices`, `fake_list`.
- Seed script (`server/db/seed.ts`) extracting mock data into the DB with bcrypt-hashed passwords.
- Senior abstractions: read/write-splitting connection manager (`server/src/core/`) with `withTransaction` / `withoutTransaction`.
- 14 passing tests (`docker compose run --rm server npm test`).

**Pending:** repositories + cache-aside (Redis), the five `/api/*` Fastify endpoints,
nginx `/api/` → `server:5000` proxy, and disabling the Umi mocks. See `migration_progress.md`.

> **Container-first:** never run `npm install`/tests on the host. Use
> `docker compose run --rm server npm run <db:check|db:seed|test>`.

> **EN/DE/ES constraint reminder:** the seeded mock content is still zh-CN — it must
> be localized/replaced before release (tracked as a trade-off in `migration_progress.md`).
