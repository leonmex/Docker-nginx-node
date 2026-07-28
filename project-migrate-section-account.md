# Feature Request: Account Section Endpoint Migration & Backend i18n

Migrate all `/api/` endpoints supporting the Account pages (`dashboard/src/pages/account/center` and `dashboard/src/pages/account/settings`) from legacy Express Mock data files in the frontend to the new PostgreSQL database and Fastify API in the server, integrating support for backend internationalization (i18n).

## 1. Current State
- **Legacy Mocks**: Account endpoints are defined across the following mock files:
  - `dashboard/mock/utils.ts` (contains `defaultUser`, avatar, titles, desc, covers, etc.)
  - `dashboard/src/pages/account/settings/_mock.ts` (implements `/api/accountSettingCurrentUser`, `/api/geographic/province`, `/api/geographic/city/:province`)
  - `dashboard/src/pages/account/center/_mock.ts` (implements `/api/currentUserDetail`, `/api/fake_list_Detail`)
- **Database Schema**: 
  - An existing `users` table contains the base fields mapping to `defaultUser`, and `user_tags` represents user tags.
  - No database tables currently exist for provinces, cities, user teams/projects, or detailed article list data (`fake_list_Detail`).
- **i18n State**: The frontend has i18n configured (in English, Spanish, German). However, backend/database-driven content is not internationalized, and backend error/status messages are currently hardcoded English strings.

## 2. Target State
- Migrate all settings and center account endpoints to the PostgreSQL database and Fastify server.
- Maintain backward compatibility of the frontend dashboard pages with the migrated server API routes.
- Implement i18n support in the backend: API responses (including error messages) and database seed data must adapt based on the client's language preference (`Accept-Language` header supporting `en`, `es`, `de`).
- **Target Countries**: Seed geographic data (provinces/states and cities) for **Spain**, **Germany**, **England**, and **Mexico**.

## 3. Requirements

### A. Database Schema & Migration
1. **Extend DB Schema**:
   - Create any additional tables required (e.g., tables for `countries`, `provinces`, `cities`, `user_projects`, or expanding `fake_list` if necessary) in `server/db/schema.sql`.
   - Update `server/db/fixtures.ts` to include clean, internationalized seeds for the 4 target countries (Spain, Germany, England, and Mexico), including their provinces/states and cities.
   - Maintain compatibility of `server/db/seed.ts` and `server/db/reset.ts` with the new tables.
2. **Migrations**:
   - Write SQL migrations (similar to existing migration scripts in `server/db/migrations/`) to define the schema updates safely.

### B. Endpoint Migration (Fastify Routes)
1. **Extend Existing API Routing**: Instead of introducing completely new routing files, extend the existing `server/src/routes/auth.ts` and `server/src/routes/users.ts` files to handle the new endpoints:
   - `GET /api/accountSettingCurrentUser`
   - `GET /api/geographic/countries`
   - `GET /api/geographic/province`
   - `GET /api/geographic/city/:province`
   - `GET /api/currentUserDetail`
   - `GET /api/fake_list_Detail`
2. **Centralized Security**: Implement a reusable Fastify decorator (e.g., `app.decorate('authenticate', ...)` or a shared preHandler hook) to validate the session cookie. Secure all endpoints using this single decorator/hook so that future security refactoring (e.g. migrating to OAuth or JWT) can be done in one place.
3. Preserve the exact response payload structures expected by the frontend.

### C. Backend i18n Support
1. Implement a backend localization helper/middleware that reads the `Accept-Language` header (defaulting to `en`) and returns localized strings for backend messages and database seeds where applicable.
2. Ensure all user-facing responses avoid hardcoded non-English text.

### D. API Response Structure
- All user-facing endpoints must return the standard response structure defined in the server code:
  - Success cases: `{ success: true, data: ... }`
  - Error/Failure cases: `{ success: false, errorCode: string, errorMessage: string }`

### E. Verification & Testing
- Write integration tests inside the `server/test` directory covering all new endpoints, verifying:
  - Correct response shapes
  - Authentication checks (401 when session cookie is missing)
  - Backend localization (testing header value `de`, `es`, and `en` returns correct strings)
- Verify that the frontend compiles (`npm run build`) and correctly fetches data from the backend proxy without console warnings or errors.