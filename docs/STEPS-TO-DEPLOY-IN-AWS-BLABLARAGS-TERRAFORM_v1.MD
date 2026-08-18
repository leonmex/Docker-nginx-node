# Steps to Deploy blablarags to AWS (Terraform) — History

**Version:** v1 — 2026-08-18
**Status:** Server live at `https://api.blablarags.com` (RDS + EC2 + real TLS).
Email (AWS SES) in progress. Dashboard/shop not yet deployed.

Chronological record of what was actually done to take `server` from code
to a live, publicly reachable production API on AWS — commands, real
values, mistakes hit, and how each was fixed. Companion to
[`DEPLOY-TO-AWS-STEP-BY-STEP.md`](./DEPLOY-TO-AWS-STEP-BY-STEP.md) (the
forward-looking checklist/status doc) — this one is the audit trail.

Account: `246064376952` · Profile: `terraform-deploy` · Region: `eu-central-1`

---

## Phase 0 — Prerequisites (earlier session work, summarized)

- `server` and `dashboard` repos got production `Dockerfile`s and
  `.github/workflows/build.yml` (test-gate → build → push to GHCR).
- All test failures found and fixed (stale fixture passwords, 2
  `RefreshableObjectStorage` bugs, `apparelImageHealth` URL-prefix bugs) —
  393/393 passing locally, lint clean.
- CDN/R2 validated end-to-end locally (`smoke-test-cdn-settings.sh`,
  13/13 pass).
- `server`'s accumulated work merged into `master` (`67b16d0` →
  `72e6156`), confirmed `origin/master` fast-forwards cleanly.
- Root repo `.gitignore` hardened (`SECRETES/`, `.env.aws.rds`, Terraform
  state/plan files, nginx private keys) after an earlier accidental
  675MB-binary commit was caught and safely uncommitted.
- `SECRETES/` convention established: gitignored local secrets, read by
  Terraform via a committed symlink
  (`infra/terraform/environments/prod/secrets.auto.tfvars` →
  `SECRETES/terraform/prod.auto.tfvars`).

---

## Phase 1 — Database (AWS RDS Postgres)

### 1.1 Bootstrap (Terraform state backend)

```bash
cd infra/terraform/bootstrap
terraform init
terraform plan -out=bootstrap.tfplan   # 5 to add, $0/month
terraform apply "bootstrap.tfplan"
```
Created `blablarags-prod-tfstate-246064376952` (S3, versioned, SSE-S3) and
`blablarags-prod-tflock` (DynamoDB). Confirmed via `aws s3 ls` /
`aws dynamodb list-tables` that the account was genuinely clean before
applying (bootstrap had been torn down in an earlier session).

### 1.2 Emergency teardown script written first

Before touching `environments/prod`, wrote `scripts/aws-teardown.sh` — runs
`terraform destroy` in prod then bootstrap, then verifies via live AWS API
calls that nothing `blablarags-prod-*` remains. Requires typing the exact
phrase `destroy everything` (or `--yes`) to fire. Tested the confirmation
gate with a wrong input (`yes`) — correctly aborted, nothing touched.

### 1.3 `environments/prod` — RDS, security group, secrets, budget

**Stale IP fix first**: `terraform.tfvars`'s `allowed_cidr_blocks` had a
dev IP from an earlier session (`2.245.10.213/32`). Checked current IP
(`curl ifconfig.me` → `77.183.158.143`) and updated it — otherwise even
DataGrip/the admin role couldn't have reached the new RDS instance.

```bash
cd infra/terraform/environments/prod
terraform init
terraform plan -out=prod.tfplan
terraform apply "prod.tfplan"
```

**First apply failed twice**, both fixed and re-applied:
1. `aws_budgets_budget` rejected `limit_unit = "EUR"` — this AWS account's
   billing currency only accepts USD. Renamed `budget_limit_eur` →
   `budget_limit_usd`, `limit_unit = "USD"`, default raised to 45.
2. `aws_db_instance.postgres` hit `FreeTierRestrictionError` on
   `backup_retention_period = 7` — a free-tier backup cap still active on
   this account despite being >12 months old (contradicts the original
   plan doc's assumption). Reduced to `1`.

Terraform's partial state (SG/subnet-group/secrets already created)
resumed cleanly on the corrected re-plan — no manual state surgery.

**Final apply**: 4 resources added (`aws_db_instance.postgres` took
6m19s), **13 total resources**, **~$16-17/month**.

```
db_endpoint = blablarags-prod-postgres.cpm82uswgaj8.eu-central-1.rds.amazonaws.com
db_port     = 5432
db_name     = blablarags
db_admin_username = admin_dba_bla       (secret: blablarags-prod-postgres-admin-credentials)
db_app_username   = app-dba-blablarags  (secret: blablarags-prod-postgres-app-credentials)
security_group_id = sg-0b82fec4a480850d2
```
This is also the DataGrip connection info (admin user, SSL mode
`require`).

### 1.4 Provisioning the app role + schema

Wrote `scripts/aws-fetch-db-secret.sh` (pulls the **app** secret from
Secrets Manager into gitignored `.env.aws.rds`, in the exact
`DB_HOST`/`POSTGRES_USER`/etc. var names `config.ts` expects).

```bash
scripts/aws-fetch-db-secret.sh
docker compose exec \
  -e ADMIN_DATABASE_URL="postgresql://<admin>:<pw>@<host>:5432/blablarags" \
  -e APP_DB_NAME=blablarags -e APP_DB_USERNAME=app-dba-blablarags -e APP_DB_PASSWORD="<pw>" \
  server npx tsx devops/provisionAwsAppRole.ts
```
Created the `app-dba-blablarags` Postgres role with full grants.

**Migration attempt #1 failed**: `relation "users" does not exist`.
Root cause: `db/migrations/*.sql` assume `db/schema.sql` already created
the baseline tables — `schema.sql` is the thing that actually builds
`users` etc., and `dev:executemigration` alone can't bootstrap an empty
DB. Also found: `db/connection.ts`'s `checkPostgres()` built its own `Pool`
without ever passing the `ssl` option (unlike the already-SSL-aware
`PgConnectionManager.ts`) — fixed, committed as `dd8e79f`.

**Decision point**: the only thing that applies `schema.sql` is
`npm run db:seed`, which *also* inserts dev/mock fixture data (test
accounts with known passwords, demo rows). Chose to run it as-is, then
clean up:
```bash
npm run db:seed   # against RDS via docker compose exec + env overrides
```
- Truncated purely-synthetic tables: `fake_list`, `dashboard_tags`,
  `user_action_logs`, `pending_category_suggestions`,
  `account_activity_items`.
- Kept real reference taxonomy (languages/currencies/countries/
  provinces/cities) and the 1 legitimate dashboard notice.
- **Rotated both seeded dashboard accounts' passwords** off the public
  `TEST_ADMIN_PASSWORD`/`TEST_USER_PASSWORD` values (bcrypt-hashed new
  random passwords via a one-off `docker compose exec ... node -` script)
  — real credentials now in gitignored
  `SECRETES/prod-dashboard-admin-credentials.md`.

Verified: `npm run db:check` passes (TLS, correct role), and
`npm run dev:executemigration` reports "no pending migrations".

---

## Phase 2 — EC2 compute + GitHub OIDC

### 2.1 `ec2.tf` + `github-oidc.tf`

Priority set by you: server first (validate `api.blablarags.com`
responds), then dashboard — `shop` deferred.

- `aws_security_group.app`: inbound 80/443 from Cloudflare's published IP
  ranges only (same list as `nginx/prod/00-shared.conf`'s
  `set_real_ip_from`), **no SSH**.
- IAM instance role: `AmazonSSMManagedInstanceCore` + scoped
  `secretsmanager:GetSecretValue` on exactly 4 secrets (app DB creds,
  nginx basic-auth htpasswd, GHCR pull token, app-runtime secret) — never
  the RDS admin secret.
- `aws_instance.app`: Ubuntu 24.04, `t3.micro`, 20GB gp3 encrypted, public
  subnet + `aws_eip.app` (stable IP for DNS), `user_data` installs Docker
  + Compose plugin.
- `aws_iam_openid_connect_provider` for
  `token.actions.githubusercontent.com` + one IAM role per repo
  (`blablarags-prod-deploy-server`, `blablarags-prod-deploy-dashboard`),
  trust policy scoped to `repo:leonmex/<repo>:ref:refs/heads/master`,
  allowed only `ssm:SendCommand` against this exact instance.
- RDS `security_group.tf` updated: added a second ingress rule
  referencing the new app SG **by ID**, alongside the existing dev-IP
  rule.

**Apply failed once**: `aws_security_group` `description` field rejected
the em-dash character ("Character sets beyond ASCII are not supported").
Fixed (`—` → `-`), re-applied clean.

**Result**: 5 added, 1 changed, **~$9-10/month** added
(→ ~$26-27/month total with RDS). Instance `i-0f84cf9304e3517bc`,
Elastic IP `52.59.99.86`, SG `sg-07b1e53dfa93d1d76`. Verified via
`aws ssm describe-instance-information` (agent online) and an
`aws ssm send-command` running `docker --version` — confirmed Docker +
Compose installed and working.

### 2.2 GHCR pull token

Both `server`/`dashboard` repos confirmed private (`curl` to the GitHub
API without auth → 404). Instance needs a token to `docker login
ghcr.io`.

**First attempt — fine-grained PAT**: created, worked for `docker login`
(succeeded) but the actual image `pull` returned `denied` — a known
GHCR + fine-grained-PAT compatibility gap.

**Fix — classic PAT**: generated via `github.com/settings/tokens/new`
(direct URL bypasses GitHub steering new tokens toward the fine-grained
flow), scope `read:packages` only. Updated
`SECRETES/terraform/prod.auto.tfvars`'s `ghcr_pull_token`, re-applied
Terraform (1 resource replaced — the Secrets Manager secret version).
Pull succeeded immediately after.

### 2.3 Production-only runtime secrets

`COOKIE_SECRET`/`JWT_ACCESS_SECRET`/`JWT_REFRESH_SECRET`/
`PAYMENT_ENCRYPTION_KEY` didn't exist for prod at all (dev's `.env` has
its own separate dev-only JWT secrets and no durable
`PAYMENT_ENCRYPTION_KEY` — dev runs on an ephemeral random fallback).
Generated fresh via `openssl rand`, saved to
`SECRETES/JWT-TOKENS-PRODUCTION.md` (plain reference file, not a new
Terraform resource — your explicit call to keep this simple). Created the
Secrets Manager secret `blablarags-prod-app-runtime` via plain
`aws secretsmanager create-secret` (not Terraform-managed), containing
those 4 keys plus the real R2 credentials/CDN base URL (reused from
`.env`). Added a `data "aws_secretsmanager_secret"` lookup in `ec2.tf`
(not a managed resource) so the instance role could still be granted
least-privilege read access to it — 1 small IAM policy apply.

---

## Phase 3 — CI: getting `build.yml`'s test gate green

This was the first time `build.yml` had ever run (confirmed via GitHub's
empty "Get started with Actions" page) — surfaced several real,
previously-invisible bugs.

### 3.1 First attempt: wrong root cause (R2, not MinIO)

Initial CI run: 9 real test failures (invoices, wallets, CDN
images/documents, blablaAI model list, 2 cart-race tests) all 500ing.
Diagnosed as: CI's test job never configured `R2_ENDPOINT`/
`R2_ACCESS_KEY`/`R2_SECRET_KEY`, and `index.ts` hardcodes the R2 client to
port 443/SSL true with no override. Made `r2Port`/`r2UseSsl` configurable,
added a `bitnami/minio` service container to `build.yml`.

**Both wrong and broken**: `bitnami/minio:latest` no longer has *any*
published tags on Docker Hub (confirmed via the Docker Hub API — Bitnami
pulled their free images). Per your explicit instruction ("test locally
first, stop the try-and-try pattern"), verified everything locally before
touching CI again:
- `docker run -d minio/minio server /data` starts and health-checks in
  ~2s (official image needs an explicit command — GitHub Actions
  `services:` can't override an image's CMD, hence the plain
  background-container approach instead of a `services:` entry).
- The real `minio` npm client (same construction `index.ts` uses)
  connects and creates a bucket against it.

Switched to official `minio/minio`, started via a `run:` step.

**Still the same 9 failures after that fix** — because `index.ts`'s
`main()` (where R2_* vars matter) is never called by the test suite at
all. `test/api.integration.test.ts` builds its own `MinioObjectStorage`
directly via `buildApp()`, reading `config.minioEndpoint`/`minioPort`/
`minioUseSsl`/`minioAccessKey`/`minioSecretKey`/`minioBucket` — i.e.
`MINIO_*` env vars, the same ones local dev's `docker-compose.yml`
already sets. **Reverted** the unused `r2Port`/`r2UseSsl` change
entirely (wrong code path, untested), pointed CI's MinIO container's
credentials at the `MINIO_*` vars instead. Verified again locally
(matching credential mapping) before pushing — this time `npm run test`
locally: 392/393 (1 pre-existing local-only artifact, a rate-limit test
timed out because `register.max_attempts` had been manually raised to
10000 for earlier smoke-testing) — and the full `_v3` smoke test:
**22/22 passed** with 4 real buyer actions against real NAS images.

### 3.2 Second CI run: a real, much bigger bug — `schema.sql` drift

17 failures this time (different from before) — CDN-Images/Documents (4)
and a cascading wave of shopping-cart 500s (13). Your question ("are you
sure cdn.blablarags.com is correctly configured?") led to checking
`schema.sql` directly: **it was missing migrations 0058, 0059, and 0061
entirely.**

`db/seed.ts` applies `schema.sql` then blindly stamps *every* migration
filename as "applied" in `schema_migrations`, trusting `schema.sql`
already folds in each one's effect. That trust was false for 3 migrations
— invisible on every existing dev DB (all of them had these migrations
replayed for real, years ago, before `schema.sql` fell behind) but fatal
on a genuinely fresh database, which CI was for the first time ever.

Missing: `shopping_cart_items.item_snapshot` column + 2 settings (0058),
the entire `pro_seller_cart_events` table + 1 setting (0059), and all 18
`cdn_images`/`cdn_documents` settings rows (0061).

**Fixed `db/schema.sql`** directly (folded `item_snapshot` into the
existing `CREATE TABLE`, appended the rest in the file's established
append-style convention). **Verified rigorously**, per your instruction:
spun up a brand-new, isolated `postgres:18.4` container from scratch
(not the long-lived local dev DB, which predates this bug and couldn't
have caught it), ran `npm run test` against it — **393/393**, up from
376/393 against the same fresh DB before the fix. Confirmed
`dev:executemigration` reports zero pending migrations afterward.

Pushed (`8f54a29`) — **CI went fully green**: `test` job passed (only the
pre-existing, non-blocking `tsc` annotations remained), `build-and-push`
completed in 33s.

### 3.3 Same bug existed on RDS — fixed there too

You asked directly: does RDS need this too? **Yes** — RDS was seeded with
the same broken `schema.sql` earlier in Phase 1, so it had the identical
gap. Verified first (`item_snapshot column exists: false`,
`pro_seller_cart_events table exists: false`, `cdn settings count: 0`),
then applied the exact same idempotent SQL directly against RDS (not a
full `db:seed` re-run, which would have re-truncated/reseeded fixture
data and undone the credential-rotation cleanup from Phase 1). Verified
after: all three now present.

---

## Phase 4 — First real deploy to EC2

### 4.1 `docker-compose.prod.yml` + deploy script

Found a stale pre-AWS `docker-compose.prod.yml` (built the dashboard
locally, used a local `dbPostgres`, no `server`/`redis`/`proxy` at all —
predated this whole effort). Rewrote it: `server` (GHCR image) + `redis`
+ `proxy` (nginx) only — `webapp`/dashboard deliberately excluded until
that phase starts.

Wrote `scripts/deploy-to-ec2.sh` — runs *on* the instance via
`aws ssm send-command` (never SSH): installs `aws` CLI v2 if missing
(official installer — `apt install awscli` has no candidate package on
this Ubuntu AMI), fetches the DB app secret + app-runtime secret + GHCR
token from Secrets Manager using the instance's own IAM role, assembles
`/opt/blablarags/.env`, `docker login ghcr.io`, `docker compose pull &&
up -d`.

No S3 sync infrastructure built yet for this first deploy — pushed
`docker-compose.prod.yml`, the deploy script, `nginx/prod/{00-shared,api.
blablarags.com}.conf`, and a temporary self-signed cert (placeholder)
directly via `aws ssm send-command` (base64-encoded file writes).

### 4.2 GHCR pull denied again → classic PAT (see 2.2)

First deploy attempt failed at the pull step (`denied`) — same
fine-grained-PAT gap. Fixed by generating and swapping in the classic PAT
(§2.2), re-ran `deploy.sh` — succeeded. All 3 containers (`proxy`,
`redis`, `server`) up. Verified via SSM: `https://localhost/api/health`
through nginx → server → RDS returned `200 {"status":"ok"}`.

### 4.3 Real TLS

Cloudflare Origin CA certificate generated by you (dashboard: SSL/TLS →
Origin Server → Create Certificate, `blablarags.com` + `*.blablarags.com`,
15-year validity) — saved to `SECRETES/cloudflare-origin-cert/`. Verified
locally (`openssl x509`) before pushing: correct SANs, valid dates.
Pushed to the instance (replacing the self-signed placeholder),
`docker compose restart proxy`. Verified via `openssl s_client` on the
instance that nginx now serves the real CloudFlare Origin CA cert
(issuer `CloudFlare Origin SSL Certificate Authority`).

### 4.4 DNS + external validation

You added an `A` record in Cloudflare: `api` → `52.59.99.86`, proxied.
Verified from outside the AWS account entirely:
```bash
curl https://api.blablarags.com/api/health
# → HTTP 200 {"status":"ok"}
```
DNS resolved to Cloudflare's edge IPs (`2606:4700::` range), confirming
the proxy is live. **`api.blablarags.com` is fully working in
production.**

---

## Phase 5 — Email (AWS SES) — in progress

Real user registration was silently broken: `system_settings.smtp.host`
still had the dev default (`mailhog`), which doesn't exist anywhere on
EC2 — verification emails were failing to send with no visible error to
the registering user.

- Confirmed SES account state: no identities, sandbox mode
  (`ProductionAccessEnabled: false`, 200/day cap, 1/sec rate) — sandbox
  alone would have blocked real signups even with correct SMTP config,
  since it can only send to pre-verified addresses.
- Created the SES domain identity for `blablarags.com`
  (`aws sesv2 create-email-identity`) — returned 3 DKIM tokens.
- You added the 3 DKIM CNAME records in Cloudflare (DNS only, not
  proxied) — confirmed live via `dig` shortly after.
- First production-access request **auto-denied** immediately (case
  `178700626400525`) — a known SES gotcha: the automated review rejects
  requests submitted before the domain identity is actually
  DKIM-verified.
- **Next**: waiting for SES to re-poll and verify DKIM (automatic,
  periodic), then resubmit the production-access request. After that:
  generate SES SMTP credentials, store in Secrets Manager, update
  `system_settings.smtp.*` on RDS (directly via SQL for now, since the
  dashboard isn't deployed yet — same technique as the schema fix) to
  point at SES's SMTP endpoint.

---

## Current live resource summary

| Resource | Value |
|---|---|
| RDS endpoint | `blablarags-prod-postgres.cpm82uswgaj8.eu-central-1.rds.amazonaws.com:5432` |
| RDS cost | ~$16-17/month |
| EC2 instance | `i-0f84cf9304e3517bc`, `t3.micro`, Elastic IP `52.59.99.86` |
| EC2 cost | ~$9-10/month (~$26-27/month total) |
| Live URL | `https://api.blablarags.com` ✅ |
| GHCR image | `ghcr.io/leonmex/server-blablaragsandrigs:latest` |
| Deploy role ARNs | `blablarags-prod-deploy-server`, `blablarags-prod-deploy-dashboard` |
| Secrets Manager | `blablarags-prod-postgres-admin-credentials`, `-app-credentials`, `-nginx-basic-auth`, `-ghcr-pull-token`, `-app-runtime` |
| Budget alert | $45/month account-wide, 50/80/100% thresholds |
| Emergency stop | `scripts/aws-teardown.sh` (tested) |

## Not yet done

- `shop`: Dockerfile + `output: 'standalone'` + `build.yml`
- `dashboard`: OIDC deploy step + first deploy (deliberately deferred
  until `server` was fully validated)
- SES: finish production-access approval, SMTP creds, wire into
  `system_settings`
- Cloudflare Email Routing (receiving `support@`/`contact@`)
- Pre-launch Basic Auth on `web`/`admin.blablarags.com` (written, not
  live — no compute for those domains yet)
- `docker-compose.prod.yml`: add `webapp`/shop services when those
  phases start
- Proper S3-based config sync for `docker-compose.prod.yml`/nginx configs
  (this first deploy used direct SSM file pushes)
