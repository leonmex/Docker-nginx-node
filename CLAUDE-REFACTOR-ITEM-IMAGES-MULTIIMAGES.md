# Technical Plan: Multi-Image Support per Item (`item_images`)

This document details the analysis and technical plan to support multiple images per item across the database repository, backend API routes, and frontend dashboard in `node-nginx-clean`.

## Current State Analysis

### 1. Database Schema (`server/db/schema.sql`)
The database schema for `item_images` already supports a 1-to-many relationship with `product_items`:
```sql
CREATE TABLE IF NOT EXISTS item_images (
  id         SERIAL PRIMARY KEY,
  item_id    INTEGER     NOT NULL REFERENCES product_items(id) ON DELETE CASCADE,
  url        TEXT        NOT NULL,
  sort_order INTEGER     NOT NULL DEFAULT 0,
  created_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
```
- **Finding**: The database table natively allows N images per item ordered by `sort_order`.

### 2. Backend API & Repository Constraints (`server/src`)
- **Single Item Creation Endpoint (`POST /api/v1/apparel`)**: Only accepts 1 multipart file (`fieldname === 'image'`). `createSingleItem()` hardcodes a single `INSERT INTO item_images (item_id, url, sort_order)`.
- **Item Detail Endpoint (`GET /api/v1/apparel/items/:itemId/detail`)**: `getItemWithGroupContext` queries `product_items.*` but does not fetch `item_images` rows for the main item.
- **Flat Items List Endpoint (`GET /api/v1/accounts/:accountId/items`)**: Uses a subquery with `LIMIT 1` to return only a single `thumbnail_url`. It does not return the array of all images per item.
- **Admin Item Endpoints (`/admin/apparel/items/:itemId`)**: `getItemForAdmin` queries `item_images` (returning `images: AdminItemImage[]`), but `updateItemAdmin` (`PATCH`) lacks endpoints or logic to add, remove, or reorder images in `item_images`.

### 3. Frontend Dashboard Constraints (`dashboard/src`)
- **Types (`services/apparel.ts`)**: `FlatItem` only defines `thumbnailUrl: string | null`.
- **UI Components (`ItemsTableView`, `ItemsListView`, `ProductRow`)**: Only display `thumbnailUrl` as a single avatar/thumbnail.
- **Admin Item Editor**: Lacks UI controls for uploading secondary images, reordering images, or deleting existing images from an item.

---

## Architectural Changes & Implementation Plan

### Phase 1: Backend Database Repository & Domain Types (`server/`)

1. **Repository Types (`server/src/repositories/types.ts`)**:
   - Extend item records to include `images: Array<{ id: number; url: string; sortOrder: number }>`.

2. **PgApparelRepository (`server/src/repositories/PgApparelRepository.ts`)**:
   - Update `getItemWithGroupContext`: Query `item_images` table for the target item and include `images: { id, url, sortOrder }[]`.
   - Update `listItemsFlat`: Perform a batched fetch of `item_images` for all item IDs on the requested page and attach `images` to each `FlatItem`.
   - Add image manipulation methods:
     - `addItemImage(itemId: number, url: string, sortOrder?: number)`
     - `deleteItemImage(itemId: number, imageId: number)`
     - `reorderItemImages(itemId: number, imageOrders: { id: number; sortOrder: number }[])`

3. **Apparel Routes (`server/src/routes/apparel.ts`)**:
   - Update `POST /api/v1/apparel`: Support multiple uploaded image files under field `images` or multiple parts and save each to `item_images`.
   - Add Admin Image Management Endpoints:
     - `POST /admin/apparel/items/:itemId/images` (upload & attach new image).
     - `DELETE /admin/apparel/items/:itemId/images/:imageId` (delete specific image).
     - `PUT /admin/apparel/items/:itemId/images/reorder` (update `sort_order`).

---

### Phase 2: Frontend Dashboard Integration (`dashboard/`)

1. **Apparel Service (`dashboard/src/services/apparel.ts`)**:
   - Update `FlatItem` type definition with `images: AdminItemImage[]`.
   - Add API request helpers for image uploads, deletions, and reordering.

2. **Item List & Table Views (`ItemsTableView`, `ItemsListView`)**:
   - Render image count indicators (e.g., `+2 photos` badge) or thumbnail preview tooltips for items with multiple images.

3. **Admin Item Management View**:
   - Add an interactive multi-image management component to view, upload, delete, and reorder item images.

---

## Verification Plan

1. **Automated Integration Tests (`server/test/`)**:
   - Verify `PgApparelRepository` multi-image CRUD operations.
   - Test `POST /api/v1/apparel` with multiple image parts.
   - Test `GET /api/v1/accounts/:accountId/items` and `GET /api/v1/apparel/items/:itemId/detail` responses for `images` array structure.
   - Test admin image management endpoints (upload, delete, reorder).

2. **Manual & UI Verification**:
   - Perform multipart upload testing with `curl`.
   - Verify dashboard table and detail drawers render multi-image items correctly.
