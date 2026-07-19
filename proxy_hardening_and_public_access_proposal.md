# Proxy Hardening & Public-Access Proposal

Written as a Sr. DevOps review, at the user's request, following the "port 5645
reverse proxy" agent-prompt draft pasted into the blablaragsandrigs session on
2026-07-19. This is a **design document for the infra team to review and
implement** — no docker-compose/nginx/cert files were touched to produce it
(same split as `new_sections_for_dashboard.md`: app-side work happens in the
Flutter/dashboard repos, infra changes happen here, by this repo's own team).

---

## 1. Reviewing the pasted "port 5645" proposal

The draft asks for a **new**, separate reverse proxy listening on a
non-standard port (5645), TLS-terminating, and forwarding to `server:5000`
over a Docker network.

**What it gets right:**
- TLS termination at the proxy layer, not inside the Fastify app — correct
  separation of concerns.
- Container-to-container communication over an internal Docker network
  rather than exposing the app's port on the host — correct principle.
- Naming Caddy as an option — its automatic HTTPS (auto-issues and renews
  Let's Encrypt certs, zero manual cert-rotation) is a genuine advantage over
  the current hand-run `scripts/generate-certs.sh` once a real public domain
  exists.

**What's missing / actively counterproductive here:**
- **This already exists.** `proxy` (nginx) already does exactly this job:
  TLS termination on 443, forwarding `/api/*` to `http://server:5000` over
  the existing `node_network` (`nginx/default.conf:23-31`,
  `docker-compose.yml`'s `server` service already has no host port —
  `expose: 5000` only). Standing up a second proxy on port 5645 forwarding
  to the same upstream is a **parallel, redundant front door**, not a
  hardening layer.
- **Two TLS endpoints instead of one doubles the attack surface**: two
  certificates to rotate, two configs to patch, two places a misconfig can
  leak information or accept a downgraded cipher — with no corresponding
  security benefit.
- **An arbitrary port number is not a security control.** Port scanners
  enumerate all 65535 ports in seconds; 5645 is not materially harder to
  find than 443. If the goal is "harder to discover," the actual tools for
  that are IP allow-listing, a VPN/tunnel (see §3), or fail2ban — not port
  choice.
- **It doesn't add any of the protections actually asked for** (rate
  limiting, WAF, mTLS, brute-force blocking). It's a second copy of the
  TLS-termination step that already exists, not a new capability.

**Verdict:** don't build this. Extend the proxy that's already there instead.

---

## 2. Recommended approach — harden the existing nginx proxy (LAN-only, no new service)

Given the two things actually asked for — "access to our server in our
internal network" (stay LAN-scoped) and "a proxy that can access in a safe
way" (more protection) — the right move is additive changes to the existing
`proxy` service, not a second one.

> [!NOTE]
> **Sandbox-phase values below are deliberately loose.** We're still in
> active testing (manual QA, smoke-test scripts, repeated register/verify
> cycles) — thresholds tight enough for a production launch would lock out
> testers or throttle test runs. Numbers below are picked so testing isn't
> disrupted; see each subsection's "before production" line for what to
> tighten once this leaves the sandbox phase.

### 2.0 Numbers at a glance

| Setting | Sandbox (now) | Production (later) |
|---|---|---|
| `api_strict` rate | `10r/s`, burst 30 | `2r/s`, burst 5 |
| `api_general` rate | `30r/s`, burst 60 | `10r/s`, burst 20 |
| `/api/admin/*` | not rate-limited (both now and later) | not rate-limited (both now and later) |
| fail2ban `maxretry` | 20 | 5 |
| fail2ban `bantime` | 5 min | 1 hour+ |
| fail2ban `findtime` | 5 min | 10 min |

### 2.1 Rate limiting (blunts brute-force / basic DoS) — ✅ IMPLEMENTED 2026-07-19

Applied directly to `nginx/default.conf` (both the port-443 and port-3000
server blocks, since both proxy `/api/`). **Needs `docker compose restart
proxy` to take effect** — nginx doesn't hot-reload a bind-mounted config.

Endpoint inventory, verified directly against the current route source
(`server/src/routes/*.ts`), not just the migration plan doc — used below to
assign each path to the right zone:

| Method | Path | Auth | Zone |
|---|---|---|---|
| POST | `/api/accounts` | none | **strict** — registration/spam target |
| POST | `/api/accounts/verify` | none | **strict** — OTP-guessing target |
| POST | `/api/accounts/verify/resend` | none | **strict** — email-bombing target |
| POST | `/api/accounts/refresh` | refresh token in body | **strict** — token replay target |
| POST | `/api/login/account` | none | **strict** — dashboard login, pre-existing |
| GET | `/api/me` | Bearer accessToken | general — already gated by a valid token |
| POST/PUT/DELETE | `/api/v1/apparel*` | Bearer accessToken | general — already gated |
| GET/POST | `/api/admin/*` (payment-fraud-reviews, and any future admin CRUD sections) | dashboard session cookie | **exempt** — see below |
| GET | `/api/health` | none | **exempt** — liveness checks shouldn't be throttled |

**`/api/admin/*` was moved from "general" to fully exempt** after a real
gap was flagged: the dashboard is the trusted internal admin tool and can
legitimately fire thousands of requests bulk-auditing/checking mobile
accounts — no fixed rate ceiling is "high enough" to guess correctly for
that, and the session-cookie gate (`requireAdmin()`) is already the actual
defense on every route under this prefix. A `location /api/admin/` block
with no `limit_req` at all (same treatment as `/api/health`) is the correct
fix, not a higher number.

Add to `nginx/default.conf`, in the `http` context (or a shared snippet
included by it) — **sandbox-phase rates** (see §2.0 for the production
target to switch to later, same two `limit_req_zone` lines, just smaller
numbers):
```nginx
limit_req_zone $binary_remote_addr zone=api_general:10m rate=30r/s;
limit_req_zone $binary_remote_addr zone=api_strict:10m rate=10r/s;
```
Then, splitting the existing `location /api/` block so the strict zone only
covers the unauthenticated auth-entry routes:
```nginx
location /api/health {
  proxy_pass http://server:5000;
  # no limit_req — liveness probes must never be throttled
}

location ~ ^/api/(accounts(/verify(/resend)?|/refresh)?|login/account)$ {
  limit_req zone=api_strict burst=30 nodelay;
  proxy_pass http://server:5000;
  proxy_http_version 1.1;
  proxy_set_header Host $host;
}

location /api/ {
  limit_req zone=api_general burst=60 nodelay;
  proxy_pass http://server:5000;
  proxy_http_version 1.1;
  proxy_set_header Upgrade $http_upgrade;
  proxy_set_header Connection 'upgrade';
  proxy_set_header Host $host;
  proxy_read_timeout 86400s;
  proxy_send_timeout 86400s;
}
```
(nginx matches the most specific `location` block, so the regex block above
takes precedence over the general `/api/` prefix block for those exact
paths — order in the file doesn't matter for this, nginx sorts by
specificity itself, but keeping the strict block declared first reads
clearer.)

**Before production**: drop `api_strict` to `2r/s`/burst 5 and `api_general`
to `10r/s`/burst 20 (the numbers originally proposed) — the sandbox values
above are wide enough that they won't meaningfully stop credential-stuffing,
they only guard against a runaway test loop or a genuine accident.

### 2.2 fail2ban on nginx's own access log (host-level)
Nginx already logs every request with status code
(`docker-compose logs proxy`). A `fail2ban` jail on the host watching for
repeated 401/403 on `/api/accounts/verify` or `/api/login/account` from the
same IP, banning via the host firewall (`iptables`/`nftables`), adds
automatic blocking with no application code changes. This is the standard
"internal network, extra protection" layer for a proxy that's otherwise
correctly configured.

**Sandbox-phase jail settings** (a tester who fails a verification code or
mistypes a password repeatedly shouldn't get banned for an hour mid-QA):
```ini
[nginx-api-auth]
enabled  = true
maxretry = 20
findtime = 5m
bantime  = 5m
```
**Before production**, tighten to something like `maxretry = 5`,
`findtime = 10m`, `bantime = 1h` (or an escalating bantime) — 20 attempts in
5 minutes is fine for catching a runaway/malicious loop but does nothing
against slow, patient credential-stuffing.

### 2.3 mTLS between nginx and the Fastify server (defense in depth inside the Docker network)
Today, `server:5000` trusts anything reachable within `node_network` — in
practice that's only `proxy`, but any other container later added to that
same network (or a compromised `webapp`) could reach it directly, unauth’d,
since the app itself does no origin check. If this networking-layer trust
boundary should be enforced explicitly:
- Issue an internal CA + a client cert for `proxy` and a server cert for
  `server` (a few `openssl` calls under `scripts/`, same idea as
  `generate-certs.sh` but for a second, INTERNAL-only cert pair).
- Fastify listens with `requestCert: true` + verifies the client cert's CN
  before handling the request (a small `preHandler`, or terminate TLS in
  front of Fastify with a tiny sidecar `nginx`/`stunnel` config that does the
  cert check).
- This is meaningful hardening for a genuinely zero-trust internal network,
  but is real added operational complexity (cert issuance + rotation for an
  INTERNAL pair too) — recommend only if the container-to-container trust
  boundary is a real concern for this deployment, not by default.

### 2.4 Baseline WAF-style rules (cheap wins, no new service)
A few `nginx`-native rules cover a good fraction of noise/scanner traffic
before it reaches Fastify at all:
```nginx
# Block common scanner paths that never legitimately hit this API
location ~* /(\.env|\.git|wp-admin|phpmyadmin) { return 404; }
# Reject obviously malformed methods
if ($request_method !~ ^(GET|POST|PUT|DELETE|OPTIONS)$) { return 405; }
```
For a real WAF (SQLi/XSS pattern matching, OWASP CRS), `nginx` with the
`ModSecurity` module (or swapping in `Coraza`, the actively-maintained Go
reimplementation) is the standard choice — heavier to operate (rule tuning,
false-positive triage) so only worth it if this server handles
untrusted/public input at meaningful volume; for an internal-network admin
dashboard + mobile-app backend, §2.1–2.3 cover the realistic threat model
more cheaply.

---

## 3. If the real goal is public-internet access (not today, but noted for later)

Nothing above makes the server internet-reachable — it's still LAN-only,
which matches "access to our server in our internal network." **If** a
future need arises for a phone on cellular data (not the home WiFi) to reach
this server, the two realistic options are:

- **Port-forward on the home router** (classic approach, what the pasted
  "port 5645" draft implicitly assumes) — requires a real domain or DDNS,
  a real CA cert (Caddy/certbot instead of the self-signed script), and
  directly exposes the home IP to the entire internet on that port. This is
  the highest-maintenance, highest-exposure option.
- **Reverse tunnel — Cloudflare Tunnel (`cloudflared`) or Tailscale Funnel**
  (recommended over port-forwarding if this need ever arises): the LAN
  server makes an OUTBOUND-only connection to the tunnel provider, so the
  home router needs **zero** open inbound ports at all — eliminates
  internet-wide port-scanning exposure entirely. Cloudflare Tunnel
  additionally sits behind Cloudflare's own DDoS protection/WAF for free.
  This is materially safer than port-forwarding for a home-LAN deployment
  and is the standard modern replacement for "open a port on the router."

Not recommending either today since the stated goal is to stay internal —
noting this only so the eventual "go public" decision isn't re-litigated
from scratch later.

---

## 4. Summary

| | Pasted "port 5645" proposal | Recommended |
|---|---|---|
| New service? | Yes — a second TLS-terminating proxy | No — extend the existing `proxy` (nginx) |
| Adds real protection? | No — duplicates existing TLS termination | Yes — rate limiting, fail2ban, optional internal mTLS, WAF-lite rules |
| Attack surface | Increases (2 TLS endpoints) | Unchanged (still 1 front door) |
| Public access | Implicitly assumes it (arbitrary port + domain prereqs) | Explicitly out of scope — stays LAN-only, with Cloudflare Tunnel noted as the safer path if that changes |

**Next step**: infra team picks which of §2.1–2.4 to implement (2.1 rate
limiting + 2.2 fail2ban are the highest-value, lowest-effort pair); this
document does not implement any of them.
