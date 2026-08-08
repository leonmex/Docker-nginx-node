# Running this stack normally — home LAN + NAS

This is the **default** way to run this repo: on the home LAN, with MinIO's
data directory and the server's telemetry logs both living on
`/mnt/junglenas` (a CIFS/SMB share reachable only on that LAN — see
`CLAUDE-IMPLEMENT-OPTOMETRY-DASHBOARD-FOR-THE-SYSTEM.md` §2.6/§2.6a for the
full rationale). If you instead need to run this off the LAN — a
presentation, a demo venue, anywhere `/mnt/junglenas` isn't reachable — see
[`README_RUN_PRESENTATION.md`](README_RUN_PRESENTATION.md) instead; nothing
below applies there.

## How it works, in one paragraph

`docker-compose.yml` bind-mounts `minio`'s `/data` from
`${MINIO_DATA_NAS_DIR:-/mnt/junglenas/logs/minio-data}` and `server`'s
`/usr/src/server/logs` from
`${TELEMETRY_LOG_NAS_DIR:-/mnt/junglenas/logs/node-nginx-clean-server}` — both
default to real paths under the NAS mount. `server` additionally
self-checks at boot (`checkNasMount()`, `server/src/core/nasMount.ts`,
called from `logger.ts`) via `fs.statfsSync()` on its log directory,
comparing the filesystem type against CIFS/NFS magic numbers — if the NAS
isn't actually mounted, it refuses to start rather than silently writing
logs to a throwaway local directory. MinIO has no equivalent self-check, so
if the NAS mount drops out **while MinIO is already running**, its symptom
looks different (see Troubleshooting below) — worth knowing before you go
looking for the wrong kind of bug.

## Prerequisites

- `/mnt/junglenas` mounted on the host **before** you start the stack. This
  repo doesn't configure or manage that mount — there's no fstab entry,
  systemd unit, or script for it here; it's autofs-triggered on this host
  (accessing the path triggers the mount). If it's not already mounted:
  ```bash
  ls /mnt/junglenas        # triggers autofs
  mountpoint -q /mnt/junglenas && echo mounted || echo "still not mounted"
  ```
  If it stays unmounted after that, the mount itself needs attention at the
  host/network level (NAS reachable on the LAN? autofs configured?) — outside
  what Docker or this repo can fix.
- Docker with Compose v2 (`docker compose`, not the old `docker-compose`).
- `.env` already generated (see Step 1 if this is a fresh checkout).

## Step 1 — First-time setup (skip if `.env` already exists)

```bash
cd /home/noel/projects/docker/Dashboard_Server/node-nginx-clean
./scripts/star-from-cero.sh
```

This bootstrap script is **not NAS-aware** — it doesn't check or wait for
the mount. What it actually does:
1. Generates `.env` if missing, with random `POSTGRES_PASSWORD`/
   `MINIO_ROOT_PASSWORD` and default host ports. A freshly generated `.env`
   has no NAS vars in it at all — `docker-compose.yml`'s
   `${MINIO_DATA_NAS_DIR:-/mnt/junglenas/logs/minio-data}`-style defaults
   apply automatically, so you don't need to add them yourself.
2. Generates a self-signed TLS cert (`nginx/certs/server.{crt,key}`) if
   missing — CN is `webapp-node.io`, matching `nginx/default.conf`'s
   `server_name`; expect a browser cert-name-mismatch warning when visiting
   by IP, that's normal and not a bug.
3. Checks every `HOST_*_PORT` against what's actually busy on this host,
   rerouting to a free port only if something *else* (not this project)
   already holds it.
4. Detects this machine's current LAN IP and rewrites
   `MINIO_PUBLIC_URL_BASE` to `https://<LAN_IP>[:port]/media` if it's stale
   — this is what keeps the whole stack IP-agnostic across different
   networks/machines, without needing a real domain.
5. Runs `docker compose up --build -d` and prints the reachable URLs
   (`localhost` and the detected LAN IP) plus a `ufw` firewall reminder.

## Step 2 — Everyday start/stop

Once `.env` exists and the NAS is mounted, bring the stack up with:

```bash
# Core stack only:
docker compose up -d

# Core stack + observability (Grafana/Loki/Prometheus/exporters — opt-in,
# see docker-compose.observability.yml's own header comment):
docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d
```

No `--env-file` flag needed here — that's specifically a presentation-mode
thing. Plain `docker compose` already reads `.env` by default, which is
exactly what NAS/LAN mode wants.

Visit `https://<LAN_IP>/` (the IP `star-from-cero.sh` printed, matching
`MINIO_PUBLIC_URL_BASE` in `.env`) — e.g. `https://192.168.178.43/`.

To stop: `docker compose down` (or `-f ... -f ... down` if observability is
up too) — this does **not** touch anything on the NAS or the local
`postgres-data`/`redis-data` volumes.

## Verifying it's actually reading from the NAS

Worth a quick check after any fresh start, since the failure mode when the
NAS *isn't* actually mounted is silent (Docker auto-creates an empty local
directory at the bind-mount source instead of erroring — see
`README_RUN_PRESENTATION.md`'s intro for the fuller explanation of that
specific Docker behavior):

```bash
mountpoint -q /mnt/junglenas && echo "NAS: mounted" || echo "NAS: NOT mounted"
docker compose logs server --tail 20 | grep -i "network filesystem" || echo "server: no NAS complaint"
docker exec minio du -sh /data 2>&1 || true   # should be gigabytes, not near-zero
```

## Troubleshooting

Real incidents hit while running this stack, kept here rather than
rediscovered blind next time:

- **MinIO logs `Error: Read quorum could not be established`,
  `listPathRaw: 0 drives provided`, or `corrupted backend`.** This is the
  signature of the NAS having gone unmounted (or never having been mounted)
  *before* MinIO's bind mount resolved — Docker silently substituted an
  empty local directory, and MinIO sees that as a corrupted/missing drive,
  not "0 objects." It is **not** real data corruption; the actual bucket
  contents on the NAS are untouched. Fix: confirm `mountpoint -q
  /mnt/junglenas` succeeds, then `docker compose up -d minio` to recreate
  it against the now-real mount (a plain restart isn't enough if the bind
  mount itself was already resolved wrong — recreate the container).
- **`server` crash-loops with `Error: LOG_OUTPUT includes 'file' but logDir
  ... is not backed by a network filesystem (detected fs type: ...)`.**
  Same root cause as above, different (louder, by design) symptom —
  `checkNasMount()` caught it at boot. Same fix: remount the NAS, then
  `docker compose up -d server`.
- **After recreating just one backend container (`server`, `minio`, etc.),
  `proxy` starts returning 502s for routes that go to it**, even though the
  container is confirmed healthy on its own. nginx caches upstream hostname
  resolution and doesn't notice the container got a new internal IP.
  Fix: `docker exec proxy nginx -s reload`.
- **`postgres-exporter` (observability stack only) spams `column
  "checkpoints_timed" does not exist`.** Not a NAS issue, not even a real
  Postgres problem — `postgres_exporter` versions before `v0.17.0` bundle a
  default query against `pg_stat_bgwriter` columns that PostgreSQL 17+
  moved into a separate `pg_stat_checkpointer` view. Already fixed in this
  repo (`docker-compose.observability.yml` pins `v0.20.1`) — mentioned here
  only in case it resurfaces after a manual image change.
- **NAS drops out *while the stack is already running fine.*** MinIO has no
  live self-check (unlike `server`'s boot-time one), so it can keep running
  against a now-stale mount for a while before erroring on an actual
  read/write. If uploads/image loads start failing with no obvious cause,
  check `mountpoint -q /mnt/junglenas` first, before assuming it's an
  application bug.

## Reference: relevant files

| File | Role |
|---|---|
| `docker-compose.yml` | `minio`/`server` NAS bind-mount definitions (`MINIO_DATA_NAS_DIR`/`TELEMETRY_LOG_NAS_DIR`) |
| `server/src/core/nasMount.ts` | `checkNasMount()` — the `statfsSync`-based CIFS/NFS filesystem-type check |
| `server/src/core/logger.ts` | Calls `checkNasMount()` at boot; `ALLOW_LOCAL_LOG_DIR=true` bypasses it (don't set this in normal LAN/NAS mode — that flag exists for presentation/local-dev mode, setting it here just hides a real problem) |
| `scripts/star-from-cero.sh` | First-time bootstrap — `.env` generation, TLS cert, port preflight, LAN IP detection |
| `scripts/generate-certs.sh` | Self-signed TLS cert generation, called by `star-from-cero.sh` |
| `nginx/default.conf` | `server_name webapp-node.io` — why the cert warning by IP is expected |
| `.env` | `MINIO_DATA_NAS_DIR`, `TELEMETRY_LOG_NAS_DIR`, `ALLOW_LOCAL_LOG_DIR=false`, `MINIO_PUBLIC_URL_BASE` |

## Known limitations

- The NAS mount itself is entirely outside this repo's control — no
  fstab/systemd/autofs config lives here, by design (host-specific,
  environment-specific). If the mount mechanism itself changes on the host,
  this doc's "trigger + verify" snippet may need to change with it.
- MinIO has no equivalent of `server`'s `checkNasMount()` — a NAS drop-out
  mid-session is only caught reactively (failed reads/writes), not
  proactively at any point after MinIO's own startup.
- CIFS/NFS as MinIO's backing store is an accepted, documented risk (not
  officially supported by MinIO) — see
  `CLAUDE-IMPLEMENT-OPTOMETRY-DASHBOARD-FOR-THE-SYSTEM.md` §2.6a for the
  full trade-off discussion, including the known slow-bulk-operations
  caveat (`mc du`/recursive scans take minutes over CIFS; individual
  object reads/writes stay fast).
