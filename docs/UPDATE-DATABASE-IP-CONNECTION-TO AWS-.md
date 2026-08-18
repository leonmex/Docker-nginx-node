# Connecting to AWS: RDS Database + EC2 Logs (no static IP needed)

One setup, two problems solved:

1. **Connecting to the RDS database** (DataGrip / psql / running
   migrations) without depending on your local machine's IP address.
2. **Checking logs / getting a shell on the EC2 instance** (`docker
   compose logs`, container status, debugging) without SSH.

**Problem this solves:** RDS's security group only allows Postgres (5432)
from a hardcoded list of IPs (`allowed_cidr_blocks` in
`infra/terraform/environments/prod/terraform.tfvars`). A home/office
internet connection's public IP is dynamic — it can change every few
minutes on some ISPs — so pinning it in Terraform means re-`apply`ing
constantly just to keep DB access working. **Don't rely on that as the
long-term solution.** Separately, the EC2 instance has no SSH access at
all (deliberate — see `infra/terraform/environments/prod/ec2.tf`'s
security group), so checking logs needs its own answer too.

**The fix for both is the same tool**: AWS Systems Manager (SSM). One
plugin install, then `aws ssm start-session` does either job depending on
the flags — port-forward into RDS, or open a shell on the instance.

## The real fix: SSM port forwarding through the EC2 instance

The EC2 instance (`i-0f84cf9304e3517bc`) already has **permanent,
IP-independent** access to RDS — its own security group is allowed by ID,
not by IP (`infra/terraform/environments/prod/security_group.tf`'s second
ingress rule). Instead of connecting to RDS directly from your machine,
tunnel through the EC2 instance via AWS Systems Manager (SSM) — no SSH, no
IP tracking, works from anywhere your AWS CLI can authenticate.

### One-time setup

Install the `session-manager-plugin` (same one needed for
`aws ssm start-session`):

```bash
curl "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o "session-manager-plugin.deb"
sudo dpkg -i session-manager-plugin.deb
session-manager-plugin   # should print a version banner
```

### Start the tunnel

```bash
aws ssm start-session \
  --target i-0f84cf9304e3517bc \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["blablarags-prod-postgres.cpm82uswgaj8.eu-central-1.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["5433"]}' \
  --profile terraform-deploy --region eu-central-1
```

This opens a local port `5433` that forwards, through SSM (encrypted, no
open port on the instance), to RDS's `5432`. Leave this running in a
terminal for as long as you need the connection — Ctrl+C to stop it.

### Point DataGrip (or psql) at the tunnel, not RDS directly

| Field | Value |
|---|---|
| Host | `localhost` |
| Port | `5433` (the local forwarded port, not 5432) |
| Database | `blablarags` |
| User | `admin_dba_bla` |
| Password | from Secrets Manager (`blablarags-prod-postgres-admin-credentials`) |
| SSL | can stay off for the tunnel itself — the SSM session is already encrypted end-to-end; RDS's own `require`-SSL setting is enforced independently on the actual DB connection through the tunnel |

Same idea for `psql`:
```bash
PGPASSWORD='<password>' psql -h localhost -p 5433 -U admin_dba_bla -d blablarags
```

### Why this is better than the CIDR allowlist

- **No IP tracking** — works identically whether you're at home, a coffee
  shop, or on a different network entirely.
- **No open port on RDS beyond the EC2 instance itself** — the CIDR-based
  dev-IP rule can eventually be removed from `security_group.tf` entirely
  once this is your normal workflow, shrinking RDS's attack surface to
  just the app instance.
- **No Terraform apply needed** to regain access after network changes —
  the tunnel is a client-side/session concern, not infrastructure.

## Bonus: the same setup also gives you a shell on the EC2 instance

The `session-manager-plugin` installed above unlocks `aws ssm
start-session` in general — port forwarding (above) is one mode of it;
a plain interactive shell is another. Same command, just without the
`--document-name`/`--parameters` flags:

```bash
aws ssm start-session \
  --target i-0f84cf9304e3517bc \
  --profile terraform-deploy --region eu-central-1
```

This drops you into a real shell on the instance — no SSH, no key pair,
same SSM channel as the tunnel above. From there, check logs directly:

```bash
cd /opt/blablarags
docker compose -f docker-compose.prod.yml logs --tail 50           # all services
docker compose -f docker-compose.prod.yml logs server --tail 100   # one service
docker compose -f docker-compose.prod.yml logs -f                  # live-follow (Ctrl+C to stop)
docker compose -f docker-compose.prod.yml ps                       # container status
```

(No local plugin? The **AWS Console** → EC2 → Instances → select the
instance → **Connect** → **Session Manager** tab → **Connect** gives the
same shell in the browser, zero local setup — useful as a quick fallback
without installing anything.)

## Fallback: updating the CIDR allowlist directly (old approach)

Only use this if SSM port forwarding isn't available (e.g., no AWS CLI
access) and you need direct IP-based access instead.

1. Get your current public IP: `curl -s https://api.ipify.org`
2. Edit `infra/terraform/environments/prod/terraform.tfvars`:
   ```
   allowed_cidr_blocks = ["<your-ip>/32"]
   ```
3. Apply:
   ```bash
   cd infra/terraform/environments/prod
   terraform plan -out=prod.tfplan
   terraform apply "prod.tfplan"
   ```
4. Verify:
   ```bash
   docker compose exec \
     -e DB_HOST=<rds-endpoint> -e DB_PORT=5432 \
     -e POSTGRES_USER=<user> -e POSTGRES_PASSWORD=<password> \
     -e POSTGRES_DB=blablarags -e DB_SSL=true \
     server npm run db:check
   ```

This only ever grants access to whatever IP is currently in the tfvars
file — every time it changes, repeat the process. This is exactly the
fragility the SSM tunnel approach avoids.
