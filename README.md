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

## Database & Cache Administration

The backend application caches data (like user profiles and tags) in Redis to improve performance. If you modify PostgreSQL tables directly (e.g., updating the `user_tags` table), the dashboard might not update immediately due to caching (cached under `user:profile:<userid>` keys for 60 seconds).

Use the following commands to manage the database and cache.

### 1. Redis Cache Commands
* **Flush the entire cache**:
  ```bash
  docker compose exec redis redis-cli flushall
  ```
  *(Note: You can also use `flushdb` instead of `flushall` to clear only the current active database).*

* **Delete a specific cached user profile**:
  ```bash
  # Delete cache for a specific user ID (e.g., admin is '00000001')
  docker compose exec redis redis-cli del user:profile:00000001
  ```

### 2. Database Resets & Seeding
* **Reset and Seed the database**:
  This command will drop all existing data and re-apply the schema and seed data (re-creating default admin and user profiles).
  ```bash
  docker compose exec server npm run db:seed
  ```
  *Default Seeded Users:*
  - **Admin**: `admin` / `ant.design` (User ID: `00000001`)
  - **User**: `user` / `ant.design` (User ID: `00000002`)

* **Verify database & cache connectivity**:
  ```bash
  docker compose exec server npm run db:check
  ```

### 3. Direct Database Access
* **Access the PostgreSQL CLI**:
  ```bash
  docker compose exec dbPostgres psql -U postgres -d test
  ```
  *(Note: Adjust the `-U` and `-d` flags if you have changed the defaults in your `.env` file).*

* **Run a single SQL query directly**:
  ```bash
  docker compose exec dbPostgres psql -U postgres -d test -c "SELECT * FROM user_tags;"
  ```

## Notes

- The containers are configured to keep running (`tail -f /dev/null`) to allow for easy debugging and manual command execution inside the containers.
- `yarn install` / `npm install` steps in the Dockerfile are conditional, so the build will succeed even if `package.json` is missing in a subdirectory.
