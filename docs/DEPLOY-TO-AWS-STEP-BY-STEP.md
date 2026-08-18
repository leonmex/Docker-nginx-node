# Deploy to AWS — Step by Step

**Version:** v2 — 2026-08-17
**Status:** Server + Dashboard code/CI ready on `master`. RDS Postgres is live. `shop` is next.

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
| Pre-launch nginx Basic Auth configs (`web`/`admin`, not `api`) | ✅ written, not live (needs EC2) |
| **Database: AWS RDS via Terraform** | ✅ done — live, schema applied, verified |
| `shop`: `output: 'standalone'` + Dockerfile + `build.yml` | ⬜ **next — this phase** |
| AWS: `ec2.tf` + `github-oidc.tf` | ⬜ pending |
| AWS: RDS security group — allow new EC2 SG | ⬜ pending |
| Root repo: `docker-compose.prod.yml` (server/shop/redis/proxy) | ⬜ pending |
| OIDC deploy step in each repo's `build.yml` | ⬜ pending |
| First real deploy (server + shop) + verification | ⬜ pending |
| `dashboard`: OIDC deploy step + deploy (last) | ⬜ pending |
| Email: AWS SES + Cloudflare Email Routing | ⬜ pending |

**Important note on current AWS state:** the RDS/Terraform work was built and
verified earlier, then **torn down** (bootstrap + prod both destroyed) while
paused. Confirmed clean via `aws s3 ls` / `aws dynamodb list-tables` (both
empty) before restarting this phase. All Terraform config files are still on
disk under `infra/terraform/` — this phase re-runs `init`/`plan`/`apply` from
scratch, nothing needs to be rewritten.

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

## 3. Phase: `shop` — Dockerfile + CI

- Add `output: 'standalone'` to `shop/next.config.ts`
- New multi-stage `Dockerfile`: `npm install` → `next build` → copy
  `.next/standalone` + `.next/static` + `public` into a slim runtime image →
  `CMD ["node", "server.js"]`
- `.github/workflows/build.yml`: same test-gate → build → push-to-GHCR
  pattern as `server`/`dashboard`

---

## 4. Phase: AWS EC2 compute

New `ec2.tf` in `infra/terraform/environments/prod`:

- `aws_security_group.app`: inbound 80/443 restricted to Cloudflare's
  published IP ranges only. **No SSH port.**
- IAM role + instance profile: `AmazonSSMManagedInstanceCore` + scoped read
  access to the app DB secret and a GHCR pull-token secret only (never admin).
- `aws_instance.app`: Ubuntu 24.04, **`t3.micro`** (budget-driven choice —
  ~$7.50/mo vs `t3.small`'s ~$15/mo), public default-VPC subnet + Elastic IP,
  no NAT gateway.
- `user_data`: installs Docker + Compose plugin (SSM agent ships preinstalled).
- Update `security_group.tf` (RDS): add ingress rule referencing the new app
  SG **by ID**, alongside the existing dev-IP rule.

**Cost added: ~$9/month** → **~$26/month total** with RDS.
Budget check: ~€24/mo × ~3.5 months to end of November ≈ ~€84, leaving ~€32
margin — this is why `t3.micro` was chosen over `t3.small`.

`terraform plan` → show cost/resources → approval → `apply` (same checkpoint
discipline as the database phase).

---

## 5. Phase: Deploy trigger (GitHub Actions → AWS via OIDC → SSM)

No SSH, no static AWS keys in GitHub.

- One-time: `aws_iam_openid_connect_provider` for
  `token.actions.githubusercontent.com` + one IAM role per repo (trust policy
  scoped to `repo:leonmex/<repo>:ref:refs/heads/master`), allowed only
  `ssm:SendCommand` against the app instance.
- Each repo's `build.yml`, after pushing its image: assumes its role via OIDC
  → `aws ssm send-command` runs `/opt/blablarags/deploy.sh` on the instance
  (`docker compose pull <service> && docker compose up -d <service>`).
- Root repo: extend `docker-compose.prod.yml` with `server`, `shop`, `redis`,
  an nginx `proxy` pulling `ghcr.io/leonmex/*:latest` (drop `dbPostgres` — RDS
  replaces it). Synced to the instance via `aws s3 cp` from a small private
  config bucket.
- GHCR pulls: long-lived `read:packages`-only GitHub PAT in Secrets Manager
  (only if the 3 app repos are private — not yet confirmed).

---

## 6. Phase: First real deploy + verification

1. Push to each of `server`/`shop` → watch the Action run → confirm image
   lands in GHCR (`docker manifest inspect ghcr.io/leonmex/<repo>:latest`)
2. Confirm the deploy step reaches the instance via SSM
3. `curl` the instance's Elastic IP on `/api/health` and the shop's root —
   confirms the compose stack before any DNS/Cloudflare step
4. Only once server+shop are verified: add the OIDC deploy step to
   `dashboard` and deploy it last
5. Point Cloudflare DNS at the instance for `api.blablarags.com`,
   `web.blablarags.com`, `admin.blablarags.com`
6. Verify pre-launch Basic Auth is live on `web`/`admin` (not `api`)

---

## 7. Phase: Email (AWS SES + Cloudflare Email Routing)

Full detail in `server/docs/EMAIL-SETUP-PLAN-SES-CLOUDFLARE-OK.md`. Summary:

- **Sending**: AWS SES (chosen over Resend for budget — $0.10/1,000 emails vs
  a flat $20/mo). DNS verification + DKIM CNAMEs in Cloudflare, exit sandbox
  via SES console, SMTP credentials → Secrets Manager, then set
  `system_settings` SMTP fields via the dashboard (no code/restart needed —
  `SmtpEmailService.ts` reads from DB).
- **Receiving**: Cloudflare Email Routing (free) — forwards `support@`,
  `contact@`, etc. to an existing inbox.
- **Cost impact**: effectively $0-1/month.

---

## Rollback / emergency stop

`scripts/aws-teardown.sh` — the "stop paying now" button. Destroys prod
(`environments/prod`) then bootstrap, then verifies via `aws rds
describe-db-instances` / `aws secretsmanager list-secrets` / `aws s3 ls` /
`aws dynamodb list-tables` that nothing `blablarags-prod-*` remains. Requires
explicit confirmation before the first `destroy` — this is a one-way door.

---

## Changelog

- **v2 (2026-08-17)**: Database phase complete — RDS live, schema applied,
  app role provisioned, seeded credentials rotated, 3 real bugs fixed along
  the way (see §2 "What actually happened"). Next: `shop`.
- **v1 (2026-08-17)**: Initial consolidated doc. `server` + `dashboard` code
  and CI merged to `master`. Starting the database (RDS) phase.
