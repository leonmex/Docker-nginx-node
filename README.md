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
