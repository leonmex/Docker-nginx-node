# CLAUDE-SECURITY.md: Project Security Auditing Plan

This document defines a structured plan and set of instructions for Claude to audit and check for security vulnerabilities in this repository, focusing on third-party dependencies, custom scripts, and runtime environment settings.

---

## 1. Third-Party Dependency Audit

Audit the project's dependencies to ensure they are free of known vulnerabilities (CVEs), prioritizing UI components, utilities, and build-time packages.

### 📋 Checklist & Tasks

- [ ] **Run Automated Vulnerability Scans**:
  - Navigate to the `dashboard` directory: `cd dashboard`
  - Run `npm audit` to check for known vulnerabilities in the dependency tree.
  - Review the severity levels (Critical, High, Moderate, Low).
- [ ] **Special Focus: `@ant-design/*` & `antd` Audit**:
  - Inspect the specific versions of all `@ant-design` packages and `antd` currently defined in `package.json`:
    - `antd` (`^6.4.3`)
    - `@ant-design/icons` (`^6.2.3`)
    - `@ant-design/plots` (`^2.6.8`)
    - `@ant-design/pro-components` (`^3.1.12-0`)
    - `@ant-design/x`, `@ant-design/x-markdown`, `@ant-design/x-sdk` (`^2.8.0`)
    - `@ant-design/cli` (`^6.4.3`)
  - Cross-reference these versions with the **GitHub Advisory Database** or the **Snyk Vulnerability Database** for known advisories relating to `antd` or `umi` plugins.
  - Identify any insecure configurations, prototypes pollution risks, or XSS vectors in those versions.
- [ ] **Lockfile Drift Analysis**:
  - Verify if `package-lock.json` is in sync with `package.json` in `dashboard`. 
  - Ensure there are no unexpected dependencies introduced via peer-dependency resolutions (like `@utoo/pack` hoisting quirks).
- [ ] **Mitigation & Fixes**:
  - Run `npm audit fix` where applicable.
  - For critical/high vulnerabilities that cannot be auto-fixed, plan manual version bumps in `package.json` and verify there are no breaking API changes.

---

## 2. Custom Scripts Security Audit

Inspect the custom Node.js utility scripts located under `dashboard/scripts/` to ensure they do not introduce security risks or reliability issues.

### 📋 Checklist & Tasks

- [ ] **Audit `dashboard/scripts/i18n-remove.js`**:
  - **File Operations**: Check for recursive file deletions (`fs.rmSync`, `fs.rmdirSync`) or overwrites. Ensure they validate paths to prevent directory traversal or accidental deletion of critical system files.
  - **Dynamic Command Execution**: Look for usage of `child_process.exec`, `eval`, or `Function` that could permit arbitrary code execution if script arguments are manipulated.
  - **Regular Expressions**: Check for complex regular expressions (specifically those processing local source code) that could trigger ReDoS (Regular Expression Denial of Service).
- [ ] **Audit `dashboard/scripts/simple.js`**:
  - **Irreversibility Analysis**: As noted, this script irreversibly modifies the codebase (removing features). Check if there are guardrails (like checking for uncommitted git changes or prompting the developer) to prevent accidental execution.
  - **File Manipulation Safeguards**: Ensure path operations are resolved safely (`path.resolve` or `path.join`) and do not accept unsanitized relative paths.
- [ ] **Check CI/CD or Husky Hooks**:
  - Review `dashboard/package.json` scripts such as `prepare` (`npx husky && max setup`) to make sure third-party scripts/pre-commit hooks cannot run arbitrary/unvetted commands.

---

## 3. Docker & Infrastructure Security Audit

Review the container configurations in the root directory to minimize attack surfaces and secure the development/production environments.

### 📋 Checklist & Tasks

- [ ] **Image Vulnerabilities & Version Pinning**:
  - Check the base images in `Dockerfile`:
    - `node:${NODE_VERSION}-alpine${ALPINE_VERSION}` (currently node 22 + Alpine 3.20)
    - `nginx:latest` or `nginx:alpine` in production configurations.
  - Verify that we pin minor/patch releases rather than utilizing mutable tags (e.g. `:latest`) to prevent unexpected image drift containing new vulnerabilities.
- [ ] **Privilege Minimization**:
  - By default, the containers run as `root`. Audit whether the `webapp` service can be configured to run under the built-in non-root `node` user:
    - Add `USER node` to the `Dockerfile` after system dependency installs.
    - Check if file/directory ownership needs to be adjusted (`chown -R node:node /usr/src/app`).
- [ ] **Secrets Management**:
  - Review the environment variables in `docker-compose.yml` and the local `.env` configuration.
  - Ensure no production passwords, tokens, or private keys are hardcoded in the configuration files or Docker images.
  - Ensure `.env` is properly excluded via `.dockerignore` and `.gitignore`.

---

## 4. Frontend Application Security (Code Auditing)

Review code patterns in `dashboard/src/` to prevent common frontend security vulnerabilities.

### 📋 Checklist & Tasks

- [ ] **Cross-Site Scripting (XSS)**:
  - Search the codebase for instances of `dangerouslySetInnerHTML`.
  - Review markdown components (`@ant-design/x-markdown`, `highlight.js`) to ensure rendered markdown HTML is properly sanitized.
- [ ] **Route Access Controls & Guarding**:
  - Review `dashboard/src/access.ts` and `dashboard/config/routes.ts`.
  - Ensure all routes requiring specific privilege roles are explicitly mapped with correct `access` keys.
- [ ] **Autofill Security**:
  - Ensure form input fields (especially authentication or credit card inputs) have correct `autocomplete` and `name` attributes, preventing browser autofill warnings or data harvesting.

---

## 5. Potential Data Backdoors & Exfiltration Channels

Audit configured endpoints, telemetry settings, and open ports that could leak information or act as backdoors to external servers.

### 📋 Checklist & Tasks

- [ ] **Google Analytics Tracking (Telemetry Leak)**:
  - In `dashboard/config/config.ts`, check the `analytics` configuration setting (`ga_v2: 'G-59NF1VHHPF'`).
  - Google Analytics is enabled by default in the Umi Max configuration. In environments handling sensitive customer data, this automatically exfiltrates page views, routes visited, browser details, and user actions to Google.
  - **Action**: Disable or delete the `analytics` block in `config/config.ts` if analytics tracking is prohibited.
- [ ] **Third-Party Chatbot API (Information Leak)**:
  - In `dashboard/src/pages/chatbot/service.ts`, verify the `CHAT_API_URL` which defaults to `https://api.x.ant.design/api/big_model_glm-4.5-flash`.
  - Prompts entered into the chatbot page are sent directly to this external Ant Design demo endpoint.
  - **Action**: Ensure this is redirected to your own internal LLM endpoint or disabled before processing any sensitive or proprietary inputs.
- [ ] **Test Proxy Endpoint (Data Exfiltration Risk)**:
  - In `dashboard/config/proxy.ts`, review the proxy target for `test`: `https://pro-api.ant-design-demo.workers.dev`.
  - If the app is run under the `test` environment, all API requests (`/api/*`) are proxied to this third-party Cloudflare Worker.
  - **Action**: Ensure this target is removed or updated to an internal test endpoint.
- [ ] **Port 6277 / MCP / SSE Reverse Proxy Mapping**:
  - In `nginx/default.conf` and `docker-compose.yml`, notice that port `6277` is exposed to the host and Nginx proxies `/config`, `/health`, `/sse`, `/message`, `/mcp`, `/stdio` to the `webapp` service.
  - If a local developer server, tool, or Model Context Protocol (MCP) daemon is running on port 6277 inside the webapp container, exposing this port allows anyone on the local network (or hosting environment) to potentially query the API, read files, or control the container environment.
  - **Action**: Verify why port `6277` and these proxy locations are exposed, and remove them if they are not actively required for local debugging or agent tools.

