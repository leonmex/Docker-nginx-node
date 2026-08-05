# Pentest Report — `/api/admin/payment-fraud-reviews`

**Date:** 2026-08-01
**Target:** `https://192.168.178.43/api/admin/payment-fraud-reviews`
**Posture tested:** unauthenticated outsider on the same LAN, no cookies/credentials, no source-code shortcuts — pure black-box HTTP requests.

## Result: could not retrieve the data. The endpoint held.

| Attack attempted | Result |
|---|---|
| No auth at all | `401 Please login first!` — no data |
| 11 forged/guessed session cookies (`session=admin`, `session=1`, `isAdmin=true`, `role=admin`, `connect.sid=…`, etc.) | All `401` |
| `Authorization: Bearer`/`Basic` guesses | All `401` (app doesn't even honor this header — cookie-only auth) |
| Trust-boundary headers (`X-Forwarded-For`, `X-Real-IP`, `X-Original-URL`, `X-Rewrite-URL`, `X-Admin: true`, etc.) | All `401` — nothing is trusted from client headers |
| Path-normalization tricks (`//`, `/./`, encoded chars, trailing slash/`;`) | `404`/`401` — Fastify's strict router rejects the mangled paths before auth even runs |
| Uppercase path (`/API/ADMIN/...`) | `200` but only the SPA's `index.html` shell — confirmed benign by hitting a random nonexistent path, which returns the identical fallback page. No fraud-review data in it. |
| HTTP verb tampering (POST/PUT/DELETE/PATCH/method-override headers) | `404` — route isn't registered for other verbs, no confusion-based bypass |
| `TRACE` | `405`, blocked by nginx |
| Alternate ports (8080, 5000, 4000) | Not listening |
| Port 3000 | Reachable, but proxies to the same app → same `401` gate |
| SQLi/XSS-style payloads in `page`, `flaggedAtFrom`, etc. | Clean `401`, no stack trace, no anomaly — auth is checked *before* any query parsing, so this endpoint gave no injection surface to an unauthenticated caller |

## Finding — CORS reflects arbitrary origins with credentials enabled

Sent `Origin: https://malicious-origin.evil.com` and the server echoed it straight back:

```
access-control-allow-origin: https://malicious-origin.evil.com
access-control-allow-credentials: true
```

This is a misconfiguration — a correct CORS policy should allow-list the real frontend origin(s), not reflect whatever `Origin` the client sends.

**Why it didn't lead to exploitation today:** the app's session cookie is `SameSite=Lax`, so a cross-site `fetch()` from an attacker's page would not carry the victim's cookie regardless of the CORS response — that's what's actually protecting this data, not the CORS policy itself.

**Why it still matters:** if that cookie attribute ever changes, or another cookie without `SameSite` protection is introduced later, this becomes directly exploitable — an attacker's website could silently read admin data through a logged-in admin's browser.

**Recommendation:** replace the reflected `Origin` with an explicit allow-list of known frontend origins in the CORS config, as defense-in-depth independent of the cookie's `SameSite` setting.

## Bottom line

Every direct attack against the endpoint itself failed — the session-cookie + DB-backed privilege check (`PAYMENT_FRAUD_REVIEW`) held, and nginx had no gaps in front of it. The only actionable finding is the CORS `Origin` reflection described above.
