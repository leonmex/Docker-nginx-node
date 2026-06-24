We need to create an interactive database reset and restore script for our Node.js server. 

### Context & Codebase Reference
- **Database Connection Manager**: `@/core/PgConnectionManager` (returns `IDatabaseConnectionManager`).
- **Seed Fixtures**: `server/db/fixtures.ts` contains arrays `userSeeds`, `noticeSeeds`, `fakeListSeeds`, and `tagSeeds`.
- **Existing Seed Script**: `server/db/seed.ts` applies `schema.sql` and performs a full truncate/seed.
- **Cache Manager**: `@/core/cache` manages Redis caching. We must flush the cache (or delete relevant keys) when database records are modified so that the web dashboard updates instantly.

### Requirements
Create a new TypeScript script at `server/db/reset.ts` and add it to `package.json` as `"db:reset": "tsx --env-file-if-exists=../.env db/reset.ts"`. When run (via `npm run db:reset`), the script must prompt the user with 3 options:

1. **Option 1: Full Reset & Restore**
   - Truncates all tables (`users`, `user_tags`, `dashboard_notices`, `fake_list`, `dashboard_tags`).
   - Re-applies the schema from `server/db/schema.sql`.
   - Inserts all seed fixtures from `server/db/fixtures.ts`.
   - Flushes the Redis cache completely.

2. **Option 2: Table-Specific Reset & Restore**
   - Interactively list the tables (`users`, `user_tags`, `dashboard_notices`, `fake_list`, `dashboard_tags`).
   - Let the user select one or more tables to reset.
   - Truncate only the selected table(s) (handling foreign key cascades like `users` -> `user_tags`).
   - Restore only the corresponding fixtures for the selected table(s).
   - Flush the Redis cache.

3. **Option 3: ID Range Restore**
   - Ask the user to select the table (e.g., `users`, `user_tags`, `fake_list`, `dashboard_tags`).
   - Ask for a **Start ID** and an **End ID** (inclusive range of the primary key).
   - Delete rows in the database that fall within that range.
   - Insert/restore the records from the fixtures file whose primary keys fall within that range.
   - Invalidate the corresponding cache keys in Redis (e.g. `user:profile:<userid>`).

### Implementation Details
- Use Node 22's native `readline/promises` library to prompt the user in the CLI to avoid adding new npm packages.
- Ensure proper transaction management (`db.withTransaction`) so partial restores don't leave the database in an inconsistent state.
- Gracefully disconnect DB and Redis connections on exit or error.
