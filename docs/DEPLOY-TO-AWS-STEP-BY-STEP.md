# Deploy to AWS — Step by Step

**Version:** v4 — 2026-08-18
**Status:** RDS + EC2 app instance (t3.small) live, `server`+`dashboard` deployed and verified, full observability stack (Prometheus/Loki/Grafana) live at `grafana.blablarags.com`. `shop` code/CI ready but its EC2 instance is explicitly **paused, not deployed** pending go-ahead. SES still sandboxed (sending confirmed working via the restored production credentials; production access / leaving the sandbox is separate and still pending). A full settings-preserving fresh-DB redeploy rehearsal (§9) just proved the entire pipeline — schema/settings restore, `server`, `dashboard`, SMTP send, observability — works end to end from a genuinely empty database.

Master tracking doc for the full production rollout of `server`, `dashboard`,
and `shop` to AWS. Consolidates and supersedes the individual planning docs in
`server/docs/` (`AWS-DEPLOY-PLAN-OK.md`, `AWS-DEPLOY-COMMANDS-STEP-BY-STEP_V1.md`,
`DEPLOY-CICD-PLAN-EC2-GHCR-OK.md`, `EMAIL-SETUP-PLAN-SES-CLOUDFLARE-OK.md`) as
the single place to check "what's done, what's next." Update the status table
and bump the version line at the top whenever a phase completes.

Account: `246064376952` · Profile: `terraform-deploy` · Region: `eu-central-1`
Budget: €116 available through November 2026.

---

## 0. Repos

Each app is its own GitHub repo, not part of this root `Docker-nginx-node` repo:

| Repo | GitHub | Deploy branch |
|---|---|---|
| server | `leonmex/server-blablaragsandrigs` | `master` |
| dashboard | `leonmex/dashboard-blablaragsandrigs` | `master` |
| shop | `leonmex/shop-blablarags` | `master` |

---

## 1. Overall status

| Phase | Status |
|---|---|
| `server`: production `Dockerfile` | ✅ done, merged to `master` |
| `server`: `build.yml` (test-gate → build → push to GHCR) | ✅ done, merged to `master` |
| `server`: fix all test failures blocking the CI gate (393/393 passing) | ✅ done |
| `server`: R2/CDN URL bugs fixed + verified end-to-end | ✅ done |
| `dashboard`: delete stock Ant Design Pro template workflows | ✅ done |
| `dashboard`: production `Dockerfile` + `build.yml` | ✅ done, merged to `master` |
| `SECRETES/` gitignored-secrets convention (symlinked `.auto.tfvars`) | ✅ done |
| Pre-launch nginx Basic Auth configs (`web`/`admin`/`grafana`, not `api`) | ✅ live |
| **Database: AWS RDS via Terraform** | ✅ done — live, schema applied, verified |
| AWS: `ec2.tf` + `github-oidc.tf` (app instance) | ✅ done — live, resized `t3.micro` → `t3.small` |
| AWS: RDS security group — allow app EC2 SG by ID | ✅ done |
| Root repo: `docker-compose.prod.yml` (server/webapp/redis/proxy + observability) | ✅ done, live |
| OIDC deploy step — `server` + `dashboard` | ✅ done, live |
| First real deploy (`server` + `dashboard`) + verification | ✅ done — `api.blablarags.com`, `admin.blablarags.com` both confirmed working |
| Observability: Prometheus + Loki + Grafana + 3 exporters | ✅ done, live at `grafana.blablarags.com` (R2 `logs-blabla` backend) |
| nginx resilience fix (`resolver` + request-time upstream DNS) | ✅ done — induced-failure tested 2026-08-18 |
| `shop`: `output: 'standalone'` + Dockerfile + `build.yml` | ✅ code ready, not yet committed/pushed to `master` |
| `shop`: `ec2-shop.tf` + `docker-compose.shop.yml` + deploy script | ✅ written, **NOT applied — paused, awaiting go-ahead** |
| Email: AWS SES + Cloudflare Email Routing | ⬜ SES still sandboxed (2 denied production-access attempts) |
| Settings-preserving full fresh-DB redeploy rehearsal | ✅ done — see §9 |

**Important note on current AWS state:** the RDS/Terraform work was built and
verified in an earlier pass, then **torn down** (bootstrap + prod both
destroyed) while paused, then rebuilt from scratch on 2026-08-17/18 — this is
the deployment currently live. `shop`'s own EC2 instance was deliberately
**not** applied yet (separate instance, separate go-ahead required — see §3).

---

## 2. Phase: Database (AWS RDS Postgres) — current phase

Full design rationale lives in `server/docs/AWS-DEPLOY-PLAN-OK.md`; exact
commands from the first successful run are in
`server/docs/AWS-DEPLOY-COMMANDS-STEP-BY-STEP_V1.md`. Summary:

- Two-phase Terraform layout: `infra/terraform/bootstrap/` (S3 state bucket +
  DynamoDB lock table, local state) → `infra/terraform/environments/prod/`
  (RDS + SG + secrets + budget, remote state in the bucket bootstrap creates).
- RDS: Postgres `18.4` (matches local dev), `db.t4g.micro`, 20GB gp3 encrypted,
  single-AZ, `publicly_accessible = true` with SG locked to the dev IP only.
- Two credential sets, **user-supplied** (not Terraform-generated), read from
  `SECRETES/terraform/prod.auto.tfvars` (gitignored, symlinked into
  `infra/terraform/environments/prod/`): admin (`admin_dba_bla`) for DBA
  access, app (`app-dba-blablarags`) for the running server — created as an
  actual Postgres ROLE by `server/devops/provisionAwsAppRole.ts` after apply
  (Terraform/RDS can only ever create the one master user).
- Both credential sets stored in Secrets Manager, never as plaintext output.
- Cost guardrail: `aws_budgets_budget` (€40/mo, account-wide) + SNS email
  alerts to `nbgsys@gmail.com` at 50/80/100% actual+forecasted. Alert-only,
  not auto-destroy — `scripts/aws-teardown.sh` is the manual "stop paying now"
  button.
- **Estimated cost: ~$16-17/month** (compute ~$13.40 + storage ~$2.60 +
  Secrets Manager ~$0.80).

### Steps

1. `cd infra/terraform/bootstrap && terraform init && terraform plan -out=bootstrap.tfplan`
   → show plan (expect: 5 to add — S3 bucket, versioning, encryption, public-access
   block, DynamoDB table) → **your approval** → `terraform apply "bootstrap.tfplan"`
2. `cd ../environments/prod && terraform init` (connects to the new S3 backend)
3. Export the two passwords from `SECRETES/terraform/prod.auto.tfvars` (or the
   symlink already resolves it via `.auto.tfvars` — no manual export needed if
   the symlink is in place)
4. `terraform validate && terraform plan -out=prod.tfplan` → show the full
   resource list + **exact estimated monthly cost** → **your approval required**
5. `terraform apply "prod.tfplan"`
6. Confirm the SNS budget-alert email subscription (check `nbgsys@gmail.com`
   for the confirmation link — alerts don't deliver until clicked)
7. Run `server/devops/provisionAwsAppRole.ts` (via `docker compose exec server
   ...`) to create the `app-dba-blablarags` Postgres role + grants
8. `scripts/aws-fetch-db-secret.sh` → produces `.env.aws.rds` (gitignored)
9. Run migrations against RDS as a smoke test: `npm run dev:executemigration
   --prefix server -- --backup --env-file=../.env.aws.rds`
10. Verify: `aws rds describe-db-instances` shows `available`; `npm run
    db:check --prefix server` (with `.env.aws.rds`) passes

Nothing gets applied without the `terraform plan` output shown and approved
first, at both the bootstrap and prod stages.

### What actually happened (2026-08-17)

- **Stale IP lock**: `terraform.tfvars`' `allowed_cidr_blocks` still had an old
  dev IP (`2.245.10.213/32`) from an earlier session — updated to the current
  one (`77.183.158.143/32`) before planning, or the SG would have refused
  every connection including DataGrip.
- **`terraform apply` failed twice on first run, both fixed**:
  1. `aws_budgets_budget` rejected `limit_unit = "EUR"` — this AWS account's
     billing currency only accepts USD. Renamed the variable to
     `budget_limit_usd`, switched to `limit_unit = "USD"`, default `45`.
  2. `aws_db_instance.postgres` hit `FreeTierRestrictionError` on
     `backup_retention_period = 7` — this account still has an active
     free-tier backup-retention cap despite being >12 months old (contradicts
     the original plan's assumption). Reduced to `1` day.
  - Terraform's partial state from the failed run resumed cleanly on the
    corrected re-plan/apply — no manual state surgery needed.
- **RDS is live**: endpoint
  `blablarags-prod-postgres.cpm82uswgaj8.eu-central-1.rds.amazonaws.com:5432`,
  db `blablarags`. This is also the DataGrip connection info (admin user
  `admin_dba_bla`, password in Secrets Manager
  `blablarags-prod-postgres-admin-credentials`, SSL mode `require`).
- **Wrote 2 scripts that were only ever documented before, never built**:
  `scripts/aws-teardown.sh` (emergency stop — tested, confirmed its
  confirmation gate rejects anything but the exact phrase `destroy
  everything`) and `scripts/aws-fetch-db-secret.sh` (pulls the **app** secret
  into gitignored `.env.aws.rds`).
- **`provisionAwsAppRole.ts`** ran successfully — created the
  `app-dba-blablarags` Postgres role with full grants on `blablarags`.
- **Migrations initially failed** (`relation "users" does not exist`) —
  turned out `db/migrations/*.sql` assume `db/schema.sql` already created the
  baseline tables (schema.sql is the "hand-folded snapshot," migrations are
  the versioned artifact on top). Found no schema-only bootstrap path exists
  in this codebase — `db:seed` is the only thing that applies `schema.sql`,
  and it always also inserts dev/mock fixture data (test accounts, demo
  rows). Ran `db:seed` against RDS (per your explicit choice), then:
  - Truncated the purely-synthetic tables (`fake_list`, `dashboard_tags`,
    `user_action_logs`, `pending_category_suggestions`,
    `account_activity_items`) — kept the real reference taxonomy (languages/
    currencies/countries/provinces/cities) and the 1 legitimate dashboard
    notice.
  - Rotated both seeded dashboard accounts' passwords off the public
    `TEST_ADMIN_PASSWORD`/`TEST_USER_PASSWORD` values — new credentials in
    gitignored `SECRETES/prod-dashboard-admin-credentials.md`.
- **Real bug found and fixed**: `db/connection.ts`'s `checkPostgres()`
  (`npm run db:check`) built its own `Pool` directly from
  `config.databaseUrl` without ever passing the `ssl` option — unlike
  `PgConnectionManager.ts` (fixed earlier this session). Always failed
  against RDS regardless of `DB_SSL`. Fixed to match.
- Verified: `npm run db:check` passes (TLS, correct role), `npm run
  dev:executemigration` reports "no pending migrations" (all 65 accounted
  for via `db:seed`'s stamping).

---

## 3. Phase: `shop` — Dockerfile + CI + its own EC2 instance

**Status: code written and locally verified, NOT yet committed to `master`,
NOT yet deployed.** Explicitly paused per your instruction ("let me know
before you deploy shop") — do not push/apply any of this without a fresh
go-ahead.

- `shop/next.config.ts`: `output: 'standalone'` added.
- `shop/Dockerfile`: multi-stage — `npm install` → `next build` → copy
  `.next/standalone` + `.next/static` + `public` into a slim runtime image →
  `CMD ["node", "server.js"]`.
- `shop/.github/workflows/build.yml`: same test-gate → build → push-to-GHCR
  pattern as `server`/`dashboard`, plus a `npm run build` step before `tsc`
  to generate `next-env.d.ts` (missing on a fresh checkout otherwise —
  verified by reproducing the failure without it, then confirming the fix,
  in a genuinely fresh clone).
- **Architecture decision**: `shop` gets its **own EC2 instance**, separate
  from the server+dashboard instance — higher/more public traffic, isolated
  for performance/blast-radius reasons. It reaches the API via the public
  `https://api.blablarags.com` (not private VPC networking) — see
  `nginx/prod/web.blablarags.com.conf`'s `$api_upstream` variable.
- Terraform: `infra/terraform/environments/prod/ec2-shop.tf` (own SG,
  Cloudflare-only/no SSH; own IAM role — only needs a GHCR pull token +
  basic-auth htpasswd, confirmed via code search that shop has zero direct DB
  usage; own Elastic IP). `github-oidc.tf`'s `deploy_repos` local already
  includes a `shop` entry scoped to this instance's ARN.
- `docker-compose.shop.yml` + `scripts/deploy-shop-to-ec2.sh`: written,
  simpler than the main deploy script (no DB/runtime secrets to fetch).

### To actually deploy (only once you give the go-ahead)

1. Commit + push `shop/next.config.ts`, `Dockerfile`, `.github/workflows/build.yml` to `master`
2. `cd infra/terraform/environments/prod && terraform plan` → show the shop
   resources (SG, IAM role, EIP, instance — ~9 resources) + cost (~$9/mo,
   see §4) → **your approval** → `terraform apply`
3. Run `scripts/deploy-shop-to-ec2.sh` for the first bootstrap deploy
4. `curl` the shop instance's Elastic IP directly (before any DNS change) to
   confirm the compose stack came up
5. Point `web.blablarags.com` DNS at the new instance's Elastic IP

---

## 4. Phase: AWS EC2 compute — ✅ done, live

`infra/terraform/environments/prod/ec2.tf`:

- `aws_security_group.app`: inbound 80/443 restricted to Cloudflare's
  published IP ranges only. **No SSH port.**
- IAM role + instance profile: `AmazonSSMManagedInstanceCore` + scoped read
  access to the app DB secret and a GHCR pull-token secret only (never admin).
- `aws_instance.app`: Ubuntu 24.04, public default-VPC subnet + Elastic IP
  (`52.59.99.86`, instance `i-0f84cf9304e3517bc`), no NAT gateway.
- `user_data`: installs Docker + Compose plugin (SSM agent ships preinstalled).
- `security_group.tf` (RDS): ingress rule references the app SG **by ID**,
  alongside the existing dev-IP rule.

**Resized `t3.micro` → `t3.small` on 2026-08-18** (originally chosen as the
budget option at ~$7.50/mo). After adding the full observability stack
(§8) alongside server/dashboard, `free -h` showed only 60MB available with
zero swap configured — a real OOM risk under any traffic/log-volume spike,
not hypothetical. Applied via `terraform apply
-target=aws_instance.app app_resize.tfplan` — confirmed in-place
modification (same instance ID, same Elastic IP), not a replacement.
**+~$7.50/month** (~$15/mo total for compute).

**Total cost so far: RDS (~$16-17/mo) + EC2 t3.small (~$15/mo) + 20GB gp3
(~$1.60/mo) ≈ ~$33-34/month.** `shop`'s own instance (§3, not yet applied)
would add another ~$9/mo on top if/when deployed.

---

## 5. Phase: Deploy trigger (GitHub Actions → AWS via OIDC → SSM) — ✅ done for `server`/`dashboard`

No SSH, no static AWS keys in GitHub.

- `github-oidc.tf`: `aws_iam_openid_connect_provider` for
  `token.actions.githubusercontent.com` + one IAM role per repo (trust policy
  scoped to `repo:leonmex/<repo>:ref:refs/heads/master`), each allowed only
  `ssm:SendCommand` against **its own** target instance —
  `local.deploy_repos` is a map of `{repo, instance_arn}` so `server`/
  `dashboard` scope to the app instance and `shop` scopes to its own
  (not-yet-applied) instance.
- Each repo's `build.yml`, after pushing its image: assumes its role via OIDC
  → `aws ssm send-command` runs the deploy script on the instance
  (`docker compose pull <service> && docker compose up -d <service>`).
- Root repo `docker-compose.prod.yml`: `server`, `webapp` (dashboard),
  `redis`, nginx `proxy`, plus the full observability stack (§8) — pulls
  `ghcr.io/leonmex/*:latest` images, no local builds, no `dbPostgres` (RDS
  replaces it).
- GHCR pulls: a classic (not fine-grained — confirmed incompatible with
  GHCR pull auth) `read:packages` PAT in Secrets Manager, fetched by
  `scripts/deploy-to-ec2.sh` via the instance's IAM role.
- `shop`'s OIDC role/deploy-script equivalents are written but its instance
  isn't applied yet — see §3.

---

## 6. Phase: First real deploy + verification — ✅ done for `server`/`dashboard`

1. Pushed `server`/`dashboard` → Actions ran → images confirmed in GHCR
2. Deploy step reached the instance via SSM
3. `curl`'d the instance directly on `/api/health` before any DNS step —
   confirmed the compose stack came up
4. Pointed Cloudflare DNS at the instance for `api.blablarags.com` and
   `admin.blablarags.com` (proxied/orange-cloud)
5. Verified pre-launch Basic Auth is live on `admin` (not `api`) — same
   htpasswd shared with `web`/`grafana`
6. **Live and confirmed working**: `https://api.blablarags.com` (RDS-backed)
   and `https://admin.blablarags.com` (dashboard)

`shop`'s equivalent first-deploy is pending its own go-ahead (§3).

---

## 7. Phase: Email (AWS SES + Cloudflare Email Routing) — ⬜ SES sandboxed

Full detail in `server/docs/EMAIL-SETUP-PLAN-SES-CLOUDFLARE-OK.md`. Summary:

- **Sending**: AWS SES (chosen over Resend for budget — $0.10/1,000 emails vs
  a flat $20/mo). DNS verification + DKIM CNAMEs in Cloudflare done, SMTP
  credentials configurable via the dashboard's Admin > System > Settings >
  SMTP page (no code/restart needed — `SmtpEmailService.ts` reads from DB).
- **Still blocked**: production-access request denied twice; a
  `ConflictException` now blocks resubmitting via the API. Needs either the
  AWS Console's own "Request production access" form, or checking the AWS
  Support Center case for the real denial reason. Contact address for the
  request: `contact@blablarags.com`.
- **Receiving**: Cloudflare Email Routing (free) — forwards `support@`,
  `contact@`, etc. to an existing inbox. Not started.
- **Cost impact**: effectively $0-1/month once unblocked.

---

## 8. Phase: Observability (Prometheus + Loki + Grafana) — ✅ done, live

Adapted from the existing local-dev `docker-compose.observability.yml`, with
Loki's storage backend swapped from local MinIO to real Cloudflare R2.

- **Placement decision**: runs on the **same instance as server+dashboard**
  (not a 3rd instance, not shop's future instance) — chosen because that
  instance carries less traffic than shop will.
- **Services** (`docker-compose.prod.yml`): `prometheus`, `loki`, `promtail`,
  `postgres-exporter`, `redis-exporter`, `node-exporter`, `grafana`.
- **Log pipeline**: `server` writes structured pino JSON logs to a file
  (`LOG_OUTPUT=both`) on a shared named volume (`server-logs`) → `promtail`
  tails it → ships to `loki` → stored in Cloudflare R2 bucket `logs-blabla`
  (S3-compatible endpoint, `observability/loki/loki-config.prod.yml`).
  Verified end-to-end with a real `request completed` log queried back out
  of Loki.
- **Access**: `grafana.blablarags.com` — same outer nginx Basic Auth as
  `web`/`admin` (same htpasswd), then Grafana's own separate login on top.
  Credentials in `SECRETES/GRAFANA-ACCESS.md` (gitignored); the admin
  password also lives in Secrets Manager
  (`blablarags-prod-app-runtime` → `grafana_admin_password`), fetched into
  `.env` by `scripts/deploy-to-ec2.sh` on every deploy.
- **postgres-exporter tuning**: `--no-collector.wal` +
  `PG_EXPORTER_EXCLUDE_DATABASES=rdsadmin` to silence expected
  permission-denied noise from the least-privilege app DB role.
- **Capacity**: this is what drove the `t3.micro` → `t3.small` resize (§4).
- **Resilience fix**: nginx's `proxy_pass` for all 4 vhosts (`api`, `admin`,
  `web`, `grafana`) converted from static hostnames to `set $var upstream;
  proxy_pass http://$var:port;`, plus `resolver 127.0.0.11 valid=10s;` in
  `00-shared.conf`. Real incident during the t3.small resize: a static
  `proxy_pass http://grafana:3000` is resolved once at nginx startup — if
  that one container wasn't up yet, nginx refused to start **at all**,
  taking down every domain, not just Grafana's. Fixed and proven with an
  induced-failure test (stopped `grafana`, full `proxy` restart): `proxy`
  started cleanly, `api` stayed at `200`, `grafana` isolated-502'd, then
  self-healed to `302` the moment `grafana` came back — no manual nginx
  restart needed.

---

## 9. Phase: Settings-preserving full fresh-DB redeploy rehearsal — ✅ done (2026-08-18)

Goal: prove the *entire* pipeline works end to end from a truly empty
database, before any real launch — not just trust that today's live state
happens to work. Confirmed with you first: pre-launch, no real user data to
lose, so a full wipe is safe; no RDS snapshot needed; reset happens on the
**same** RDS instance (drop/recreate the app database, don't
terraform-destroy/recreate the instance itself); `logs-blabla` R2 objects get
deleted but the bucket itself stays.

Step-by-step gate discipline (each step must pass before the next starts):

1. ✅ Verify current DB connection still works with existing keys/passwords
   (SSM tunnel, `docs/UPDATE-DATABASE-IP-CONNECTION-TO AWS-.md`) — confirmed
   both `admin_dba_bla` and the app role `app-dba-blablarags` connect fine;
   `system_settings` had 91 rows live at time of extraction.
2. ✅ Extract current `system_settings` (settings only, no user rows) from
   the live RDS database.
3. ✅ Fold those settings into `server/db/schema.sql` so a from-scratch
   deploy reproduces today's working configuration instead of generic
   defaults. Of the 91 rows: 80 are real operational config (tax rates,
   invoicing prefixes, security rate limits, shipping/carrier config, legal
   terms version, etc.) baked directly into a new "production settings
   snapshot" block appended to the end of `schema.sql`, using `ON CONFLICT
   (key) DO UPDATE` so it wins over the generic defaults set earlier in the
   same file — validated by applying the full file to a throwaway
   `postgres:18.4` container and spot-checking values landed correctly. The
   other 11 were empty secrets already (blank carrier/CDN credentials) — no
   real value to restore.
   - **3 real secrets excluded from schema.sql on purpose**
     (`smtp.username`, `smtp.password`, `health_test_user.password`) — it's
     a git-tracked file pushed through CI, so plaintext secrets don't belong
     in it. Stored instead in Secrets Manager
     (`blablarags-prod-app-runtime`) and `SECRETES/
     PRODUCTION-SYSTEM-SETTINGS-SECRETS.md`, restored by the new
     `server/devops/restoreProductionSecrets.ts` (run once, right after
     `db:seed`, same invocation pattern as `provisionAwsAppRole.ts`).
   - **Known follow-up, not yet handled**: `health_test_user.*` settings
     point at `mobile_account_id`/`address_id` = 1, but a full `db:seed`
     TRUNCATEs `mobile_accounts` — the health-check test account itself
     needs re-provisioning after a full reset, restoring just its password
     setting isn't enough on its own.
4. ✅ Dropped and recreated the `blablarags` database on the same RDS
   instance (`pg_terminate_backend` + `DROP DATABASE` + `CREATE DATABASE`,
   each as its own connection — `DROP/CREATE DATABASE` can't run alongside
   other statements in one multi-statement psql call), re-granted the
   `app-dba-blablarags` role's privileges (same GRANTs as
   `provisionAwsAppRole.ts`), then ran `db:seed` against it through the SSM
   tunnel (RDS enforces SSL — `DB_SSL=true` required even over the tunnel).
   Verified: 91/91 settings present with restored real values,
   `mobile_accounts` genuinely empty.
5. ✅ Restarted `server` on the fresh DB. `/api/health` → `200`. Full
   end-to-end proof: logged in with the freshly-seeded default admin
   password, confirmed it worked, then **rotated it immediately** (same
   practice as the original bootstrap — public `TEST_ADMIN_PASSWORD`/
   `TEST_USER_PASSWORD` never stay live) and re-verified the old default now
   fails / new password works. New credentials in
   `SECRETES/prod-dashboard-admin-credentials.md`. Also truncated the
   purely-synthetic fixture tables again (`fake_list`, `dashboard_tags`,
   `user_action_logs`, `pending_category_suggestions`,
   `account_activity_items`).
6. ✅ Verified `dashboard` (`admin.blablarags.com`) end to end: basic-auth
   gate reachable, login succeeds through the full nginx→server→RDS path,
   and an authenticated session correctly reads back the restored SMTP
   settings (with the app-layer `••••••` password masking working as
   expected) — proves the settings restoration is really wired through the
   whole stack, not just present in the DB.
7. ✅ SMTP verified for real, not just config-present: triggered an actual
   mobile account registration (`POST /api/accounts`), confirmed via server
   logs the email really sent through the restored SES credentials
   (`"provider":"smtp","msg":"email sent"`), **you confirmed real delivery**
   (received the verification email with a real code), then completed
   `POST /api/accounts/verify` with that real code — full loop closed,
   JWT session issued. Test account cleaned up afterward
   (`TRUNCATE mobile_accounts, pending_registrations`) for a pristine final
   state. Receiving (Cloudflare Email Routing for `support@`/`contact@`) is
   explicitly out of scope for this rehearsal — still "not started," see §7
   above.
8. ✅ Cleaned `logs-blabla`: deleted all 10 objects via `aws s3 rm --recursive`
   against the R2 endpoint, bucket itself confirmed still present
   (`head-bucket` succeeded). Stopped + removed the 7 observability
   containers, deleted their 4 data volumes (`grafana-data`, `loki-data`,
   `prometheus-data`, `promtail-positions`), brought the stack back up —
   all 7 came up clean on the first try (no crash-loop, confirming the
   nginx `resolver` fix from §8 holds under a real fresh-container restart,
   not just the earlier induced-failure test). Verified: Grafana reachable
   and its own login still works (its credential store isn't part of the
   wiped volumes), `api.blablarags.com` unaffected throughout, and — the
   real proof — generated fresh traffic and queried Loki directly
   (`{job="node-nginx-clean-server"}`) to confirm real `request completed`
   log lines are flowing through the entire pipeline again on the
   completely fresh R2-backed stack.

**Standing rule for this phase and beyond**: any new credential generated
along the way (a fresh DB password, new SMTP creds, etc.) gets its own file
in `SECRETES/` immediately, matching the format of existing files like
`GRAFANA-ACCESS.md` — not deferred to a follow-up. Applied throughout: new
`SECRETES/PRODUCTION-SYSTEM-SETTINGS-SECRETS.md`, rotated
`SECRETES/prod-dashboard-admin-credentials.md`.

**Outcome**: the full pipeline — schema/settings restore, `server`,
`dashboard`, SMTP, observability — is now proven to work end to end from a
genuinely empty database, not just trusted because today's live state
happened to work. Confidence for a real launch is meaningfully higher than
before this rehearsal.

---

## Rollback / emergency stop

`scripts/aws-teardown.sh` — the "stop paying now" button. A single
`terraform destroy` on `environments/prod` covers everything in that state —
RDS, the app EC2 instance + shop's (if applied), Elastic IPs, security
groups, the OIDC provider + per-repo deploy roles, instance IAM roles — then
bootstrap is destroyed too. Verifies via `aws rds describe-db-instances` /
`aws ec2 describe-instances` / `aws ec2 describe-addresses` / `aws iam
list-roles` / `aws iam list-open-id-connect-providers` / `aws
secretsmanager list-secrets` / `aws s3 ls` / `aws dynamodb list-tables` that
nothing `blablarags-prod-*` remains. **Not covered**: Cloudflare R2 buckets
(media/CDN, `logs-blabla`) and DNS — different provider, clean up separately
in the Cloudflare dashboard if needed. Requires explicit confirmation before
the first `destroy` — this is a one-way door.

---

## Changelog

- **v4 (2026-08-18)**: Completed §9's settings-preserving full fresh-DB
  redeploy rehearsal — dropped/recreated the RDS database, restored real
  production settings via a new `schema.sql` snapshot block + Secrets
  Manager (see `server/devops/restoreProductionSecrets.ts`), verified
  `server`/`dashboard`/SMTP send end to end (including a real received
  verification email + completed verification), and did a full clean
  redeploy of the observability stack (`logs-blabla` objects cleared,
  volumes wiped) — confirmed the nginx resilience fix from v3 holds under a
  real fresh-container restart, not just the earlier induced-failure test.
- **v3 (2026-08-18)**: EC2 app instance + OIDC deploy live for
  `server`/`dashboard`, both verified working in production. Full
  observability stack (Prometheus/Loki/Grafana) deployed, capacity-driven
  resize to `t3.small`, and a real nginx crash-loop bug found and fixed
  (§8). `shop`'s instance deliberately left unapplied pending go-ahead (§3).
  `scripts/aws-teardown.sh` extended to verify EC2/EIP/IAM cleanup too.
  Started §9: a settings-preserving full fresh-DB redeploy rehearsal to
  prove the whole pipeline before real launch.
- **v2 (2026-08-17)**: Database phase complete — RDS live, schema applied,
  app role provisioned, seeded credentials rotated, 3 real bugs fixed along
  the way (see §2 "What actually happened"). Next: `shop`.
- **v1 (2026-08-17)**: Initial consolidated doc. `server` + `dashboard` code
  and CI merged to `master`. Starting the database (RDS) phase.
