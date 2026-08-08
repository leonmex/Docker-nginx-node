# Observability Implementation Plan — Grafana-based Monitoring & Alerting

**Status:** Plan only — nothing in this document has been implemented yet.
**Date:** 2026-08-05
**Scope:** `node-nginx-clean` (Fastify `server` + Postgres + Redis + MinIO + MailHog + nginx `proxy` + Ant Design Pro `dashboard`/`webapp`), Docker Compose stack.

## 1. Goal

Turn the telemetry that already exists in this codebase (structured pino logs, a homegrown `TelemetryCollector`, several audit-log tables) into a real, always-on Grafana observability stack that can answer, without anyone manually running a script:

1. **Is every service up and talking to the others right now?** (Postgres, Redis, MinIO, MailHog, the API itself, the reverse proxy)
2. **Is the buyer → seller purchase flow actually moving?** (registration → listing → buy-now/offer-accept → escrow → shipment → delivery → payout), not just "did the HTTP request succeed."
3. **Are shipments and buyer/seller messages flowing correctly**, with alerting on stuck/at-risk states, not just current counts.
4. **Where do requests fail, and how fast are they**, per route, with the ability to jump from a metric spike straight to the matching log lines.

This is explicitly a **plan document** — see §9 for the proposed phased rollout before any of it gets built.

---

## 2. Current state (verified against the live code, not assumed)

### 2.1 What "telemetry" means in this codebase today

`server/src/core/TelemetryCollector.ts` (`ITelemetryCollector` in `ITelemetry.ts`) is **not distributed tracing** — no trace/span IDs, no propagation, no OpenTelemetry. It's a per-call in-memory span accumulator: `startSpan()`/`endSpan()`/`recordError()` push timing entries into an array, and `flush()` emits exactly **one** `"transaction completed"` JSON log line (via the plain pino `logger`, not `req.log`) containing `totalMs`, `status`, `spanCount`, and a `spans[]` array. Nothing consumes the `flush()` return value anywhere — it only ever reaches the log sink.

**Only 4 of ~30 route files use it**, each with its own copy-pasted local `withTelemetry()` helper (not a shared utility):

| File | Spans | Notably NOT wrapped |
|---|---|---|
| `shipments.ts` | create/update/updateTracking/remove/addTrackingEvent/addMessage/csIntervene (+2 nested) | list/detail/search (deliberate — matches `shipment_audit_logs`' mutation-only scope) |
| `acquisitions.ts` | buyNow (+2 nested) | `checkout-quote`, and **`PATCH /:id/hide` — a real mutation** |
| `offers.ts` | create/counter/reject/withdraw/accept (+2 nested) | — |
| `conversations.ts` | startThread/reply/notifyRecipient | — |

**Not instrumented at all**: `wallets.ts` (includes `releaseAcquisitionManually`/`blockAcquisitionPayment` — admin actions that move real escrow money, currently only leave a `wallet_audit_logs` row, no telemetry), `apparel.ts`, `wallet.ts`, `paymentFraudReviews.ts`, `auth.ts`, `invoices.ts`, every admin/catalog route.

**A real bug that will hurt log-correlation dashboards if not fixed first**: every `withTelemetry()` builds its `TelemetryCollector` from the **root** `logger`, never `req.log`, so the `"transaction completed"` line **carries no `reqId`** — it can't be joined to the rest of that request's logs except by eyeballing timestamps. See §9 Phase 0.

### 2.2 Logging

- **pino 9.5.0**, JSON, with `pino-pretty` for local dev only. Every record gets `service`/`pid`/`hostname` base fields.
- `LOG_OUTPUT=both` in `.env` today → logs already go to **both** stdout (`docker logs`) **and** a file, `server/logs/server.log` on the host (bind-mounted from `/usr/src/server/logs/` in the container) — **this is already a ready-made Promtail scrape target, zero app changes required for Phase 1.**
- `reqId` comes from Fastify's own default generator (an in-process incrementing counter, not a UUID — not globally unique across container restarts or multiple `server` replicas). Fine for single-instance dev/staging; would need `genReqId` overridden to a UUID before this ever runs > 1 replica.
- Repository-level logging is inconsistent: only the `Cached*Repository` wrappers log (cache hit/miss), and they log off the root logger too (no reqId). Plain `Pg*Repository` classes don't log — errors only surface at the route's own catch block (which does have `reqId`).

### 2.3 Infra: what's already in `docker-compose.yml`

Single bridge network: **`node_network`**. Services: `webapp`, `proxy` (nginx), `dbPostgres` (Postgres 18.4, loopback-only host port), `redis` (7-alpine, loopback-only), `minio` (S3 API internal-only, console loopback), `server` (Fastify, **no host port exposed at all today** — `expose: 5000` internal-only), `mailhog`. A commented-out `elasticsearch` block exists (abandoned attempt, not live). **Confirmed: no Prometheus/Grafana/Loki/exporter of any kind exists today.**

No metrics library is installed (`prom-client`, `@opentelemetry/*`, `winston` — all absent from `server/package.json`).

### 2.4 Data that already models the flows we want to observe

- **`acquisitions`** (`AcquisitionStatus = escrow_held | buyer_confirmed | released | disputed | refunded | cancelled`, grouped `in_progress|completed|cancelled`) — has `createdAt`/`buyerConfirmedAt`/`escrowReleaseAt`/`releasedAt`, enough to graph time-in-escrow.
  - ⚠️ **Real product gap found while researching this plan, directly relevant to "is the purchase flow moving": there is no code path anywhere that ever transitions an acquisition from `escrow_held` to `buyer_confirmed`.** `sweepMaturedEscrows()` only matures rows *already* `buyer_confirmed` past `escrow_release_at` — nothing feeds it. There's also **no cron/scheduler in the whole app** (confirmed empty grep for `cron|setInterval|schedule` in `src/index.ts`); the sweep only runs lazily, inline, scoped to one account, when that account's buyer or seller happens to load their own orders list. Today the *only* way an `escrow_held` acquisition ever resolves is an admin manually calling `releaseAcquisitionManually`/`blockAcquisitionPayment` (`wallets.ts`). **This means `escrow_held` acquisitions can pile up forever with no automatic resolution — exactly the kind of stuck-state this observability project should alert on (§7.2), and arguably a bug worth its own follow-up ticket, not just a dashboard.**
- **`shipments`** (`awaiting_tracking|in_transit|delivered|lost|disputed|cancelled`) — `riskLevel` (`normal|warning|critical`) is computed **live in SQL** from `tracking_deadline`, never stored. `PgShipmentRepository.getStats()` already aggregates `totalActive/highRisk/warning/normal` — this exact query is the natural source for a shipment-risk panel.
- **`shipment_audit_logs`** — real event stream (`created|status_change|tracking_added|tracking_modified|cs_intervention|deleted`), but `ON DELETE CASCADE` on `shipment_id` means a deleted shipment's whole audit trail disappears with it (already a documented known-gap elsewhere in this repo).
- **`wallet_audit_logs`** — captures every admin escrow release/block/pause action (`ON DELETE SET NULL`, survives acquisition deletion) — good source for a "manual escrow interventions" panel, and the closest thing to an alert-worthy admin-action stream today.
- **`payment_fraud_reviews`** — `status` funnel (`pending_review|cleared|confirmed_fraud|blocked`), `risk_score` — fraud-review backlog panel.
- **`conversations`/`conversation_messages`** — no status enum; message volume/rate and time-to-first-reply are derivable straight from `created_at` timestamps, no new instrumentation needed.

### 2.5 Existing manual/homegrown monitoring (don't blindly duplicate)

- `server/scripts/ops/stack-health.sh` — live Postgres/Redis/MinIO/MailHog/API reachability check, exits non-zero on failure (already CI/cron-shaped).
- `server/scripts/ops/db-health-check.sh` — row counts + **4 business-invariant SQL assertions** the schema can't enforce alone (every escrow_held/buyer_confirmed acquisition has a shipment; no duplicate pending offer threads; wallet balances never negative; `wallets.balance` always matches the last ledger entry). **These four assertions are exactly what should become Prometheus alert rules (§7.3) instead of a script a human has to remember to run.**
- `server/src/routes/dashboardMonitor.ts` — dashboard-native panels already exist for products-by-country and Redis cache stats (`cache-stats`, built this session).
- `server/src/routes/apiHealth.ts` + `ApiHealthChecker.ts` — a real synthetic-monitoring feature: runs ~23 grouped checks against live endpoints using a persistent test account, plus an actual **end-to-end purchase test** (`run-purchase-test`) on demand. This is hand-built synthetic-transaction monitoring already — Phase 4 proposes exposing its pass/fail as a scheduled Prometheus metric instead of a manual dashboard click (§9 Phase 4).

---

## 2.6 Confirmed architecture decisions (2026-08-05)

Discussed and settled before implementation started:

1. ~~MinIO's own storage stays on local disk, not the NAS.~~ **Superseded 2026-08-06** — see §2.6a below. MinIO's data directory (both buckets) now runs directly against the NAS, a deliberate risk-accepted change so this gets validated for real before the Kubernetes move rather than discovered for the first time in production.
2. **Log source is NAS-mounted, not Docker stdout, not the old local bind mount.** `server` writes its JSON logs to a *configurable* path that now defaults to `/mnt/junglenas/logs/node-nginx-clean-server/` (env var, same override convention as `LOG_DIR` today), and Promtail mounts that same NAS path read-only and tails it directly. Note: `/mnt/junglenas/logs/` already has unrelated content (`logs.log`, `temp.log`, `COMMANDS_TO_EXECUTE.md` — a different, pre-existing use) — this project gets its own `node-nginx-clean-server/` subfolder there, not the shared root.
3. ~~MinIO itself does not read the NAS directly.~~ **Superseded 2026-08-06** — see §2.6a. The NAS is now touched at three points: (a) as the log **source** Promtail tails from, (b) as MinIO's own **live data directory** (both buckets), and (c) as the **backup destination** for the MinIO bucket's contents (a true second copy now, since (b) and (c) are different NAS paths).

### 2.6a MinIO data directory moved to the NAS (2026-08-06, supersedes decision #1/#3 above)

Decision #1 above ("MinIO stays on local disk") was reversed at the user's explicit request: *"we need to be sure that all work as we expect in real"* — i.e. validate MinIO-on-NAS now, in this dev/sandbox environment, rather than assume it and find out it doesn't work only after the Kubernetes/production move.

- **What changed**: `minio` service's volume mount is now `${MINIO_DATA_NAS_DIR:-/mnt/junglenas/logs/minio-data}:/data` (was the local `minio-data` named volume — still declared in `docker-compose.yml` for rollback, just unused).
- **Scope**: the WHOLE MinIO service — both `blablarags-apparel` (real product images) and `telemetry-logs` (Loki's chunk storage) — per explicit confirmation, not just the telemetry bucket.
- **Known, accepted risk**: MinIO's own docs state it requires a local POSIX filesystem (atomic rename, real `flock`) and does not officially support CIFS/NFS network filesystems as backing storage. Silent corruption under concurrent access is the failure mode if this doesn't hold up. This was flagged explicitly before implementing; the user chose to proceed anyway to validate it for real.
- **Migration performed**: `minio` stopped, existing local-volume contents (11,329 files, 1.2GB — both buckets + MinIO's internal `.minio.sys`) copied via `rsync` (through a throwaway Alpine container, per this repo's container-first convention) to `/mnt/junglenas/logs/minio-data/`, then the compose mount switched and `minio` recreated.
- **Verified post-migration**: MinIO boots cleanly against the NAS path (no lock/rename errors in logs). Object counts/sizes read via Prometheus (`minio_bucket_usage_object_total`/`_bytes` — MinIO's own periodic usage-crawler results, not a live scan) match exactly what was live before the migration: `blablarags-apparel` 6,032 objects / 1,235,984,720 bytes, `telemetry-logs` 17 objects / 12,259 bytes. Single-object GET/PUT/DELETE (the actual product-image serving pattern) measured fast: ~80–200ms.
- **Real performance caveat found**: `mc du` (MinIO client's recursive bucket-usage scan, which stats every object client-side) **timed out (>2 min)** against `blablarags-apparel`'s 6,032 objects over the CIFS mount — a genuine slow path, not a fluke. This does not appear to affect normal serving (single-object reads/writes are fast, and MinIO's own server-side usage crawler — what the Grafana dashboard actually queries via Prometheus — completes fine on its own schedule), but **any tooling that does a live recursive `mc du`/`mc find`/bulk `rsync` against this bucket should be expected to be slow**, and that should factor into any future backup-job design or admin tooling that touches this bucket in bulk.
- **Not yet done**: `MINIO_PUBLIC_URL_BASE` in `.env` is still a hardcoded LAN IP (`https://192.168.178.43/media`), unrelated to this change but flagged by the user in the same conversation as something that needs to work "in any intranet... no matter what is the ip" — not changed here since it wasn't part of the specific ask, but noted for a future pass.
4. **Metrics stay local-Prometheus-only** for this pass — no Mimir/Thanos yet; revisit when the actual Kubernetes move happens, where object-storage-backed metrics is the standard pattern anyway.
5. **NAS backup job degrades gracefully**: checks the mount first (`mountpoint -q`, same pattern `sync_images_to_nas.py`/the smoke-test script already use in this repo) and skips the cycle with a warning if the NAS is unavailable — never blocks or crashes the live stack.

## 3. Proposed architecture

```
┌─────────────┐   scrape /metrics   ┌────────────┐        ┌─────────┐
│   server     │◄────────────────────│ Prometheus │───────►│ Grafana │◄── you, via browser
│ (+prom-client)│                    └─────┬──────┘        └────┬────┘
└──────┬───────┘                           │                    │
       │ writes JSON logs to               │ scrapes            │ queries
       │ server/logs/server.log            ▼                    │
       │                          ┌──────────────────┐          │
       │                          │ postgres_exporter │          │
       │                          │  redis_exporter   │          │
       │                          │  (+ custom biz-   │          │
       │                          │   invariants      │          │
       │                          │   exporter)       │          │
       │                          └──────────────────┘           │
       ▼                                                         │
┌─────────────┐   pushes log lines   ┌──────┐                    │
│  Promtail    │─────────────────────►│ Loki │◄───────────────────┘ (LogQL)
└─────────────┘                       └──────┘
```

- **Prometheus** — pulls metrics on a scrape interval (proposed 15s) from the app and exporters. Also owns alert-rule evaluation (or delegate to Grafana Alerting — see §7.1 decision).
- **Grafana** — dashboards + (proposed) built-in Alerting, so we don't need a separate Alertmanager container for a stack this size.
- **Loki + Promtail** — ingests the pino JSON log file that already exists, indexed by labels (`service`, `level`, `module`), queryable/graphable via LogQL, and linkable from a metric panel straight to the matching logs (Grafana's log-metrics correlation).
- **postgres_exporter / redis_exporter** — off-the-shelf, point at the existing `dbPostgres`/`redis` services on `node_network` using credentials already in `.env`. No app changes.
- **A small custom "business metrics" exporter** (new, ~100 lines) — the one piece with no off-the-shelf equivalent: runs the four `db-health-check.sh` invariant queries plus the acquisitions/shipments/escrow-age queries on an interval and serves them as Prometheus gauges. This is what makes "is the purchase flow actually moving correctly" a graphable, alertable time series instead of a script someone has to remember to run.

All new containers join the existing `node_network` — no new network needed. Grafana's UI is the only thing a human needs to reach; everything else stays internal, following the same "loopback/internal only unless there's a specific reason" posture the rest of this stack already uses (see §8).

---

## 4. New Docker Compose services (concrete)

Add to `docker-compose.yml` (new file `docker-compose.observability.yml` is the recommended approach — see §9 Phase 1 rationale — merged via `docker compose -f docker-compose.yml -f docker-compose.observability.yml up`, so the observability stack is opt-in and doesn't slow down a plain dev boot):

```yaml
services:
  prometheus:
    image: prom/prometheus:v3.0.1
    container_name: prometheus
    volumes:
      - ./observability/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./observability/prometheus/rules:/etc/prometheus/rules:ro
      - prometheus-data:/prometheus
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=15d
    ports:
      - "127.0.0.1:9090:9090"   # loopback only, same posture as dbPostgres/redis today
    networks: [node_network]

  loki:
    image: grafana/loki:3.3.0
    container_name: loki
    volumes:
      - ./observability/loki/loki-config.yml:/etc/loki/local-config.yaml:ro
      - loki-data:/loki
    ports:
      - "127.0.0.1:3100:3100"
    networks: [node_network]

  promtail:
    image: grafana/promtail:3.3.0
    container_name: promtail
    volumes:
      - ./observability/promtail/promtail-config.yml:/etc/promtail/config.yml:ro
      - ${TELEMETRY_LOG_NAS_DIR:-/mnt/junglenas/logs/node-nginx-clean-server}:/var/log/telemetry:ro
    command: -config.file=/etc/promtail/config.yml
    depends_on: [loki]
    networks: [node_network]
    # Reads directly from the NAS path `server` now writes to (see §2.6/§5.3) —
    # NOT Docker stdout, NOT a local bind mount. If the NAS is unmounted when
    # this container starts, the volume mount itself will fail loudly
    # (compose error, not a silent empty directory) — intentional, since a
    # silently-empty log source is worse than a container that won't start.

  postgres-exporter:
    image: prometheuscommunity/postgres-exporter:v0.15.0
    container_name: postgres-exporter
    environment:
      - DATA_SOURCE_NAME=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@dbPostgres:5432/${POSTGRES_DB}?sslmode=disable
    networks: [node_network]

  redis-exporter:
    image: oliver006/redis_exporter:v1.62.0
    container_name: redis-exporter
    environment:
      - REDIS_ADDR=redis:6379
    networks: [node_network]

  business-metrics-exporter:
    build: ./observability/business-metrics-exporter
    container_name: business-metrics-exporter
    environment:
      - DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@dbPostgres:5432/${POSTGRES_DB}
    networks: [node_network]
    # see §5.4 — new, small, purpose-built for this repo's own invariants

  grafana:
    image: grafana/grafana:11.4.0
    container_name: grafana
    environment:
      - GF_SECURITY_ADMIN_PASSWORD__FILE=/run/secrets/grafana_admin_password
      - GF_USERS_ALLOW_SIGN_UP=false
    secrets: [grafana_admin_password]
    volumes:
      - ./observability/grafana/provisioning:/etc/grafana/provisioning:ro
      - ./observability/grafana/dashboards:/var/lib/grafana/dashboards:ro
      - grafana-data:/var/lib/grafana
    ports:
      - "127.0.0.1:3300:3000"   # NOT 3000 — already used by webapp; loopback only, see §8
    depends_on: [prometheus, loki]
    networks: [node_network]

secrets:
  grafana_admin_password:
    file: ./observability/grafana_admin_password.txt   # gitignored, generated once by the setup script

volumes:
  prometheus-data:
  loki-data:
  grafana-data:
```

Notes:
- Every new port binds to `127.0.0.1` only, matching this repo's existing convention for `dbPostgres`/`redis`/`minio console`/`mailhog` — **not** proxied through nginx to the LAN by default. If remote access to Grafana is wanted later, add an explicit auth-gated nginx `location` for it deliberately (mirroring the care taken in the recent endpoint security audit, §2 of `server/docs/doc_enpoints_v1_28072026.md`) rather than exposing it by accident the way `/dev/turbopack-cache-size` was.
- `grafana_admin_password` via Docker secret (file-based), not a plaintext env var in `.env` — small, cheap improvement over how some other credentials in this repo are currently handled.

---

## 5. App-side changes needed (server)

### 5.1 Add `prom-client`, expose `/metrics`

```
npm install prom-client
```

New `server/src/core/metrics.ts`:
- One shared `Registry`.
- `httpRequestDuration` (Histogram, labels `method`, `route`, `status_code`) — populate via a Fastify `onResponse` hook in `app.ts` (use the *route pattern*, e.g. `/api/admin/shipments/:id`, not the raw URL, to avoid unbounded label cardinality from path params).
- `httpRequestsTotal` (Counter, same labels).
- Re-export `prom-client`'s default Node process metrics (event loop lag, heap, GC) — free signal, zero extra code.

New route (loopback-reachable only, same posture as §4 — do **not** register it under `/api/` where nginx would proxy it to the LAN, following the exact lesson from the `/dev/turbopack-cache-size` incident earlier this project):
```ts
app.get('/internal/metrics', async (req, reply) => {
  reply.header('Content-Type', register.contentType);
  return register.metrics();
});
```
Bind this only where Prometheus can reach it inside `node_network` — it doesn't need an nginx route at all; Prometheus scrapes `server:5000/internal/metrics` directly over the internal Docker network.

### 5.2 Business-level gauges (updated on an interval inside the app, OR pulled by the exporter — see decision in §9 Phase 2)

Either approach works; recommendation is the **standalone exporter** (§5.4) rather than adding a `setInterval` inside the main API process, so a slow/failing metrics query can never affect request-serving latency. Metrics to expose either way:
- `acquisitions_by_status{status}` (gauge, from `GROUP BY status`)
- `acquisitions_escrow_age_seconds` (histogram/summary, `now() - created_at` for `status='escrow_held'`) — directly targets the stuck-escrow gap found in §2.4.
- `shipments_by_risk_level{risk_level}` (gauge, reuses `PgShipmentRepository.getStats()`'s exact query)
- `conversations_messages_total` / rate (counter-ish gauge sampled on interval)
- `wallet_invariant_negative_balance_count`, `wallet_invariant_ledger_mismatch_count`, `offer_invariant_duplicate_pending_count`, `shipment_invariant_missing_for_escrow_count` — the 4 assertions from `db-health-check.sh`, now graphable and alertable instead of script-only.

### 5.3 Fix the reqId gap (prerequisite, small, do this first — see §9 Phase 0)

Change every `withTelemetry()` (currently 4 copy-pasted versions) to build `new TelemetryCollector(req.log)` instead of the root `logger`, so `"transaction completed"` lines inherit `reqId` and become joinable to the rest of that request's logs in Loki. While touching this, consider extracting the duplicated helper into one shared `server/src/core/withTelemetry.ts` — not required for observability itself, but free cleanup while every call site is already being touched.

### 5.4 New: `observability/business-metrics-exporter/`

Small standalone Node (or Python) service, own `Dockerfile`, ~100–150 lines:
- Connects to Postgres read-only (`SELECT`-only role recommended — see §8).
- On each Prometheus scrape (or a short internal cache TTL, e.g. 10s, to avoid hammering Postgres on every scrape), runs the queries in §5.2 and serves them via `prom-client`'s registry on `:9200/metrics` (or reuse the same `prom-client` pattern as the main app).
- This is the one genuinely new piece of code this plan requires beyond config — everything else is off-the-shelf exporters + Grafana provisioning YAML/JSON.

### 5.5 Log destination: NAS-mounted, configurable (per §2.6 decision #2)

`server/src/config.ts`'s existing `LOG_DIR`/`LOG_FILE`/`LOG_OUTPUT` env vars are repointed, not replaced:
- New default: `LOG_DIR=/mnt/junglenas/logs/node-nginx-clean-server` (was `logs`, a path relative to the container's cwd) — still overridable via `.env`, same as today.
- `docker-compose.yml`'s `server` service gains a new bind mount: `${TELEMETRY_LOG_NAS_DIR:-/mnt/junglenas/logs/node-nginx-clean-server}:/usr/src/server/logs` (same pattern as the existing `dashboard`/`webapp_node_modules` mounts).
- **Startup validation, matching this repo's established NAS-mount-check convention** (`sync_images_to_nas.py`'s `ensure_nas_mounted()`, the smoke-test script's `mountpoint -q` block): before `server` starts writing logs, verify the mount point is real (not an empty directory autofs hasn't triggered yet) and fail loudly with a clear error rather than silently writing logs into a local, un-synced directory that looks identical to the real mount. Concretely: a small check at the top of `src/index.ts`'s `main()`, gated behind `LOG_OUTPUT` including `'file'`, calling `fs.statSync` and comparing device IDs the same way `mountpoint -q` does, OR simplest: shell out to `mountpoint -q` itself from a pre-start wrapper script (matches existing repo style more closely than reimplementing the check in TypeScript).
- **Backup direction is the opposite of the log-source direction** — don't confuse the two: `server` → writes → `/mnt/junglenas/logs/node-nginx-clean-server/` (raw JSON log files, read by Promtail). Separately, a new `server/scripts/ops/backup-telemetry-bucket-to-nas.sh` (new, following the exact `sync_images_to_nas.py`/`db-export-csv.sh` conventions already in `server/scripts/ops/`) periodically runs `mc mirror` (MinIO's own client, already how this repo would talk to MinIO for admin tasks) from the MinIO telemetry bucket to a *different* NAS path, e.g. `/mnt/junglenas/observability-backups/loki-bucket/`. Scheduled via host cron (simplest, matches how nothing else in this app runs background jobs — see §2.4's finding that there's no in-app scheduler anywhere) — not a new always-running container.

---

## 6. Grafana dashboards to build (provisioned as JSON, not clicked together by hand — see §9 Phase 3)

1. **System Health** — `up{job=...}` for every exporter/target (instant "what's down right now" panel), Postgres/Redis/MinIO/MailHog reachability (from the exporters + a blackbox-style check hitting `/api/health`), container restart counts (via `cadvisor` — optional stretch, not in the core plan).
2. **API Performance** — request rate / error rate (4xx vs 5xx) / p50-p95-p99 latency, all sliceable by route, from `httpRequestDuration`. This is the classic RED-metrics dashboard.
3. **Purchase Funnel & Escrow Health** — acquisitions by status over time (stacked), **escrow age distribution with a red line at the alert threshold**, manual wallet interventions timeline (from `wallet_audit_logs`, via the business-metrics exporter or a Postgres datasource panel directly in Grafana — Grafana can query Postgres natively too, worth using for ad-hoc panels that don't need to be alert-driven).
4. **Shipment Risk** — `shipments_by_risk_level` stacked over time, count of `critical` right now as a big single-stat panel, shipment_audit_logs event stream.
5. **Messaging Activity** — message volume/rate, active conversations, (stretch) time-to-first-reply distribution.
6. **Log Explorer** (Loki-backed) — pre-built queries for `level="error"`, filtered by `module`/`service`, with the request-id fix from §5.3 making it possible to click an error and see that whole request's full log trail.

Grafana natively supports **mixed-datasource dashboards** (Prometheus + Loki + direct Postgres panels side by side) — lean on that rather than forcing everything through the metrics exporter.

---

## 7. Alerting

### 7.1 Decision: Grafana Alerting, not a separate Alertmanager

For a stack this size, Grafana's built-in unified alerting (rule evaluation + routing + Slack/email/webhook notification) is enough — a standalone Alertmanager container is only worth it once there are multiple Prometheus instances or need for complex silence/inhibition rules neither of which applies here yet.

### 7.2 Proposed alert rules (start small, expand later)

| Alert | Condition | Severity | Why |
|---|---|---|---|
| Service down | `up == 0` for any exporter target > 1m | Critical | Direct answer to "is X running" |
| Stuck escrow | `count(acquisitions_by_status{status="escrow_held"}) > 0 AND max(acquisitions_escrow_age_seconds) > 14d` | Warning → Critical past 30d | Targets the real gap found in §2.4 — nothing auto-resolves these today |
| Shipment critical risk | `shipments_by_risk_level{risk_level="critical"} > 0` | Warning | Buyer never got tracking before the deadline |
| Wallet invariant violation | any of the 4 `wallet_invariant_*`/`offer_invariant_*`/`shipment_invariant_*` gauges > 0 | Critical | These are the exact assertions `db-health-check.sh` already checks manually — should page, not wait for someone to run a script |
| API error rate | 5xx rate > 2% over 5m, any route | Warning | Classic RED-metric alert |
| API latency | p95 > 1s over 5m, any route | Warning | |
| MailHog unreachable | `up{job="mailhog"} == 0` | Critical | Registration/verification/notification emails would silently stop |

### 7.3 Notification channel

Not yet decided — needs a decision from you (§10) before Phase 4: Slack webhook, email via the existing MailHog/SMTP config (dev) or a real provider (staging/prod), or just an in-Grafana dashboard for now with no paging.

---

## 8. Security posture

Following the exact lesson from this session's own endpoint-security audit (`server/docs/doc_enpoints_v1_28072026.md`, and the `/dev/turbopack-cache-size` incident where a route was accidentally made LAN-reachable by not thinking through nginx's routing):

- Every new service (`prometheus`, `loki`, `grafana`, exporters) binds to `127.0.0.1` only, exactly like `dbPostgres`/`redis`/`minio` console/`mailhog` already do — **none of this is proxied through nginx to the LAN by default.**
- `server`'s new `/internal/metrics` route is reachable only inside `node_network` (Prometheus container to `server` container, direct), never registered under a path nginx would proxy — same fix pattern as the Turbopack-cache-route incident, applied proactively this time instead of after the fact.
- `postgres-exporter`/`business-metrics-exporter` should use a **dedicated read-only Postgres role**, not the app's own `POSTGRES_USER` — smaller blast radius if an exporter is ever compromised or misconfigured. (Concrete: `CREATE ROLE observability_ro LOGIN PASSWORD '...'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO observability_ro;` in a new migration or a one-off ops script, not the main app's migration-tracked schema.)
- Grafana admin password via Docker secret (file), not a plaintext `.env` var.
- If/when Grafana needs to be LAN- or internet-reachable, add it deliberately through nginx with its own `location` block, real auth (Grafana supports OAuth/basic auth proxying), and — learning from the rate-limiting gap the security audit already found in the main app — actually rate-limit it this time.

---

## 9. Phased rollout

**Phase 0 — prerequisite fix (do first, ~1-2 hrs):** fix `withTelemetry()` to use `req.log` instead of the root logger (§5.3). Everything downstream (log correlation, error-to-request tracing in Grafana) is weaker without this, and it's a trivial, low-risk change.

**Phase 1 — logs only (~half a day):** stand up Loki + Promtail against the *already-existing* `server/logs/server.log` file. Zero app code changes needed beyond Phase 0. Immediate payoff: searchable/graphable logs in Grafana, no waiting on metrics work. Good first deliverable to validate the whole stack boots and networks correctly before adding more services.

**Phase 2 — infra metrics (~half a day):** `postgres-exporter` + `redis-exporter` + Prometheus, wired to existing services, zero app changes. Gets "is Postgres/Redis actually healthy" graphable immediately.

**Phase 3 — app metrics (~1-2 days):** `prom-client` in `server` (§5.1), the `/internal/metrics` route, the business-metrics-exporter (§5.4) for the purchase/shipment/invariant gauges. This is the phase with actual new application code.

**Phase 4 — dashboards + alerting (~1 day):** provision the 6 dashboards in §6, wire the alert rules in §7.2, decide on a notification channel (§10). Optionally also wrap `apiHealth.ts`'s existing synthetic purchase-test as a scheduled metric (`api_health_synthetic_purchase_test_success{}` gauge, run every N minutes by the business-metrics-exporter calling that route internally) so the hand-built synthetic monitoring becomes a time series too, not just an on-demand dashboard click.

**Phase 5 — stretch, not required for the stated goal:** real distributed tracing (OpenTelemetry SDK + an OTel collector + Tempo, replacing/augmenting `TelemetryCollector`) if request-level trace visualization ever becomes necessary beyond what structured logs + reqId correlation already give.

---

## 10. Open questions before implementation starts

**Resolved 2026-08-05** (see §2.6): bucket storage location, log source, metrics durability, NAS-failure behavior. Implementation is now underway starting with Phase 0/1.

Still open, revisit as later phases approach:

1. **Notification channel for alerts** (§7.3) — Slack/email/none-yet?
2. **Retention** — 15 days proposed for Prometheus/Loki; fine for dev/staging, but confirm before this ever points at a production database.
3. **Does the stuck-escrow gap (§2.4) get its own fix ticket**, or should Phase 3's alert simply be the permanent detection mechanism for it (i.e., is "admin manually resolves it when alerted" the intended long-term design, or does a real buyer-confirm-receipt flow need to be built)? This plan can monitor the gap either way, but it changes whether Phase 3's alert is a stopgap or the final intended safety net.
4. **Multi-replica `server` in the future?** — if so, `reqId` needs `genReqId` switched to a UUID generator (Fastify supports this via config) before request correlation across replicas would work in Loki; not needed for the current single-instance setup.
5. **Confirm `docker-compose.observability.yml` as a separate opt-in file** (§4) is acceptable, vs. merging everything into the root `docker-compose.yml` directly — separate file means `docker compose up` alone (today's normal dev flow) doesn't change at all unless someone opts in with `-f docker-compose.observability.yml`.

## 11. Implementation log

**2026-08-05 — Phase 0 + Phase 1 complete, verified end-to-end.**

Phase 0:
- `server/src/routes/{shipments,offers,acquisitions,conversations}.ts`'s `withTelemetry()` now takes the request-scoped `log` (`req.log`) as its first argument instead of building off the root `logger` — every `"transaction completed"` line now carries that request's `reqId`.

Phase 1:
- `server/src/core/nasMount.ts` (new) — `checkNasMount()`, uses `fs.statfsSync` to confirm a directory is actually backed by a network filesystem (CIFS magic `0xFE534D42`, empirically confirmed against this project's real NAS mount; NFS's `0x6969` also accepted).
- `server/src/core/logger.ts` — refuses to open the file log destination unless `checkNasMount(config.logDir)` passes, or `ALLOW_LOCAL_LOG_DIR=true` is set. **Verified live**: booting with a bad `TELEMETRY_LOG_NAS_DIR` crashes immediately with a clear error (`detected fs type: 61267` — local ext4, not network); booting with the real NAS path starts clean.
- `server/src/config.ts` — new `allowLocalLogDir` config value.
- `docker-compose.yml` — `server` service gains a bind mount: `${TELEMETRY_LOG_NAS_DIR:-/mnt/junglenas/logs/node-nginx-clean-server}:/usr/src/server/logs`.
- `.env` — documented `TELEMETRY_LOG_NAS_DIR`, `ALLOW_LOCAL_LOG_DIR`, `GRAFANA_ADMIN_PASSWORD`.
- `observability/loki/loki-config.yml`, `observability/promtail/promtail-config.yml`, `observability/prometheus/prometheus.yml`, `observability/grafana/provisioning/{datasources,dashboards}/*.yml`, `observability/grafana/dashboards/logs-explorer.json` — all new.
- `docker-compose.observability.yml` (new, opt-in per §10 Q5) — `minio-init-telemetry-bucket` (one-shot `mc mb`, reuses the existing `minio` service — NOT a dedicated instance), `prometheus`, `loki` (S3 backend = that bucket), `promtail` (tails the NAS path directly, read-only), `postgres-exporter`, `redis-exporter`, `grafana`. Grafana admin password via a plain `.env` var (`GRAFANA_ADMIN_PASSWORD`), matching how `MINIO_ROOT_PASSWORD`/`POSTGRES_PASSWORD` are already handled in this repo — the original plan's Docker-secret idea was dropped as inconsistent with existing convention, not for a technical reason.
- `server/scripts/ops/backup-telemetry-bucket-to-nas.sh` (new) — `mountpoint -q` check, skip+warn if the NAS is down (per §2.6 decision #5), `mc mirror` the bucket to a *separate* NAS path (`/mnt/junglenas/observability-backups/telemetry-logs/`, distinct from the raw-log-source path). Not yet scheduled via cron — that's a manual follow-up (there's no in-app scheduler to hang it off, confirmed in §2.4).

**Verified live end-to-end**: real server logs land on the NAS (`/mnt/junglenas/logs/node-nginx-clean-server/server.log`) → Promtail tails them → Loki (S3-backed by the `telemetry-logs` MinIO bucket) ingests them, queryable (`{job="node-nginx-clean-server"}` returns real log lines) → Grafana up, both datasources provisioned, Log Explorer dashboard provisioned. Prometheus scraping `postgres-exporter`/`redis-exporter` successfully (`up`). Full test suite (308 tests), lint, and `tsc --noEmit` all clean after the Phase 0 changes.

**Not done yet** (Phase 2/3, per the original phasing in §9): `prom-client` in `server`, the `/internal/metrics` route, the business-metrics-exporter (acquisitions/shipments/invariant gauges), custom dashboards for those, alert rules, cron-scheduling the NAS backup script.

**2026-08-05 (later) — Grafana LAN access + community dashboards.**
- Grafana reachable at `https://<host-ip>/grafana/` via a dedicated nginx location (see §12.9) — verified live (`<title>Grafana</title>` through nginx, not the webapp fallback).
- Added `node-exporter` (`prom/node-exporter:v1.8.2`, host `/proc`/`/sys`/`/` read-only mounts, `pid: host`) — host-level CPU/memory/disk/load metrics, scraped by Prometheus.
- Imported 3 well-maintained community Grafana dashboards (grafana.com dashboard IDs, datasource template vars rewired to this stack's actual Prometheus datasource UID since file-based provisioning doesn't get the import wizard's variable-substitution step): **Node Exporter Full** (ID 1860), **PostgreSQL Database** (ID 9628), **Redis Dashboard for Prometheus Redis Exporter 1.x** (ID 763) — all in `observability/grafana/dashboards/`, auto-provisioned alongside the hand-built Log Explorer.
- Verified live: all 4 Prometheus targets (`prometheus`, `postgres-exporter`, `redis-exporter`, `node-exporter`) healthy, and every metric these 3 dashboards depend on (`node_cpu_seconds_total`, `node_memory_MemAvailable_bytes`, `node_filesystem_avail_bytes`, `pg_up`, `pg_stat_database_numbackends`, `redis_up`, `redis_memory_used_bytes`) confirmed present with real values — including `node_filesystem_avail_bytes` correctly reporting the NAS mount itself (`fstype="cifs"`, `mountpoint="/mnt/junglenas"`, ~1.9TB free), a useful early-warning signal for the log/bucket-backup storage this whole feature depends on.

**2026-08-05 (later still) — object-assets bucket + build-cache dashboards.** See §13.4/§13.5 for the full reference.

- **MinIO/bucket dashboard**: enabled MinIO's built-in Prometheus metrics (`MINIO_PROMETHEUS_AUTH_TYPE=public` in `docker-compose.yml`'s `minio` service — safe here since port 9000 was already internal-only), added `minio-cluster`/`minio-bucket` Prometheus scrape jobs. The one community MinIO dashboard on grafana.com (ID 6248) is from 2018 and targets a metrics path (`/minio/prometheus/metrics`) MinIO abandoned years ago — would show "No data" against the current server. Built a custom one instead (`observability/grafana/dashboards/minio-buckets.json`) using real, verified-live metric names (`minio_cluster_health_status`, `minio_bucket_usage_object_total`, `minio_bucket_usage_total_bytes`, `minio_bucket_objects_size_distribution`, `minio_bucket_requests_total`), specifically focused on `blablarags-apparel` (the real image-assets bucket — confirmed live: 6032 objects, ~1.18GB) alongside `telemetry-logs`.
- **Build-cache dashboard**: the Turbopack cache stats (§ earlier in this log — `dashboard/plugins/cacheMonitorPlugin.ts`) are JSON, not Prometheus format, so a small new bridge was built: `observability/turbopack-cache-exporter/` (dependency-free Node script, polls `webapp:3000/dev/turbopack-cache-size` live on each scrape, republishes as `turbopack_cache_*` gauges; reports `turbopack_cache_scrape_success=0` rather than crashing when `webapp` isn't running `npm run dev`). New Prometheus job `turbopack-cache-exporter`. Dashboard `observability/grafana/dashboards/build-cache.json` graphs both real risk signals from the original incident this monitors (size AND staleness vs. their ceilings, not just size — a small-but-stale cache broke the build before, not a large one).
- **Verified live end-to-end**: all 7 Prometheus targets now healthy (`prometheus`, `postgres-exporter`, `redis-exporter`, `node-exporter`, `minio-cluster`, `minio-bucket`, `turbopack-cache-exporter`); every panel *expression* (not just raw metric) from both new dashboards queried directly against Prometheus and confirmed returning real computed values (e.g. cluster capacity used `17.5%`, build-cache-vs-ceiling `49%`, per-bucket request rate by API).
- Grafana now provisions 6 dashboards total: Log Explorer, Node Exporter Full, PostgreSQL Database, Redis, MinIO Buckets, Turbopack Build Cache.

**2026-08-06 — MinIO's data directory moved from local disk to the NAS.** Reverses §2.6 decision #1 at explicit user request ("we need to be sure that all work as we expect in real" — validate this now, in dev, not first find out at the Kubernetes move). Full detail in §2.6a. Summary:
- `docker-compose.yml`'s `minio` service volume changed from the local `minio-data` named volume to `${MINIO_DATA_NAS_DIR:-/mnt/junglenas/logs/minio-data}:/data`; new `.env` var `MINIO_DATA_NAS_DIR`.
- Both buckets (`blablarags-apparel` + `telemetry-logs`) migrated via `rsync` (11,329 files, 1.2GB) before cutover, through a throwaway container per this repo's container-first convention.
- Verified: MinIO boots clean against the NAS (no lock/rename errors); object counts/bytes via Prometheus match exactly pre- and post-migration; single-object GET/PUT/DELETE fast (~80–200ms) — the actual product-serving path is unaffected.
- Found and documented a real limitation: `mc du`'s recursive client-side scan timed out (>2 min) against `blablarags-apparel` over CIFS — bulk/recursive tooling against this bucket should be assumed slow going forward; normal serving traffic was not affected.
- `loki-config.yml`'s header comment and §13.4 updated to match; `MINIO_PUBLIC_URL_BASE`'s hardcoded LAN IP flagged as a separate, not-yet-addressed item.

---

## 12. Configure Process — setup, verification & troubleshooting

Everything below reflects what was actually run to stand this up (§11), not a hypothetical — every command has real, confirmed output. Run every `docker`/`docker compose` command from the repo root (`/home/noel/projects/docker/Dashboard_Server/node-nginx-clean`). Per this project's own convention, **nothing here runs bare on the host** — every check either goes through `docker compose exec`, a throwaway container, or a plain `curl`/`docker run` against a container port; there is no host `node`/`npm`/`mkdir` step anywhere below.

### 12.1 Prerequisites

1. **NAS mounted on the host**:
   ```bash
   mountpoint -q /mnt/junglenas && echo "mounted" || echo "NOT mounted — try 'ls /mnt/junglenas' to trigger autofs, then re-check"
   ```
2. **`.env` has the observability vars** (added in §11 — confirm they're present, not their values, since real secrets shouldn't be pasted around):
   ```bash
   grep -E "^(TELEMETRY_LOG_NAS_DIR|ALLOW_LOCAL_LOG_DIR|GRAFANA_ADMIN_PASSWORD)=" .env
   ```
   Expected: all three present. If `GRAFANA_ADMIN_PASSWORD` is still the placeholder (`dev-only-change-me`), change it before this is reachable by anyone but you.
3. **The main stack is up** (`server`, `dbPostgres`, `redis`, `minio`, `mailhog`, `proxy`, `webapp`):
   ```bash
   docker compose ps
   ```

### 12.2 Bring up the observability stack

Opt-in, layered on top of the main compose file (§4/§10 Q5 — this is deliberate, a plain `docker compose up` is unaffected):

```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d
```

First run pulls 6 images (`prom/prometheus`, `grafana/loki`, `grafana/promtail`, `prometheuscommunity/postgres-exporter`, `oliver006/redis_exporter`, `grafana/grafana`) plus `minio/mc` for the one-shot bucket-init step — expect this to take a minute or two the first time, seconds after that.

### 12.3 Verify each piece, in dependency order

**1. MinIO bucket was created** (the one-shot init container — should have exited 0 already):
```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml logs minio-init-telemetry-bucket
```
Expected: `Added \`local\` successfully.` / `Bucket created successfully \`local/telemetry-logs\`.` / `telemetry-logs bucket ready`. If this failed, nothing downstream (Loki) will have started — check `minio` itself is up first (`docker compose ps minio`).

**2. `server` started without a NAS-mount error**:
```bash
docker compose logs server --tail=20
```
Expected: normal boot lines (`starting server`, `Server listening at ...`, `redis connected`), no `Error: LOG_OUTPUT includes 'file' but logDir ... is not backed by a network filesystem`. If you DO see that error, the NAS bind mount fell through to a local directory — check `mountpoint -q /mnt/junglenas` on the host (§12.1) and `docker compose up -d server` again once it's really mounted.

**3. Logs are actually landing on the NAS** (via a throwaway container, not a host `cat`):
```bash
docker run --rm -v /mnt/junglenas:/mnt/junglenas alpine sh -c \
  "tail -c 500 /mnt/junglenas/logs/node-nginx-clean-server/server.log"
```
Expected: real JSON log lines (`{"level":"info","time":"...","service":"node-nginx-clean-server",...}`).

**4. Promtail is tailing that file**:
```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml logs promtail --tail=20
```
Expected: `msg="Adding target" key="/var/log/telemetry/*.log:{job=\"node-nginx-clean-server\"}"`, `msg="watching new directory" directory=/var/log/telemetry`, `msg="tail routine: started" path=/var/log/telemetry/server.log`.

**5. Loki actually ingested lines** (query it directly — this is the real end-to-end proof, not just "the container is up"):
```bash
docker run --rm --network node-nginx-clean_node_network curlimages/curl:latest \
  -s -G "http://loki:3100/loki/api/v1/query_range" \
  --data-urlencode 'query={job="node-nginx-clean-server"}' \
  --data-urlencode 'limit=5'
```
Expected: `"status":"success"` with a non-empty `result` array containing real log line JSON. An empty `result` with `"status":"success"` usually just means no logs in the queried time window yet — hit a real endpoint on `server` first (e.g. `curl -sk https://<host>/api/health`) to generate a fresh line, then retry.

**6. Prometheus scrape targets are healthy**:
```bash
docker run --rm --network node-nginx-clean_node_network curlimages/curl:latest -s "http://prometheus:9090/api/v1/targets" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); [print(t['labels'].get('job'), t['health'], t.get('lastError','')) for t in d['data']['activeTargets']]"
```
Expected (as of §11's latest entry): `prometheus`, `postgres-exporter`, `redis-exporter`, `node-exporter`, `minio-cluster`, `minio-bucket`, `turbopack-cache-exporter` — all `up`. (No `node-nginx-clean-server`/`business-metrics-exporter` lines yet — those are commented out in `observability/prometheus/prometheus.yml` until Phase 3 ships; see §11. `turbopack-cache-exporter` is expected `up` even when `webapp` isn't running `npm run dev` — it's the exporter container itself that Prometheus checks, not the target it polls; see §13.5 for how that failure surfaces instead.)

**7. Grafana is up and provisioned correctly**:
```bash
docker run --rm --network node-nginx-clean_node_network curlimages/curl:latest -s "http://grafana:3000/api/health"
docker run --rm --network node-nginx-clean_node_network curlimages/curl:latest -s -u "admin:${GRAFANA_ADMIN_PASSWORD}" "http://grafana:3000/api/datasources"
docker run --rm --network node-nginx-clean_node_network curlimages/curl:latest -s -u "admin:${GRAFANA_ADMIN_PASSWORD}" "http://grafana:3000/api/search"
```
Expected: health `"database":"ok"`; datasources returns both `Prometheus` (`isDefault:true`) and `Loki`; search returns 6 dashboards (as of §11's latest entry) — Log Explorer (`nnc-log-explorer`), Node Exporter Full, PostgreSQL Database, Redis Dashboard for Prometheus Redis Exporter 1.x, MinIO — Buckets & Storage (`minio-buckets`), webapp — Turbopack Build Cache (`turbopack-build-cache`).

### 12.4 Open it in a browser

Grafana is loopback-only (`127.0.0.1:3300`, §8 — not proxied through nginx to the LAN by default), so from the machine running Docker itself:

```
http://localhost:3300
```
Login: `admin` / whatever `GRAFANA_ADMIN_PASSWORD` is set to in `.env`. Dashboard: **node-nginx-clean → Log Explorer**. If you need this reachable from another machine on the LAN, don't just change the port binding — add a deliberate, auth-gated nginx `location` for it instead (§8 explains why, referencing the `/dev/turbopack-cache-size` incident earlier this project).

### 12.5 Verify the fail-loud NAS check actually works (optional, destructive-safe)

This was tested once already during implementation (§11) — repeat it any time you want to confirm the safety net is still live, e.g. after touching `docker-compose.yml` or `.env`:

```bash
# Point the bind mount at a definitely-local, definitely-not-NAS path:
TELEMETRY_LOG_NAS_DIR=/tmp/fake-local-not-nas docker compose up -d server
sleep 3
docker compose logs server --tail=10
```
Expected: a crash with `Error: LOG_OUTPUT includes 'file' but logDir (logs) is not backed by a network filesystem (detected fs type: 61267...)`. **Then restore the real value:**
```bash
docker compose up -d server   # picks the real TELEMETRY_LOG_NAS_DIR back up from .env
sleep 3
docker compose logs server --tail=5   # should show a clean boot again
```

### 12.6 Run the MinIO→NAS backup manually

Not yet cron-scheduled (§11) — run it by hand for now:
```bash
./server/scripts/ops/backup-telemetry-bucket-to-nas.sh
```
Expected: `OK: mounted` → `OK: ready` → `mc mirror` output (silent if nothing new to copy) → `OK: backup complete`. Verify the copy landed:
```bash
docker run --rm -v /mnt/junglenas:/mnt/junglenas alpine ls -la /mnt/junglenas/observability-backups/telemetry-logs/
```
To actually schedule it, add a host crontab entry (outside this repo, since there's no in-app scheduler to hang it off — §2.4):
```
0 * * * * cd /home/noel/projects/docker/Dashboard_Server/node-nginx-clean && ./server/scripts/ops/backup-telemetry-bucket-to-nas.sh --yes >> /var/log/telemetry-backup.log 2>&1
```

### 12.7 Tear down (observability stack only, main stack unaffected)

```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml down
```
This stops/removes only the observability containers and their named volumes' *containers* (not the volumes themselves — `prometheus-data`/`loki-data`/`grafana-data` persist across `down`/`up` unless you also pass `-v`). `server`/`dbPostgres`/`redis`/`minio`/etc. are untouched since they're defined in the base file, not this one.

### 12.8 Troubleshooting quick-reference

| Symptom | Likely cause | Fix |
|---|---|---|
| `server` won't start, `Error: LOG_OUTPUT includes 'file' ...` | NAS not mounted, or bind-mount fell through to an empty local dir | `mountpoint -q /mnt/junglenas` on host; re-trigger autofs (`ls /mnt/junglenas`); `docker compose up -d server` again |
| `loki` never starts | `minio-init-telemetry-bucket` failed | Check its logs (§12.3 step 1); confirm `minio` itself is healthy first |
| Promtail up but Loki query returns empty `result` | No log lines in the queried time window, OR Promtail hasn't picked up new lines yet | Hit a real `server` endpoint to generate a fresh log line, retry the query; check `promtail` logs for tailer errors |
| Grafana `datasources` API call returns empty/errors | Wrong `GRAFANA_ADMIN_PASSWORD`, or Grafana still starting | Re-check `.env`; `docker compose -f ... logs grafana` |
| `docker run --network node-nginx-clean_node_network ...` fails with "network not found" | Main stack isn't up yet, or the compose project name differs from `node-nginx-clean` | `docker network ls \| grep node_network` to confirm the real name, adjust accordingly |
| Backup script prints `WARN: ... is not mounted ... Skipping this backup cycle` | NAS dropped mid-session (has happened before in this project) | Same as the first row — this is the intentional skip+warn behavior (§2.6 decision #5), not a bug |
| Editing `nginx/default.conf` and reloading (`nginx -s reload`) doesn't seem to change behavior | **Real gotcha, hit during implementation**: Docker single-file bind mounts pin to the file's *inode* at container-create time. An editor/tool that writes atomically (write-temp + rename, which most editors and formatting tools do) gives the file a NEW inode — the running container keeps serving the OLD one, and `nginx -s reload` faithfully reloads that stale content. `nginx -t`/`-s reload` succeeding proves the syntax was valid, NOT that the container saw your latest edit. | Recreate the container, don't just reload: `docker compose up -d --force-recreate proxy`. Verify with `docker compose exec proxy stat -c '%i' /etc/nginx/conf.d/default.conf` vs `stat -c '%i' nginx/default.conf` on the host — inodes must match. |

### 12.9 Reaching Grafana from the LAN (not just `localhost`)

By default (§12.4) Grafana is loopback-only. To make it reachable at `https://<host-ip>/grafana/` (same pattern as the dashboard itself), two pieces work together — both already applied in this repo, documented here so the setup is reproducible if reverted:

1. **`docker-compose.observability.yml`'s `grafana` service** sets `GF_SERVER_ROOT_URL=%(protocol)s://%(domain)s/grafana/` and `GF_SERVER_SERVE_FROM_SUB_PATH=true` — both are required together, or Grafana generates asset/redirect URLs for the root path and everything 404s under a subpath.
2. **`nginx/default.conf`** has a dedicated `location /grafana/ { proxy_pass http://grafana:3000/grafana/; ... }` block — deliberately its own location (not left to fall through to the catch-all `location /`), rate-limited via the existing `api_general` zone. Auth is Grafana's own login (`GF_USERS_ALLOW_SIGN_UP=false`, no anonymous access) — this only changes reachability, not who can get in once they're there.

**Apply/verify:**
```bash
docker compose exec proxy nginx -t                       # syntax check
docker compose up -d --force-recreate proxy               # NOT just `nginx -s reload` — see the inode gotcha in §12.8
docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d grafana
curl -sk https://<host-ip>/grafana/login | grep -o "<title>[^<]*</title>"   # expect: <title>Grafana</title>
```
If that `curl` instead returns the webapp's own title, nginx is routing the request to the catch-all `location /` — re-check the inode issue above before assuming the location block itself is wrong.

---

## 13. Bucket & NAS Log Collection — Configuration Reference (Docker today, Kubernetes tomorrow)

Two genuinely different storage locations are involved (§2.6 decision #3 — don't conflate them):

- **(A) The raw log SOURCE** — where `server` writes its pino JSON logs, and where Promtail reads them from. Today: a NAS/CIFS directory, bind-mounted into both containers.
- **(B) The bucket** — where Loki's processed chunks/index live (S3 API, served by the existing `minio` container, itself on local disk). Backed up to a *different* NAS path by `backup-telemetry-bucket-to-nas.sh`, on a schedule you control.

Every piece of both is env-var-driven precisely so this section can describe how to change any of it without touching code.

### 13.1 (A) Log source — every config point, today (Docker Compose)

| What | Where it's set | Current value |
|---|---|---|
| Host path Promtail/`server` actually read/write | `.env`: `TELEMETRY_LOG_NAS_DIR` | `/mnt/junglenas/logs/node-nginx-clean-server` |
| Container path inside `server` that path is mounted to | `docker-compose.yml`, `server.volumes` (hardcoded target, not env-driven — matches every other bind mount in this file) | `/usr/src/server/logs` |
| Container path inside `promtail` that path is mounted to | `docker-compose.observability.yml`, `promtail.volumes` (same source var, different target) | `/var/log/telemetry` |
| What `server` believes its log dir is (relative, resolved against its own cwd) | `.env`: `LOG_DIR` | `logs` (→ `/usr/src/server/logs`, i.e. the mount above) |
| Whether `server` refuses to start if that path isn't a real network filesystem | `.env`: `ALLOW_LOCAL_LOG_DIR` | `false` (fail loud — see `server/src/core/nasMount.ts`) |
| What Promtail treats as the log stream identity (Loki label) | `observability/promtail/promtail-config.yml`: `job_name`/`labels.job` | `node-nginx-clean-server` |

**To point this at a different NAS share/path entirely** (e.g. a different NAS box, or switching CIFS→NFS — `checkNasMount()` already accepts NFS's magic number, no code change needed for that specific swap):
```bash
# .env
TELEMETRY_LOG_NAS_DIR=/mnt/some-other-nas/logs/node-nginx-clean-server
```
```bash
docker compose up -d server
docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d promtail
```
Both need restarting since a bind-mount source is only re-resolved at container (re)create — same inode caveat as §12.8, but for a *source path change* rather than a content edit, so `up -d` (which recreates when the resolved config differs) is sufficient here; no explicit `--force-recreate` needed.

**To rename the log stream's Loki label** (if you ever run more than one `server` instance and need to tell their logs apart): change `job_name`/`labels.job` in `promtail-config.yml`, restart `promtail`. Every Grafana panel/alert that filters on `job="node-nginx-clean-server"` (§6's dashboards, once built) would need the same rename.

### 13.2 (B) The bucket — every config point, today (Docker Compose)

| What | Where it's set | Current value |
|---|---|---|
| MinIO instance | reused — `docker-compose.yml`'s existing `minio` service, NOT a dedicated instance (§2.6 decision #1) | `minio:9000` (internal only) |
| Bucket name | `docker-compose.observability.yml`: `minio-init-telemetry-bucket`'s command, AND `observability/loki/loki-config.yml`: `storage_config.aws.bucketnames` — **must match, nothing enforces this at build time** | `telemetry-logs` |
| Credentials | `.env`: `MINIO_ROOT_USER`/`MINIO_ROOT_PASSWORD` (same vars the `minio` service itself already uses — no separate credential set) | defaults to `minioadmin`/`minioadmin` if unset, same fallback `docker-compose.yml` already applies to `minio` itself |
| Where the bucket's actual bytes live on disk | `docker-compose.yml`'s `minio-data` named volume (unchanged by this feature — MinIO's own storage, local disk, §2.6 decision #1) | Docker-managed volume, not the NAS |
| Where the bucket gets backed UP to | `server/scripts/ops/backup-telemetry-bucket-to-nas.sh`: `TELEMETRY_BACKUP_NAS_DIR` (env override) or its default | `/mnt/junglenas/observability-backups/telemetry-logs` |

**To rename the bucket**: change it in both places in the same table row above (they don't share a single source of truth today — a real follow-up would be to derive both from one `.env` var, e.g. `TELEMETRY_BUCKET_NAME`, rather than hardcoding it twice; noted here rather than done, to keep this pass's diff focused), then:
```bash
docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d minio-init-telemetry-bucket
docker compose -f docker-compose.yml -f docker-compose.observability.yml up -d loki
```

**To change the backup destination**:
```bash
# no .env default exists for this one yet — pass it explicitly, or add
# TELEMETRY_BACKUP_NAS_DIR to .env following the same pattern as
# TELEMETRY_LOG_NAS_DIR if you want it to stick permanently.
TELEMETRY_BACKUP_NAS_DIR=/mnt/junglenas/some-other-backup-path ./server/scripts/ops/backup-telemetry-bucket-to-nas.sh
```

### 13.3 Kubernetes: what this maps to, and what's worth reconsidering

Two viable patterns. **Pattern A** is the literal, minimal-change translation of everything above — good for "prove the migration works" with the least risk of behavior changing underneath you. **Pattern B** is the more idiomatic Kubernetes-native approach, worth adopting once you're actually committing to K8s rather than just proving portability.

#### Pattern A — direct translation (NFS-backed PV + in-cluster/managed S3)

**(A) Log source**: replace the Docker bind mount with a `PersistentVolume`/`PersistentVolumeClaim` backed by an NFS CSI driver pointed at the same NAS share (this repo's CIFS mount would need to become NFS for this to work cleanly in K8s — most NFS CSI drivers assume NFS, not CIFS/SMB; `checkNasMount()` already accepts NFS's magic number for exactly this reason).

```yaml
# nas-log-pv.yaml — cluster-scoped, provisioned once
apiVersion: v1
kind: PersistentVolume
metadata:
  name: telemetry-log-nas
spec:
  capacity:
    storage: 10Gi
  accessModes: [ReadWriteMany]   # multiple pods (server + promtail) read/write concurrently
  nfs:
    server: jungle.local          # the NAS, exported over NFS instead of CIFS
    path: /diskc/blablaragsandrigs/logs/node-nginx-clean-server
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: telemetry-log-nas-claim
  namespace: node-nginx-clean
spec:
  accessModes: [ReadWriteMany]
  resources:
    requests:
      storage: 10Gi
  volumeName: telemetry-log-nas
```

Mount that PVC into the `server` Deployment at `/usr/src/server/logs` (same `LOG_DIR`/`checkNasMount()` logic applies unchanged — `fs.statfsSync` sees the NFS magic number the same way it sees CIFS's today) and into the `promtail` DaemonSet/Deployment at `/var/log/telemetry`, exactly mirroring the two bind-mount targets in §13.1's table.

**(B) The bucket**: swap the self-hosted `minio` container for either (a) the [MinIO Operator](https://min.io/docs/minio/kubernetes/upstream/operate/installation/) running in-cluster, or (b) a real managed bucket (AWS S3, GCS via its S3-compat API, etc.) — Loki's `storage_config.aws` block barely changes:

```yaml
# loki-config.yaml diff for a real S3 bucket instead of in-cluster MinIO
storage_config:
  aws:
    # endpoint: minio:9000        # REMOVE — real S3 doesn't need this
    bucketnames: telemetry-logs
    region: eu-central-1          # a REAL region now, not a placeholder
    # access_key_id / secret_access_key: prefer IAM roles (IRSA on EKS,
    # Workload Identity on GKE) over static keys where the cloud supports it
    # s3forcepathstyle: true      # REMOVE — only needed for MinIO's path-style API
    # insecure: true              # REMOVE — real S3 is always TLS
```

Credentials move from a plaintext `.env` var to a `Secret`:
```yaml
apiVersion: v1
kind: Secret
metadata:
  name: telemetry-bucket-credentials
  namespace: node-nginx-clean
type: Opaque
stringData:
  access_key_id: "..."
  secret_access_key: "..."
```
mounted into Loki's pod as env vars (`AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, Loki's S3 client reads the standard AWS SDK env vars too, not just the config file fields).

**Backup job → CronJob** (direct translation of `backup-telemetry-bucket-to-nas.sh`, which already has nothing Docker-specific in its actual backup logic beyond the `mc`-via-container pattern — that part translates almost as-is):
```yaml
apiVersion: batch/v1
kind: CronJob
metadata:
  name: backup-telemetry-bucket-to-nas
  namespace: node-nginx-clean
spec:
  schedule: "0 * * * *"
  jobTemplate:
    spec:
      template:
        spec:
          restartPolicy: OnFailure
          containers:
            - name: mc-mirror
              image: minio/mc:latest
              command: ["sh", "-c", "mc alias set local http://minio:9000 \"$MINIO_ROOT_USER\" \"$MINIO_ROOT_PASSWORD\" && mc mirror --overwrite local/telemetry-logs /backup"]
              envFrom:
                - secretRef: { name: minio-credentials }
              volumeMounts:
                - { name: nas-backup, mountPath: /backup }
          volumes:
            - name: nas-backup
              nfs: { server: jungle.local, path: /diskc/blablaragsandrigs/observability-backups/telemetry-logs }
```
This is exactly what a real K8s deployment needs instead of the host crontab entry in §12.6 — a `CronJob` IS the scheduler this codebase doesn't have (§2.4), no separate always-running container required, matching the same "not an always-on service" design choice made for the Docker version.

#### Pattern B — Kubernetes-native (recommended once you're committing to K8s, not just proving portability)

Skip (A)'s log-source PV entirely. Instead:
- `server` just logs to **stdout** (its existing `LOG_OUTPUT=stdout` mode — already supported, zero code change) — the standard 12-factor-app expectation in K8s.
- A **Promtail (or Fluent Bit/Vector) DaemonSet** reads every pod's stdout the way the kubelet already captures it (`/var/log/pods/**/*.log` on each node) — this is what Loki's own Helm chart sets up by default, and it's the pattern this repo's own plan (§2.6 decision #2) explicitly discussed and set aside for the *current Docker Compose phase specifically* because you wanted a NAS-defined, cross-container-reachable log source at the time. In Kubernetes, the DaemonSet-per-node model removes the reason that mattered — every pod's stdout is already centrally reachable by the DaemonSet without any shared filesystem at all.
- The bucket stays exactly as in Pattern A (real S3, or in-cluster MinIO).

### 13.4 The OTHER bucket — object assets (`blablarags-apparel`), today MinIO, tomorrow maybe real S3

Everything in §13.1/§13.2 is about `telemetry-logs` (Loki's own storage). This is a **completely separate bucket, same MinIO instance**: `blablarags-apparel`, the real product/apparel photo storage `PgApparelRepository`/`MinioObjectStorage` write to. It's the one that actually matters for "detect issues in our system" from a business standpoint — it's live user-facing storage, not internal tooling data.

**Config, today:**
| What | Where |
|---|---|
| Enables MinIO's built-in Prometheus endpoints (both buckets, cluster-wide) | `docker-compose.yml`'s `minio` service: `MINIO_PROMETHEUS_AUTH_TYPE=public` |
| Cluster-wide metrics (capacity, health, drives/nodes online) | `GET http://minio:9000/minio/v2/metrics/cluster` |
| Per-bucket metrics (object count, bytes used, size distribution, request rate) | `GET http://minio:9000/minio/v2/metrics/bucket` |
| Prometheus scrape jobs | `observability/prometheus/prometheus.yml`: `minio-cluster`, `minio-bucket` |
| Dashboard | `observability/grafana/dashboards/minio-buckets.json` (custom-built — the one community MinIO dashboard on grafana.com, ID 6248, is from 2018 and targets an abandoned metrics path; see §11) |

**Real numbers confirmed live** while building this: `blablarags-apparel` — 6032 objects, ~1.18GB. `telemetry-logs` — 4 objects, ~2.3KB (expected, brand new).

**Update 2026-08-06 — storage location, not just metrics, moved to the NAS.** Both buckets described in this table now physically live on `/mnt/junglenas/logs/minio-data/` (see §2.6a) rather than local disk — reversing the local-disk decision from §2.6. Numbers re-confirmed identical post-migration (6,032 objects / 1,235,984,720 bytes for `blablarags-apparel`), and the `minio-buckets.json` dashboard's panels are all still live and correct, since they read from MinIO's Prometheus endpoint (server-side, unaffected by where the underlying disk is). The one thing that changed operationally: bulk/recursive tooling against this bucket (`mc du`, `mc find`, ad-hoc `rsync`) is now slow over CIFS (a live `mc du` timed out at >2 min) — normal single-object serving traffic was not affected (~80–200ms GET/PUT), but keep this in mind for any future backup/admin scripts that touch the bucket in bulk rather than by individual key.

**Migrating this specific bucket to real S3 later** (separately from the Loki bucket in §13.3, and likely on a different timeline — this one probably moves whenever the app itself does, not necessarily together with the observability stack): the *monitoring* side barely changes conceptually, but real S3 does **not** expose Prometheus metrics the way MinIO does — `/minio/v2/metrics/*` is MinIO-specific. Two options at that point:
1. **AWS S3 + CloudWatch**: use the `cloudwatch_exporter` (or Prometheus's native CloudWatch remote-read) to pull S3 bucket size/object-count metrics (`BucketSizeBytes`, `NumberOfObjects` — daily granularity only, a real limitation vs. MinIO's near-real-time numbers) into the same Prometheus/Grafana stack.
2. **Keep MinIO in front of S3** as a gateway/cache layer (MinIO does still support this in some deployment modes) specifically to keep the same near-real-time Prometheus metrics — adds an operational component just for observability, worth weighing against option 1's coarser granularity.
Either way, `MinioObjectStorage`'s own `IObjectStorage` interface (already an abstraction in this codebase) is what would need a real-S3 implementation for the APPLICATION side of this move — separate from, and probably preceding, the monitoring-side decision above.

### 13.5 The build cache — bridging a non-Prometheus JSON endpoint

Different problem entirely from either bucket: `dashboard/plugins/cacheMonitorPlugin.ts` already serves real Turbopack build-cache stats (§ implementation log, 2026-08-04/05 entries — this was built and debugged earlier in this project, including a real routing bug where the endpoint was accidentally unreachable) — but as plain JSON, not Prometheus's text exposition format. Prometheus cannot scrape arbitrary JSON directly.

**Config, today:**
| What | Where |
|---|---|
| The original data source (unchanged, pre-existing) | `webapp:3000/dev/turbopack-cache-size` (dev-only — no such route in a production build) |
| The bridge (new) | `observability/turbopack-cache-exporter/exporter.mjs` — dependency-free Node script, polls the URL above fresh on every Prometheus scrape (no caching layer of its own), republishes as `turbopack_cache_*` Prometheus gauges on `:9300/metrics` |
| Target URL override | `docker-compose.observability.yml`'s `turbopack-cache-exporter.environment.TURBOPACK_CACHE_URL` |
| Prometheus scrape job | `observability/prometheus/prometheus.yml`: `turbopack-cache-exporter` |
| Dashboard | `observability/grafana/dashboards/build-cache.json` — graphs BOTH real risk signals from the original incident (size AND staleness vs. their respective ceilings), not just size |

**Why a whole extra tiny service instead of a Grafana JSON-datasource plugin** (e.g. `yesoreyeram-infinity-datasource`, which CAN query arbitrary REST/JSON directly): consistency with this stack's existing shape — everything else here is already Prometheus-native (metrics, alerting rules when they land, the other 5 dashboards), and a second query paradigm for exactly one dashboard would be one more thing to explain/maintain differently. The exporter is ~90 lines with zero dependencies; the tradeoff was worth it for consistency.

**This is dev-only and will report `turbopack_cache_scrape_success=0`** (not crash, not a Prometheus scrape failure) whenever `webapp` isn't running `npm run dev` — expected/correct in any environment other than active local development.

**Recommendation**: build Pattern A first if/when the K8s move happens — it's the direct, low-surprise continuation of everything already built and tested here. Revisit Pattern B as a deliberate follow-up simplification once the migration itself is no longer the risky part.
