# Permanent RDS Tunnel via SSM (macOS LaunchAgent)

A one-time setup that makes the AWS SSM port-forward tunnel to RDS **always
on** — starts automatically at login, auto-restarts if it ever drops, and
never depends on your local machine's IP address. This supersedes manually
running `aws ssm start-session` every time (see
`CREATE-NEW-CONNECTION-SESSION-PC-TO-AWS.md` for that manual/one-off
version) and the CIDR-allowlist fallback (`terraform.tfvars`'
`allowed_cidr_blocks`) for day-to-day DataGrip use.

## 1. One-time prerequisites

Same as `CREATE-NEW-CONNECTION-SESSION-PC-TO-AWS.md` Part 1 — do these
first if not already done:

```bash
# AWS CLI, if missing
which aws || brew install awscli

# Session Manager plugin (needs your Mac's login password, interactively —
# this is a `sudo` prompt from brew's installer, nothing AWS-related)
brew install --cask session-manager-plugin

# terraform-deploy profile — run yourself, never paste keys into chat/AI
aws configure --profile terraform-deploy
aws sts get-caller-identity --profile terraform-deploy   # should print your IAM identity
```

## 2. Create the LaunchAgent

Save this as `~/Library/LaunchAgents/com.blablarags.rds-tunnel.plist`
(adjust the two `/Users/nbarrera` paths if running this on a different
account):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.blablarags.rds-tunnel</string>

    <key>ProgramArguments</key>
    <array>
        <string>/usr/local/bin/aws</string>
        <string>ssm</string>
        <string>start-session</string>
        <string>--target</string>
        <string>i-0f84cf9304e3517bc</string>
        <string>--document-name</string>
        <string>AWS-StartPortForwardingSessionToRemoteHost</string>
        <string>--parameters</string>
        <string>{"host":["blablarags-prod-postgres.cpm82uswgaj8.eu-central-1.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["5433"]}</string>
        <string>--profile</string>
        <string>terraform-deploy</string>
        <string>--region</string>
        <string>eu-central-1</string>
    </array>

    <key>EnvironmentVariables</key>
    <dict>
        <key>HOME</key>
        <string>/Users/nbarrera</string>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
    </dict>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>StandardOutPath</key>
    <string>/Users/nbarrera/Library/Logs/blablarags-rds-tunnel.log</string>

    <key>StandardErrorPath</key>
    <string>/Users/nbarrera/Library/Logs/blablarags-rds-tunnel.err.log</string>

    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
```

Notes on the two fields most likely to need adjusting on a different
machine:
- `ProgramArguments`' first entry (`/usr/local/bin/aws`) — confirm with
  `which aws`; Apple Silicon Homebrew installs sometimes resolve to
  `/opt/homebrew/bin/aws` instead.
- `EnvironmentVariables.HOME` — must match the actual account running this
  (so `aws` finds `~/.aws/credentials`), and `PATH` must include wherever
  `aws` actually lives if it's not one of the paths already listed.

## 3. Load it (starts the tunnel immediately, plus on every future login)

```bash
mkdir -p ~/Library/LaunchAgents ~/Library/Logs
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.blablarags.rds-tunnel.plist
```

## 4. Verify

```bash
# Should show state = running
launchctl print gui/$(id -u)/com.blablarags.rds-tunnel | head -6

# Should show something listening on 5433
lsof -i :5433

# Should print "succeeded"
nc -zv localhost 5433

# Should show "Port 5433 opened ... Waiting for connections."
tail -20 ~/Library/Logs/blablarags-rds-tunnel.log
```

## 5. Point DataGrip (or psql) at the tunnel

| Field | Value |
|---|---|
| Host | `localhost` |
| Port | `5433` (the local forwarded port — never 5432 directly) |
| Database | `blablarags` |
| User | `admin_dba_bla` |
| Password | from Secrets Manager (`blablarags-prod-postgres-admin-credentials`) |
| SSL | off — the SSM tunnel itself is already encrypted end-to-end; RDS's own `require`-SSL is enforced independently over the tunnel regardless |

```bash
PGPASSWORD='<password>' psql -h localhost -p 5433 -U admin_dba_bla -d blablarags
```

## Why this over the CIDR allowlist

- **No IP tracking** — works identically at home, a coffee shop, or a
  different network entirely; a changed IP never breaks this.
- **Survives reboots** — `RunAtLoad` brings it back on every login with
  zero manual steps.
- **Self-healing** — `KeepAlive` restarts the tunnel if the SSM session
  ever drops (network blip, laptop sleep, etc.), throttled to at most once
  every 10 seconds (`ThrottleInterval`) so a persistent failure doesn't
  spin.
- **Smaller attack surface** — once this is the normal workflow, the
  CIDR-based dev-IP rule in `infra/terraform/environments/prod/security_group.tf`
  can eventually be removed entirely, since RDS access no longer needs a
  direct-IP allowlist rule at all.

## Managing it

```bash
# Stop temporarily (survives until next login/reboot, when RunAtLoad restarts it)
launchctl kill TERM gui/$(id -u)/com.blablarags.rds-tunnel

# Stop and prevent it from starting again
launchctl bootout gui/$(id -u)/com.blablarags.rds-tunnel

# Remove entirely
launchctl bootout gui/$(id -u)/com.blablarags.rds-tunnel
rm ~/Library/LaunchAgents/com.blablarags.rds-tunnel.plist

# Re-apply after editing the plist
launchctl bootout gui/$(id -u)/com.blablarags.rds-tunnel 2>/dev/null
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.blablarags.rds-tunnel.plist
```

## Troubleshooting

- **`state` isn't `running`** — check `~/Library/Logs/blablarags-rds-tunnel.err.log`
  for the actual AWS CLI error (expired/missing `terraform-deploy`
  credentials is the most common cause — re-run
  `aws sts get-caller-identity --profile terraform-deploy` to confirm).
- **Nothing on port 5433** — confirm `session-manager-plugin` is actually
  on `PATH` for launchd's minimal environment (the plist's `PATH` entry
  must include wherever it installed to — `which session-manager-plugin`
  to check).
- **DataGrip still can't connect** — test the raw tunnel first with
  `nc -zv localhost 5433` before troubleshooting DataGrip itself; if that
  fails, the problem is the tunnel, not DataGrip's connection settings.
