# Technical Report & Architectural Analysis: Database Trade-Off with Numeric ID Sequences Across Stack

This document defines the senior data engineering analysis, root cause evaluation, cross-stack serialization hazards, and concrete resolution plan for item numeric ID sequence jumps ($10^6 \to 10^9$) across **PostgreSQL Backend**, **Fastify REST API**, **Ant Design Pro Dashboard**, and **Flutter Mobile SQLite**.

---

## 1. Root Cause & Architectural Trade-Off Analysis

### 1.1. Trade-Off 1: PostgreSQL 32-Bit `SERIAL` Overflow Hazard

- **Current Database State**: In `server/db/migrations/0004_blablarags_catalog_and_profiles.sql`, the `product_items.id` column is defined as `SERIAL PRIMARY KEY`:
  ```sql
  CREATE TABLE IF NOT EXISTS product_items (
    id SERIAL PRIMARY KEY,
    group_id INTEGER NOT NULL REFERENCES product_groups(id) ON DELETE CASCADE,
    ...
  );
  ```
- **Technical Limitation**: `SERIAL` creates a 32-bit signed integer sequence (`-2,147,483,648` to `2,147,483,647`).
- **The Hazard**: When application updates or cross-team sequence offsets jump `item_id` values from `1,000,000` to `1,000,000,000` (1 Billion), the table consumes **46.5%** of its absolute 32-bit integer capacity. Any further sequence increments, batch data imports, or multi-region allocation offsets will crash PostgreSQL with an unrecoverable runtime exception:
  ```sql
  ERROR: integer out of range (PGCODE 22003)
  ```
- **Required Resolution**: Upgrade `product_items.id` and all referencing foreign keys (`item_images.item_id`, `ai_training_queue.item_id`) from `SERIAL`/`INTEGER` to `BIGSERIAL`/`BIGINT` (64-bit signed integers supporting values up to $9.22 \times 10^{18}$).

---

### 1.2. Trade-Off 2: Primary Key Mutability Anti-Pattern & Mobile SQLite Cache Mismatch

- **The Problem**: Re-allocating, regenerating, or incrementing `item_id` whenever an item is edited or updated by different teams violates **Primary Key Immutability**.
- **Impact on PostgreSQL Backend**:
  - Updating primary keys requires cascading updates across `item_images`, `ai_training_queue`, and `user_action_logs`.
  - Triggers table lock escalation, foreign key constraint evaluation overhead, and high write amplification.
- **Impact on Flutter Mobile SQLite (`blablaragsandrigs`)**:
  - The Flutter application caches catalog items in an on-device SQLite database mapped by `item_id`.
  - When the server assigns a new `item_id` for an updated item (e.g. changing `1000000` to `1000000000`), Flutter's local SQLite cannot match the updated item against the existing local primary key.
  - **Downstream Bugs**: Duplicate item cards on mobile feeds, orphaned image caches, missing update notifications, and synchronization state corruption.
- **Required Resolution**:
  - **Decouple Internal PK from Business Identity**: Keep `item_id` strictly **IMMUTABLE** once allocated.
  - Track edits/revisions via a static `revision_version INTEGER` or `updated_at TIMESTAMPTZ` column instead of altering the primary key.
  - Introduce an immutable UUID column (`item_uuid UUID DEFAULT gen_random_uuid()`) for distributed cross-system identification.

---

### 1.3. Trade-Off 3: Cross-Stack Serialization & Data Type Compatibility Matrix

| Stack Layer | Supported Integer Range | Hazard / Vulnerability | Recommended Architecture Rule |
|---|---|---|---|
| **PostgreSQL Database** | `BIGINT` (64-bit signed: up to $9.22 \times 10^{18}$) | `SERIAL` (32-bit) overflows at 2.147 Billion | Use `BIGSERIAL` / `BIGINT` in all migration scripts |
| **Node.js `pg` Driver** | `string` for `BIGINT` | `node-postgres` converts OID 20 (`bigint`) to `string` in JS to prevent float truncation | Normalize DTO return contracts to handle `id` as `string` |
| **UmiJS / React Dashboard** | JS `Number` (Max Safe: $9.007 \times 10^{15}$) | Numbers above $2^{53} - 1$ suffer floating-point precision loss | Type IDs as `string` in TypeScript interfaces (`id: string`) |
| **Flutter SQLite (Dart)** | `INTEGER` (64-bit in Dart) | SQLite natively supports 64-bit ints, but JSON `int` vs `String` decoding crashes if untyped | Decode API response IDs using defensive parsing: `int.parse(json['id'].toString())` |

---

## 2. Database Migration Blueprint (`0019_upgrade_item_ids_to_bigint.sql`)

To upgrade PostgreSQL tables to 64-bit integers and enforce immutable UUID tracking, execute the following migration:

```sql
-- Migration 0019: Upgrade product_items.id and foreign keys to BIGINT

BEGIN;

-- 1. Upgrade product_items primary key sequence and column to BIGINT
ALTER TABLE product_items 
  ALTER COLUMN id TYPE BIGINT;

-- 2. Upgrade all referencing foreign key columns to BIGINT
ALTER TABLE item_images 
  ALTER COLUMN item_id TYPE BIGINT;

ALTER TABLE ai_training_queue 
  ALTER COLUMN item_id TYPE BIGINT;

-- 3. Add immutability tracking and UUID identity
ALTER TABLE product_items 
  ADD COLUMN IF NOT EXISTS item_uuid UUID DEFAULT gen_random_uuid(),
  ADD COLUMN IF NOT EXISTS revision_version INTEGER NOT NULL DEFAULT 1;

-- 4. Create unique index on item_uuid for fast client synchronization
CREATE UNIQUE INDEX IF NOT EXISTS uq_product_items_uuid ON product_items (item_uuid);

COMMIT;
```

---

## 3. Flutter Mobile SQLite & Cache Synchronization Implementation

In `lib/features/catalog/data/local_item_repository.dart` (Flutter app):

### 3.1. Defensive JSON ID Decoding
```dart
class CatalogItemDto {
  final int id;
  final String itemUuid;
  final int revisionVersion;

  CatalogItemDto({
    required this.id,
    required this.itemUuid,
    required this.revisionVersion,
  });

  factory CatalogItemDto.fromJson(Map<String, dynamic> json) {
    return CatalogItemDto(
      id: int.parse(json['id'].toString()),
      itemUuid: json['itemUuid'] as String? ?? '',
      revisionVersion: json['revisionVersion'] as int? ?? 1,
    );
  }
}
```

### 3.2. SQLite Upsert Logic
Use `CONFLICT` resolution on the immutable `id` or `item_uuid` to ensure edits update local records in place without producing duplicates:

```sql
INSERT INTO local_items (
  id,
  item_uuid,
  group_id,
  title,
  price,
  revision_version,
  updated_at
) VALUES (?, ?, ?, ?, ?, ?, ?)
ON CONFLICT(id) DO UPDATE SET
  title = excluded.title,
  price = excluded.price,
  revision_version = excluded.revision_version,
  updated_at = excluded.updated_at;
```

---

## 4. Verification & Quality Checklist

1. **PostgreSQL Validation**: Run `\d product_items` in psql to confirm `id` column type is `bigint`.
2. **Fastify API Test**: Verify `GET /api/v1/accounts/:accountId/items` serializes large IDs (`1000000000`) without numeric truncation.
3. **Flutter Test**: Run unit tests in `blablaragsandrigs` validating 64-bit integer parsing from mock JSON responses.
4. **Dashboard Test**: Confirm Ant Design Pro dashboard renders item IDs without precision loss.
