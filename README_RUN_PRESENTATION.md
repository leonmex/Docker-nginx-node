# Running this stack for a presentation, off the LAN

This repo's normal setup is NAS-backed: MinIO's data directory and the
server's telemetry logs both live on `/mnt/junglenas` (a CIFS/SMB share
reachable only on the home LAN — see
`CLAUDE-IMPLEMENT-OPTOMETRY-DASHBOARD-FOR-THE-SYSTEM.md` §2.6/§2.6a for why).

Take this machine somewhere else — a different WiFi network, a venue
hotspot, anywhere `/mnt/junglenas` isn't reachable — and `docker compose up`
as-is **breaks**, not just "stops using the NAS":

- `server`'s log volume bind-mounts to whatever's at `TELEMETRY_LOG_NAS_DIR`.
  If that path doesn't exist, Docker silently creates an **empty local
  directory** there instead of failing — and then `logger.ts`'s
  `checkNasMount()` immediately throws because that directory isn't a real
  network filesystem, so `server` crash-loops.
- `minio`'s data volume has the same silent-empty-directory problem — MinIO
  would boot against nothing, and the product catalog would look **deleted**,
  not just unreachable.
- Every already-uploaded product image URL (`item_images.url`, stored as a
  full absolute string like `https://192.168.178.43/media/...`, baked in at
  upload time — see below) points at the home LAN IP, which won't resolve
  anywhere else.

This document covers the two scripts that solve this:
[`server/scripts/ops/presentation-prepare.sh`](server/scripts/ops/presentation-prepare.sh)
and
[`server/scripts/ops/presentation-up.sh`](server/scripts/ops/presentation-up.sh).

## How it works, in one paragraph

A second env file, `.env.presentation` (gitignored, same as `.env`), is a
full copy of `.env` with three storage variables pointed at local Docker
volumes instead of NAS paths, plus a fourth (`MINIO_PUBLIC_URL_BASE`)
rewritten to whatever IP this machine currently has. `postgres-data` was
**always** a local Docker volume — never NAS-backed — so the real database
travels with the machine automatically; only MinIO's bucket contents need
an explicit one-time copy. `docker compose --env-file .env.presentation ...`
then brings the exact same stack up using that file instead of `.env` — the
real `.env` (LAN/NAS mode) is never modified, so switching back is just
running `docker compose` normally again.

## Prerequisites

- Docker with the `node-nginx-clean` stack already set up (`.env` exists,
  `docker compose up` already works normally on the LAN).
- `python3` on the host (used once, to read the compose project name —
  everything else runs inside containers, per this repo's container-first
  convention).
- Run `presentation-prepare.sh` **before** you leave the LAN — it needs
  `/mnt/junglenas` reachable.

## Step 1 — Prepare (run once, on the LAN, before the trip)

```bash
cd /home/noel/projects/docker/Dashboard_Server/node-nginx-clean
./server/scripts/ops/presentation-prepare.sh
```

This will prompt once before briefly stopping `minio` (a few minutes of
downtime while it copies data — safe to do outside business hours). Skip the
prompt with `--yes` for a scripted run.

**What it does:**

1. Checks `/mnt/junglenas/logs/minio-data` (or whatever `MINIO_DATA_NAS_DIR`
   is set to) is actually reachable — refuses to continue if not.
2. Copies `.env` → `.env.presentation`, then overwrites three lines:
   | Variable | LAN/NAS value (`.env`) | Presentation value (`.env.presentation`) |
   |---|---|---|
   | `MINIO_DATA_NAS_DIR` | `/mnt/junglenas/logs/minio-data` | `minio-data` |
   | `TELEMETRY_LOG_NAS_DIR` | `/mnt/junglenas/logs/node-nginx-clean-server` | `server-logs-local` |
   | `ALLOW_LOCAL_LOG_DIR` | `false` | `true` |

   (`minio-data` and `server-logs-local` are plain Docker **named volumes**,
   not paths — Compose treats a bare name with no slashes as a named volume
   automatically, both are already declared in `docker-compose.yml`'s
   top-level `volumes:` section, so no host directory prep is needed on
   whatever machine this runs on.)
3. Stops `minio`, `rsync`s the current NAS bucket contents (both
   `blablarags-apparel` and `telemetry-logs`) into the local `minio-data`
   volume, restarts `minio` — back on the NAS, exactly as before, since the
   real `.env` was never touched.

**Real captured output** (this repo, `--yes` flag, 2026-08-06):

```
== Checking NAS mount (/mnt/junglenas/logs/minio-data) ==
  OK: reachable

== Writing /home/noel/projects/docker/Dashboard_Server/node-nginx-clean/.env.presentation ==
  OK: wrote MINIO_DATA_NAS_DIR=minio-data, TELEMETRY_LOG_NAS_DIR=server-logs-local, ALLOW_LOCAL_LOG_DIR=true
  WARN: MINIO_PUBLIC_URL_BASE still points at whatever it currently is (the LAN IP) — presentation-up.sh fixes this at the venue, not here.

== Stopping minio ==
 Container minio  Stopping
 Container minio  Stopped
  OK: stopped

== Copying /mnt/junglenas/logs/minio-data -> local volume node-nginx-clean_minio-data ==
  OK: copied

== Restarting minio (back on the NAS — .env is unchanged) ==
 Container minio  Created
 Container minio  Starting
 Container minio  Started
  OK: minio restarted on the NAS as normal

== Done ==
  Real product-image data is now seeded into the local 'minio-data' volume.
  Next: at the venue, run ./presentation-up.sh to detect the venue IP,
  fix image URLs, and bring the stack up standalone.
  (Re-run this script any time before a trip to refresh the local copy
  with whatever's newest on the NAS.)
```

Verified afterward: the local `minio-data` volume held 1.7GB (`blablarags-apparel` + `telemetry-logs`, both present), and `minio` came back up cleanly on the NAS with no disruption to the live LAN stack.

**Note on timing:** the `rsync` step copies ~11,000 small files over the
CIFS mount and can take **15–20 minutes** — this is a known slow path for
this NAS (bulk/recursive operations against it are slow; single-object
reads/writes are fast — see `CLAUDE-IMPLEMENT-OPTOMETRY-DASHBOARD-FOR-THE-
SYSTEM.md` §2.6a). Budget time accordingly; don't run this the morning of a
trip.

Re-run this script any time before a future trip to refresh the local copy
with whatever's newest on the NAS — it's fully idempotent (`rsync --delete`
keeps the local copy in sync, doesn't just add new files).

## Step 2 — Go standalone (run at the venue, or anywhere off the LAN)

```bash
cd /home/noel/projects/docker/Dashboard_Server/node-nginx-clean
./server/scripts/ops/presentation-up.sh
```

**What it does:**

1. Detects this machine's current IP (same `hostname -I` / `ip route get`
   fallback logic `scripts/star-from-cero.sh` already uses for normal LAN
   boots).
2. Computes the new base URL — **always `https://`**, never plain HTTP:
   nginx's port 80 server is a redirect-to-443 only
   (`nginx/default.conf:17-23`), there's no unencrypted path. Expect a
   browser certificate warning at the venue (the self-signed cert's CN is
   the fixed string `webapp-node.io`, not tied to any specific IP — this
   warning already happens on the LAN today too, nothing new).
3. **Backfills already-stored URLs.** This is the part that actually needs
   care: `item_images.url` and similar columns
   (`mobile_accounts.avatar_url`, `campaign_banner_assets.cdn_image_url`,
   `invoices.pdf_storage_url`/`xml_storage_url`,
   `credit_notes.pdf_storage_url`) are stored as **full absolute URLs**,
   baked in once at upload time by `MinioObjectStorage.putObject` — there
   are no presigned URLs and nothing recomputes them at read time. Changing
   `MINIO_PUBLIC_URL_BASE` alone does **not** fix already-uploaded images;
   this script runs a `SELECT count(*)` first, shows you exactly how many
   rows in each table will change, then prompts before running the actual
   `UPDATE ... SET url = replace(url, old_base, new_base) WHERE url LIKE
   old_base || '%'`. Safe to re-run — a second run against the same
   old/new pair touches 0 rows.
4. Brings the stack up:
   `docker compose --env-file .env.presentation -f docker-compose.yml -f docker-compose.observability.yml up -d`

**Example run:**

```
== Detecting this machine's current IP ==
  OK: 10.20.30.5

== Rewriting MINIO_PUBLIC_URL_BASE: https://192.168.178.43/media -> https://10.20.30.5/media ==
  OK: written

== Backfilling stored URLs (https://192.168.178.43/media -> https://10.20.30.5/media) ==
  Rows that will be updated:
   item_images | avatars | campaign_banners | invoices | credit_notes
  -------------+---------+------------------+----------+--------------
          6032 |       3 |                1 |        0 |            0

Rewrite these rows' stored URLs from https://192.168.178.43/media to https://10.20.30.5/media?
Proceed? [y/N] y
  OK: backfilled

== Bringing the stack up (presentation mode — local storage only) ==
 Container minio    Recreated
 Container dbPostgres  Running
 Container redis-1  Running
 Container node-nginx-clean-server-1  Recreated
 Container proxy    Recreated
  OK: up

== Done ==
  Dashboard/API: https://10.20.30.5/ (raw images at https://10.20.30.5/media)
  Grafana:       https://10.20.30.5/grafana/
  To go back to LAN/NAS mode: docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d
  (plain 'docker compose up', no --env-file, reads the real .env again)
```

Run `./presentation-up.sh --yes` to skip the confirmation prompt (e.g. for
a scripted/unattended demo kiosk setup) — use with care, it means the URL
backfill runs with no review step.

## Reverting to LAN/NAS mode

Nothing to undo on the `.env`/NAS side — it was never touched. Back on the
LAN:

```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d
```

Plain `docker compose up` with no `--env-file` reads the real `.env` again,
recreating `minio` and `server` back onto the NAS paths. The `minio-data`
and `server-logs-local` local volumes are left in place (harmless, just
unused disk space) — safe to delete with `docker volume rm minio-data
server-logs-local` if you want the space back, or keep them for the next
trip.

**Note:** the LAN-side `item_images.url` rows were rewritten to the venue's
IP by step 2 above, and Postgres is the same database in both modes (it was
never NAS/mode-specific to begin with) — so after returning to the LAN, run
`presentation-up.sh` again while on the LAN (it'll detect the LAN IP and
backfill back) if you want image URLs pointing at the LAN IP again.

## Reference: what's local vs. what's shared between modes

| Data | LAN/NAS mode | Presentation mode | Shared between modes? |
|---|---|---|---|
| Postgres (`postgres-data`) | local Docker volume | local Docker volume | **Yes — same volume always** |
| Redis (`redis-data`) | local Docker volume | local Docker volume | **Yes — same volume always** |
| MinIO buckets (`minio-data` vs NAS) | `/mnt/junglenas/logs/minio-data` | local `minio-data` volume | No — separate copies, sync via `presentation-prepare.sh` |
| Server telemetry logs | `/mnt/junglenas/logs/node-nginx-clean-server` | local `server-logs-local` volume | No — presentation-mode logs aren't collected by the LAN's Promtail/Loki |
| `item_images.url` etc. (stored URL strings) | whatever `MINIO_PUBLIC_URL_BASE` was at last `presentation-up.sh` run | same | **Yes — same rows, rewritten in place by whichever mode ran last** |

## Files this feature touches

| File | Role |
|---|---|
| `docker-compose.yml` | Declares the `server-logs-local` named volume (harmless/unused in normal LAN mode) |
| `.env.presentation` | Generated by `presentation-prepare.sh`, gitignored — not committed |
| `server/scripts/ops/presentation-prepare.sh` | Run once per trip, on the LAN |
| `server/scripts/ops/presentation-up.sh` | Run at the venue (or any time you want to go standalone) |
| `server/scripts/ops/_lib.sh` | Shared helpers (`step`/`ok`/`warn`/`err`/`confirm`/`psql_exec`) both scripts use — see that file's own header comment for the trust model |

## Known limitations

- **Not a full offline snapshot tool.** Only MinIO buckets are copied
  on-demand by `presentation-prepare.sh`; Postgres/Redis are always-local
  already, so there's nothing to snapshot there — but this also means data
  written *during* a presentation (new signups, new orders) stays on
  whatever machine ran the demo and does **not** sync back to the LAN
  automatically. If that matters, treat presentation-mode data as
  disposable, or plan a manual `pg_dump`/restore separately.
- **The URL backfill is global**, not scoped to "images used in this demo"
  — it rewrites every row currently matching the old base URL. Fine for
  this repo's dataset size (a few thousand rows), but worth knowing if the
  catalog grows much larger.
- **Relative image URLs would remove this whole problem** — storing
  `/media/...` instead of a full absolute URL, resolved client-side against
  whatever host is already in use, needs no backfill ever. That's a bigger
  change (touches `MinioObjectStorage`, every caller, and the Flutter app's
  image-loading code) and is intentionally out of scope here — see
  `CLAUDE-IMPLEMENT-OPTOMETRY-DASHBOARD-FOR-THE-SYSTEM.md`'s presentation-
  mode plan entry for the fuller discussion.
- **`docker compose --env-file` doesn't override a service's `env_file:`
  directive** — found the hard way on 2026-08-07: the NAS went unmounted
  while the stack was up (unrelated to presentation mode), MinIO's bind
  mount silently resolved to an empty local directory (the usual
  bind-mount-auto-creates-empty-dir trap), and bringing the stack back up
  with `--env-file .env.presentation` fixed MinIO and the `minio-data`
  volume-based bind mount correctly — but the `server` container still
  crashed on `ALLOW_LOCAL_LOG_DIR=false`, because `docker-compose.yml`'s
  `server` service had a **hardcoded** `env_file: - ./.env`. `--env-file`
  only controls `${VAR}` interpolation in the compose YAML itself; it does
  not touch an explicit `env_file:` directive, which always loads its
  literal path into the container regardless. Fixed by parameterizing it
  (`env_file: - ${SERVER_ENV_FILE:-./.env}`) and having
  `presentation-prepare.sh` write `SERVER_ENV_FILE=.env.presentation`
  (self-pointing) into the generated file. If you're adding a new service
  with its own `env_file:` in the future, use the same pattern or it will
  silently ignore presentation mode too.
- **Recreating one container behind nginx needs an nginx reload.** After
  recreating just `server` (e.g. to pick up the `SERVER_ENV_FILE` fix
  above), `/api/*` returned 502 through `proxy` even though `server` was
  confirmed healthy — nginx caches upstream hostname resolution and had the
  old container's IP. `docker exec proxy nginx -s reload` fixed it
  immediately. Worth remembering any time a single backend container gets
  recreated without touching `proxy` itself.
