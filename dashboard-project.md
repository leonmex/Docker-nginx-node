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
