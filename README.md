# Node Nginx Clean

A clean and modular Docker environment for Node.js applications served with Nginx. This setup includes configurations for a webapp, GraphQL service, and TypeScript support, orchestrated via Docker Compose.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/)
- [Docker Compose](https://docs.docker.com/compose/install/)

## Getting Started

1.  **Clone the repository:**

    ```bash
    git clone <repository-url>
    cd node-nginx-clean
    ```

2.  **Environment Setup:**
    Duplicate the `.env-example` file to `.env` (if applicable) and configure your environment variables.

    > [!IMPORTANT]
    > The `APP_ROUTE` variable in `.env` must point to the absolute path where your project source code resides. Additionally, the target project **must** contain a `Dockerfile` compatible with the one provided in this repository (e.g., matching build stages and arguments).

    ```bash
    cp .env-example .env
    ```

3.  **Build and Run:**
    Use Docker Compose to build and start the services.
    ```bash
    docker-compose up --build
    ```

## Directory Structure

- `nginx/`: Nginx configuration files.
- `docker/`: Docker-specific configurations and entrypoint scripts.
- `graphql/`: GraphQL service source code.
- `typescript/`: TypeScript service source code.
- `Dockerfile`: Multi-stage Dockerfile defining the service images.
- `docker-compose.yml`: Defines the services, networks, and volumes.

## Services

- **webapp**: The main Node.js web application.
- **proxy**: Nginx reverse proxy serving the application.
- **dbPostgres**: PostgreSQL database.
- _(Optional/Commented)_: Elasticsearch, GraphQL, TypeScript services.

## Notes

- The containers are configured to keep running (`tail -f /dev/null`) to allow for easy debugging and manual command execution inside the containers.
- `yarn install` / `npm install` steps in the Dockerfile are conditional, so the build will succeed even if `package.json` is missing in a subdirectory.

## Recent Debugging & Resolution Notes

During development and environment setup, the following issues were resolved to ensure the application builds, hydrates, and renders correctly across all locales and screen sizes:

### 1. Vite Outdated Optimize Dep 504 Errors (Dev Toolbar)
* **Issue:** In development mode, Astro's dev-toolbar requests static JS assets (`astro-BKQCAMZY.js`, etc.) that frequently fall out of sync with Vite's optimized dependency cache after configuration updates, throwing `net::ERR_ABORTED 504 (Outdated Optimize Dep)` in the browser console.
* **Fix:** Disabled the Astro dev toolbar in the configuration file.
* **Location:** [astro.config.mjs](file:///Users/nbarrera/projects/Docker/node-nginx-clean/astro.config.mjs#L15-L17) (added `devToolbar: { enabled: false }`).

### 2. React Hydration Mismatches (Password Manager Injection)
* **Issue:** Browser extensions (such as LastPass or 1Password) dynamically inject form overlay elements (like `data-lastpass-icon-root`) into input containers within SSR-rendered client components (specifically the contact form) before React hydration begins, causing a hydration mismatch.
* **Fix:** Added `suppressHydrationWarning={true}` on the form container and individual inputs, and set `data-lpignore="true"` on the input/textarea fields to block password managers from injecting overlay elements.
* **Location:** [ContactForm.tsx](file:///Users/nbarrera/projects/Docker/node-nginx-clean/src/components/ContactForm.tsx#L64-L123).

### 3. React 19 `react-dom/client` `createRoot` Hydration Syntax Error
* **Issue:** Vite fails to automatically pre-bundle the CommonJS format of React 19's `react-dom/client` entry point. The browser attempts to load the raw file directly, which lacks the named `createRoot` ESM export and throws a syntax error.
* **Fix:** Explicitly listed `react-dom/client` in Vite's `optimizeDeps.include` config to force ESM pre-bundling. The local Vite cache was cleared (`rm -rf node_modules/.vite`) and the container restarted to build fresh dependencies.
* **Location:** [astro.config.mjs](file:///Users/nbarrera/projects/Docker/node-nginx-clean/astro.config.mjs#L19-L22) and the running container's volume.

### 4. Alpine Node.js Version Downgrade
* **Issue:** The `node:22-alpine` base image has Node v22 preinstalled, but running `apk add nodejs` automatically pulled and installed Alpine's repository version (v20), overwriting and downgrading the Node binary.
* **Fix:** Removed the redundant `nodejs` and `yarn` packages from the Alpine `apk add` list to preserve the native v22 pre-installation.
* **Location:** [Dockerfile](file:///Users/nbarrera/projects/Docker/node-nginx-clean/Dockerfile#L11-L16).

### 5. PDF Parser Summary Truncation
* **Issue:** The summary parser script used a lookahead regex matching the word `"Experience"`. Because the first summary sentence contained the word `"experience"`, the parser cut off the summary prematurely.
* **Fix:** Updated the lookahead in the regex to only match section headings like `Current Employment` or `Employment`.
* **Location:** [parse-pdf.mjs](file:///Users/nbarrera/projects/Docker/node-nginx-clean/scripts/parse-pdf.mjs#L76).

### 6. Responsive Layout & Mobile Navigation Menu
* **Issue:** Grids, headers, and CTA layouts wrapped awkwardly or overflowed on screen widths below 768px.
* **Fix:** 
  * Replaced the desktop header links with a collapsible mobile navigation drawer toggled via a hamburger button in the sticky nav.
  * Added CSS overrides to scale displays, collapse column grids to 1-column layouts, stack CTA buttons, and adjust margins/paddings.
* **Location:** [Header.astro](file:///Users/nbarrera/projects/Docker/node-nginx-clean/src/components/Header.astro) and [global.css](file:///Users/nbarrera/projects/Docker/node-nginx-clean/src/styles/global.css#L1213-L1365).

