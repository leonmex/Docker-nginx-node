# Deploy `shop` to AWS — Step by Step

**Version:** v3 — 2026-08-19
**Status:** ✅ Live. `terraform apply` done (9 added, 1 changed, 0 destroyed
— instance `i-0fd474b057cf3d8c0`, Elastic IP `3.78.45.208`). Files staged,
first deploy run — `shop`/`proxy`/`promtail` containers all up. DNS already
pointed at the new instance (done by you, outside this session) — confirmed
real browser traffic reaching it and shop's logs landing in Loki with
`instance="shop"` within minutes of first boot.

Companion to `docs/DEPLOY-TO-AWS-STEP-BY-STEP.md` (the master doc for
`server`/`dashboard`/RDS/observability) — this one is scoped to `shop`'s own
EC2 instance specifically, since it's a separate, later phase with its own
gotchas. Read the master doc first for shared context (Terraform layout,
account/region, SSM access pattern).

Account: `246064376952` · Profile: `terraform-deploy` · Region: `eu-central-1`

---

## 0. Why `shop` gets its own instance

`shop` (the Next.js storefront) runs on a **separate EC2 instance** from
`server`+`dashboard` — higher/more public traffic, isolated for
performance/blast-radius reasons (your own decision, confirmed earlier in
this project). It reaches the API over the public `https://api.blablarags.com`
(not private VPC networking) — see `nginx/prod/web.blablarags.com.conf`'s
`$api_upstream` variable and `docker-compose.shop.yml`'s
`API_PROXY_TARGET`. `shop` has **zero direct database access** — confirmed by
code search (no `pg`/`POSTGRES_*` references anywhere in `shop/`) — so this
phase never touches RDS or its security group.

---

## 1. One-time local setup (credentials/tooling gotchas from the last session)

These bit us during the RDS/app-instance work and will bite again here if
skipped — do them once, up front, instead of mid-deploy.

### 1.1 `session-manager-plugin` — required for any SSM tunnel or shell

Check first:
```bash
session-manager-plugin
```
If `command not found`, install it (needs `sudo` — run this yourself in a
real terminal, an agent/assistant session can't supply a sudo password):
```bash
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/session-manager-plugin.deb
sudo dpkg -i /tmp/session-manager-plugin.deb
session-manager-plugin   # should print a version banner
```
This does **not** persist across some environments/containers — if a fresh
shell reports it missing again later, just reinstall, it's quick.

### 1.2 Where every credential this phase needs actually lives

No new secrets need creating for this phase — everything already exists.
**Never hardcode any of these in a script or command history** — always
fetch live from Secrets Manager, same pattern as every other script in
`scripts/`.

| What | Where | Used for |
|---|---|---|
| GHCR pull token | Secrets Manager `blablarags-prod-ghcr-pull-token` | `docker login ghcr.io` on the shop instance |
| nginx basic-auth htpasswd | Secrets Manager `blablarags-prod-nginx-basic-auth` | pre-launch gate on `web.blablarags.com`, same file as `admin`/`grafana` |
| Cloudflare Origin CA cert/key | **Not actually present in local `nginx/certs/`** (that path holds an old local-dev self-signed cert, `server.crt`/`server.key`) — the real one only exists on the app instance's filesystem at `/opt/blablarags/nginx/certs/cloudflare_origin.{crt,key}`. Relay it instance-to-instance via two `aws ssm send-command` calls (`base64 -w0` on the app instance, decode into place on the shop instance) — there's no direct instance-to-instance file copy without SSH. | TLS termination in shop's own nginx `proxy` container — **same wildcard cert already used on the app instance**, copy don't regenerate |
| GitHub API token (troubleshooting only, not part of the deploy itself) | `SECRETES/GITHUB-TOKEN-SUITE.md` / `GITHUB-TOKEN-SUITE-V2.md` | checking Actions run status / triggering `workflow_dispatch` if CI needs re-running (see §2) |

`shop` needs **no** DB credentials, no `blablarags-prod-app-runtime` secret
(SMTP/JWT/R2 keys — none of that applies here), and no RDS security group
change — this phase is deliberately simpler than the `server`/`dashboard`
one.

### 1.3 SSM tunnel reliability note

The port-forward tunnel (`localhost:5433` → RDS) is **not needed for this
phase at all** (no DB), but if you use it for anything else in parallel:
it drops silently sometimes (SSM session timeout) with no warning — always
verify with a real query before trusting it's still up, don't assume a
tunnel opened earlier in the day is still alive.

---

## 2. Pre-flight checks (do these before `terraform apply`)

Already run once (2026-08-19) as part of the readiness review — repeat if
any time has passed since, since GHCR/CI state can drift.

### 2.1 Confirm `shop`'s code is on `master` and CI produced a real `:latest` image

```bash
cd shop && git status && git log origin/master..HEAD --oneline   # expect: clean, nothing ahead
```

**Known gotcha, already hit once**: `docker/metadata-action`'s
`type=raw,value=latest,enable={{is_default_branch}}` only tags `:latest` if
the run's default-branch check passes — if the GitHub repo's *default
branch* setting doesn't match the branch that pushed (e.g. it was still
`main` at some point), the run reports "success" but **only pushes a
`sha-...` tag, silently missing `:latest`** — and `docker-compose.shop.yml`
pulls `:latest` specifically, so this fails invisibly at deploy time, not at
CI time. Verify the real tag exists before trusting a green CI run:
```bash
docker login ghcr.io -u leonmex --password-stdin <<< "$(aws secretsmanager get-secret-value --secret-id blablarags-prod-ghcr-pull-token --profile terraform-deploy --region eu-central-1 --query SecretString --output text)"
docker manifest inspect ghcr.io/leonmex/shop-blablarags:latest
```
If that 404s, re-run the workflow (`workflow_dispatch` is enabled) via the
GitHub UI, or via the API with a token from `SECRETES/GITHUB-TOKEN-SUITE.md`:
```bash
curl -X POST -H "Authorization: Bearer <token>" -H "Accept: application/vnd.github+json" \
  https://api.github.com/repos/leonmex/shop-blablarags/actions/workflows/build.yml/dispatches \
  -d '{"ref":"master"}'
```

### 2.2 `terraform plan` — confirm no drift

```bash
cd infra/terraform/environments/prod
terraform init -input=false
terraform validate
terraform plan -out=shop.tfplan
```
Expected: **9 to add, 1 to change, 0 to destroy** (`aws_eip.shop`,
`aws_security_group.shop`, `aws_iam_role.shop_instance`,
`aws_iam_instance_profile.shop`, `aws_iam_role_policy.shop_instance_secrets`,
`aws_iam_role_policy_attachment.shop_instance_ssm`,
`aws_iam_role.deploy["shop"]`, `aws_iam_role_policy.deploy_ssm["shop"]`,
`aws_instance.shop` added; `aws_security_group.app` changed **in-place**
— adds the Loki ingress rule from §4.1, does not touch anything else on
that SG). If it shows changes to *any other* existing resource (RDS, the
app instance itself, RDS's security group), **stop and investigate before
applying** — only that one SG rule should ever be a diff on existing infra.

### 2.3 Budget check

Current run-rate (RDS + app `t3.small`) ≈ **$33-34/month**. Adding shop's
`t3.micro` + 20GB gp3 EBS ≈ **+$9/month → ~$42-43/month total**, against the
AWS Budget alert configured at **$45/month** (`blablarags-prod-monthly-cost`
— alert-only via SNS to `nbgsys@gmail.com`, not an auto-destroy). Expect the
80%-threshold email almost immediately after this applies — that's expected,
not a sign something's wrong.

---

## 3. Apply — ✅ done

```bash
cd infra/terraform/environments/prod
terraform apply "shop.tfplan"
```
Show the plan output and get explicit approval before running this —
same checkpoint discipline as every other `apply` in this project. Confirm
after:
```bash
terraform output shop_instance_id shop_public_ip shop_security_group_id
aws ec2 describe-instances --instance-ids <shop_instance_id> --profile terraform-deploy --region eu-central-1 --query "Reservations[].Instances[].State.Name"
aws ssm describe-instance-information --profile terraform-deploy --region eu-central-1 --query "InstanceInformationList[?InstanceId=='<shop_instance_id>']"
```
The last command confirms the SSM agent has checked in — proves the
instance is reachable for the next steps (no SSH, ever).

---

## 4. Stage the files the instance needs (gap found during the readiness review) — ✅ done

**This step is required and easy to miss** — `ec2-shop.tf`'s `user_data`
only installs Docker + Compose; it does **not** put
`docker-compose.shop.yml`, the nginx config, or the TLS cert on the
instance. Without this step, `scripts/deploy-shop-to-ec2.sh` fails at
`docker compose pull` with "no such file." Same stopgap approach used for
the app instance's first deploy (a proper S3-config-sync workflow is still
a future improvement, not built yet for either instance).

Push, via `aws ssm send-command` (`AWS-RunShellScript`, base64-encoded to
avoid shell-quoting issues with multi-line file content — see
`docs/DEPLOY-TO-AWS-STEP-BY-STEP.md`'s troubleshooting notes on this exact
problem):

1. `docker-compose.shop.yml` → `/opt/blablarags/docker-compose.shop.yml`
   (now includes the `promtail` service — see §4.1)
2. `nginx/prod/00-shared.conf` and `nginx/prod/web.blablarags.com.conf` →
   `/opt/blablarags/nginx/prod/`
3. `nginx/certs/cloudflare_origin.crt` and `.key` →
   `/opt/blablarags/nginx/certs/` (same wildcard `*.blablarags.com` cert
   already in use on the app instance — copy, don't regenerate)
4. `scripts/deploy-shop-to-ec2.sh` → `/opt/blablarags/deploy-shop-to-ec2.sh`
   (or just run its contents directly via `send-command` instead of staging
   it as a file first)
5. `observability/promtail/promtail-config.shop.yml` →
   `/opt/blablarags/observability/promtail/promtail-config.shop.yml`

Verify all 5 landed before proceeding:
```bash
aws ssm send-command --instance-ids <shop_instance_id> --document-name AWS-RunShellScript \
  --parameters 'commands=["ls -la /opt/blablarags /opt/blablarags/nginx/prod /opt/blablarags/nginx/certs /opt/blablarags/observability/promtail"]' \
  --profile terraform-deploy --region eu-central-1
```

### 4.1 Observability: shop's logs → the same Loki/R2 store as server (done 2026-08-19)

Built and verified ahead of the actual deploy — ready to go live the moment
the instance exists, no extra steps needed at deploy time beyond staging
the file above.

- **Why not the same approach as `server`**: shop has zero structured
  logging (no pino, nothing writing to a file) — unlike `server`'s
  `LOG_OUTPUT=both` pattern. Rather than add a logging library to the
  Next.js app just for this, `promtail-config.shop.yml` uses
  `docker_sd_configs` to tail Docker's own container log files directly —
  captures both the `shop` container's console output AND `proxy`
  (nginx)'s access/error logs (already going to stdout/stderr in the
  official image) with zero app code changes.
- **Cross-instance network path**: shop's instance pushes to Loki on the
  app instance over the **private VPC** (both instances share
  `vpc-0715111b5b4994170`) at `http://172.31.45.243:3100` (app instance's
  private IP — update this in `promtail-config.shop.yml` if the app
  instance is ever replaced, private IPs aren't stable across a
  replacement). Access is restricted at the **security-group layer only**
  — `ec2.tf`'s `aws_security_group.app` now has an ingress rule allowing
  port 3100 from `aws_security_group.shop`'s ID specifically, same pattern
  already used for RDS's SG referencing the app instance. Loki itself has
  no auth (`auth_enabled: false`) — the SG rule IS the access control, and
  it's never exposed publicly.
- **Also required**: `docker-compose.prod.yml`'s `loki` service changed
  from `expose: "3100"` (container-network-only) to `ports: "3100:3100"`
  (published on the app instance's host) — already pushed and live on the
  app instance (`docker compose up -d loki`, confirmed listening on
  `0.0.0.0:3100`).
- **Every shop log line is labeled `instance=shop`**, plus a `container`
  label (`shop` or `proxy`) — this is what lets Grafana tell these apart
  from server/dashboard's own logs in the same shared Loki store.
- **New Grafana dashboard**: "Shop Instance - Logs & Errors"
  (`https://grafana.blablarags.com/d/shop-instance-logs/`) — 6 panels:
  error count (last 15m), total log volume (liveness signal), error rate
  over time, log volume by container, a filtered "recent errors only" log
  view, and a full live log browser. Error detection happens at query time
  via LogQL (`|~ "(?i)error|\" [45][0-9]{2} "` — matches nginx 4xx/5xx
  status codes AND any line containing "error"), not via promtail-side
  parsing, since nginx's plain-text logs and the Next.js app's unstructured
  console output don't share one schema. Imported via Grafana's API
  (`POST /api/dashboards/db`), not manually clicked together — reproducible
  from `SECRETES/` + the dashboard JSON if it's ever lost.
- **Verified**: both dashboard LogQL queries return `HTTP 200` /
  `"status":"success"` against the live Loki instance (empty result is
  expected — the shop instance doesn't exist yet, so no data has been
  pushed). Confirms the query syntax is correct ahead of time rather than
  discovering a typo after the real deploy.

---

## 5. First deploy — ✅ done

```bash
aws ssm send-command --instance-ids <shop_instance_id> --document-name AWS-RunShellScript \
  --parameters 'commands=["bash /opt/blablarags/deploy-shop-to-ec2.sh"]' \
  --profile terraform-deploy --region eu-central-1
```
Capture the returned `CommandId` directly from this call's own output —
don't rely on `list-command-invocations` to "find" it later, it's been
flaky before. Poll:
```bash
aws ssm get-command-invocation --command-id <CommandId> --instance-id <shop_instance_id> \
  --profile terraform-deploy --region eu-central-1
```

---

## 6. Verify — by IP first, DNS last — ✅ done (DNS already live)

**Don't point DNS until this passes.** Curl the instance's Elastic IP
directly (add `-k` since the cert is for `*.blablarags.com`, not the raw
IP, and add a `Host` header so nginx's `server_name` matching picks the
right vhost):
```bash
curl -sk -H "Host: web.blablarags.com" -u "<basic-auth-user>:<basic-auth-pass>" https://<shop_public_ip>/
```
Expect `200` (or a redirect) from the real Next.js app, behind the
pre-launch basic-auth gate — same 3 users as `web`/`admin`/`grafana`, from
`SECRETES/Basic-Auth/users-access.md`.

Only once that's confirmed working:

1. Add DNS: `web.blablarags.com` → `<shop_public_ip>` (proxied/orange-cloud,
   same as `api`/`admin`/`grafana`)
2. Re-test through the real domain: `curl -s -u "..." https://web.blablarags.com/`
3. Confirm the Cloudflare Origin CA cert is actually serving (no browser
   trust warning) — it's the same cert already proven working on
   `api`/`admin`/`grafana`, so this should just work, but verify anyway
   rather than assume

---

## 7. Rollback / stop paying

`scripts/aws-teardown.sh` covers `shop`'s instance too (it's in the same
Terraform state as everything else — a single `terraform destroy` on
`environments/prod` tears down RDS, both EC2 instances, and all IAM/OIDC
resources together). For `shop` alone without touching anything else:
```bash
cd infra/terraform/environments/prod
terraform destroy -target=aws_instance.shop -target=aws_eip.shop \
  -target=aws_security_group.shop -target=aws_iam_role.shop_instance \
  -target=aws_iam_instance_profile.shop \
  -target=aws_iam_role_policy.shop_instance_secrets \
  -target=aws_iam_role_policy_attachment.shop_instance_ssm \
  -target='aws_iam_role.deploy["shop"]' \
  -target='aws_iam_role_policy.deploy_ssm["shop"]'
```
Show the plan and get approval before running, same as any other destroy.

---

## Changelog

- **v4 (2026-08-19)**: Fixed a real post-deploy bug — background API calls
  from the shop SPA (`/api/v1/cart`, `/api/accounts/refresh`, etc.) were
  401-looping in Loki, never succeeding, while the storefront page itself
  authenticated fine. Root cause: `web.blablarags.com.conf` inherited
  `auth_basic` from its server block down into the `/api/*` proxy
  locations — a client-side `fetch()`/XHR can't interactively answer a
  Basic Auth challenge the way a top-level navigation can. This is exactly
  the problem `api.blablarags.com.conf` already deliberately avoids (see
  its own header comment: "mobile app... can't handle an auth_basic
  prompt") — the `web.blablarags.com` proxy paths just hadn't gotten the
  same treatment. Fixed by adding `auth_basic off;` to the `/api/health`,
  `/api/(accounts...)`, `/api/`, `/sw.js`, and `/manifest.json` locations
  in `nginx/prod/web.blablarags.com.conf` (storefront `location /` still
  gated). Verified: `/api/v1/cart` now returns the real app's own JSON 401
  (no session — correct) instead of nginx's Basic Auth 401, confirmed by
  the absence of a `WWW-Authenticate: Basic` header. Deployed by pushing
  the updated config file to the instance via `send-command` and `nginx -s
  reload` (no container restart needed). Found the identical bug in
  `nginx/prod/admin.blablarags.com.conf` (dashboard) while investigating —
  same fix applied there too, deployed to the app instance the same way,
  verified `/api/health` returns 200 with no auth while `/` still 401s.
- **v3 (2026-08-19)**: Real deploy, done end to end. `terraform apply`: 9
  added, 1 changed, 0 destroyed (instance `i-0fd474b057cf3d8c0`, EIP
  `3.78.45.208`) — matched the pre-validated plan exactly. Staged all 5
  files via base64-encoded `send-command` (§4) — found along the way that
  the Cloudflare Origin cert/key isn't actually on local disk (only an old
  local-dev self-signed cert lives in `nginx/certs/`); relayed the real one
  instance-to-instance from the app instance instead (§1.2 updated). Ran
  `deploy-shop-to-ec2.sh` — `shop`/`proxy`/`promtail` all up on first try.
  DNS for `shop.blablarags.com` was already pointed at the new EIP (done
  outside this session) — confirmed via real browser traffic in `docker
  logs shop` within minutes of boot, nginx correctly 401'ing unauthenticated
  requests (basic-auth gate working), and shop's logs actually landing in
  the shared Loki store (`{instance="shop"}` query returned real `proxy`
  container log lines) — the §4.1 observability wiring built ahead of time
  worked with zero changes needed once real traffic existed.
- **v2 (2026-08-19)**: Added §4.1 — shop's logs now wired into the same
  Loki/R2 store `server`/`dashboard` use, plus a new Grafana dashboard
  ("Shop Instance - Logs & Errors"). Built entirely ahead of the actual
  instance existing: new `aws_security_group.app` ingress rule (private
  VPC, SG-restricted, mirrors the RDS pattern), `docker-compose.prod.yml`'s
  `loki` service now publishes its port (was container-network-only),
  `docker-compose.shop.yml` gained a `promtail` service using
  `docker_sd_configs` (no app code changes needed — shop has no file-based
  logging to tail), and the dashboard's LogQL queries were validated
  against the live Loki instance (`HTTP 200`, empty result as expected —
  no shop data yet). Terraform plan updated: 9 to add, 1 to change
  (the new SG rule).
- **v1 (2026-08-19)**: Initial doc, written after a full readiness
  double-check. Found and fixed a real blocker (GHCR `:latest` tag was
  silently missing due to a default-branch mismatch at CI run time — fixed
  by re-triggering `workflow_dispatch`, confirmed `:latest` now pullable).
  Identified the file-staging gap (§4) before it could cause a deploy-time
  failure. Terraform plan validated clean. Not yet applied.
