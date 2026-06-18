Security Audit Report — node-nginx-clean / Ant Design Pro dashboard
Audited per CLAUDE-SECURITY.md against the actual code. Severity is 1 (trivial) → 10 (critical), weighted by real exploitability in this project (not just the raw advisory rating).

Summary table
#	Finding	Area	Severity
1	immer prototype pollution — npm critical (via dva-immer)	Dependencies	7
2	Chatbot sends user prompts to external api.x.ant.design	Exfiltration	6
3	Node inspector port 9229 published to 0.0.0.0	Docker	6
4	57 npm vulns (12 high) — esbuild/vite/babel/ws	Dependencies	6
5	Google Analytics hardcoded to a non-owned tracking ID	Telemetry	5
6	nginx exposes /mcp /stdio /sse /config on port 6277	Docker/Infra	5
7	Containers run as root	Docker	5
8	Hardcoded weak DB credentials in .env	Secrets	4
9	test proxy → third-party Cloudflare Worker	Exfiltration	4
10	Lockfile drift (package-lock.json out of sync)	Supply chain	4
11	Unpinned base images (nginx:latest, postgres:latest)	Supply chain	4
12	Client-only access control (access.ts)	App logic	3
13	simple.js irreversible, no git guardrail	Scripts	2
14	DOM XSS surface in Yuan.tsx (innerHTML)	Frontend XSS	2
Details
1. immer prototype pollution — 7/10 (npm: critical)
npm audit reports 1 critical: immer 7.0.0–9.0.5 prototype pollution (GHSA-c36v-fmgq-m8hx), pulled in via dva-immer. Prototype pollution can escalate to XSS or logic bypass. Fix available via npm audit fix. Exploitability here depends on whether dva-immer reaches the runtime bundle — verify, then patch.

2. Chatbot prompt exfiltration — 6/10
dashboard/src/pages/chatbot/service.ts:6 defaults CHAT_API_URL to https://api.x.ant.design/api/big_model_glm-4.5-flash. Every chatbot prompt is sent to Ant Design's public demo endpoint. With real/sensitive input this is a data leak to a third party. It honors process.env.CHAT_API_URL — point it at your own LLM or disable the page in production.

3. Node inspector port 9229 published — 6/10
docker-compose.yml:18 maps 9229:9229 on all interfaces. The Node inspector protocol grants arbitrary code execution to anyone who can attach. Even if not currently listening, publishing it is unnecessary attack surface. Remove the mapping (or bind to 127.0.0.1 only) — it's the dev debugger port and shouldn't be world-reachable.

4. 57 npm vulnerabilities (12 high) — 6/10
{low:10, moderate:34, high:12, critical:1}. Most high/moderate are build-time tooling (esbuild, vite, @babel/*, @umijs/*, ws) that don't ship to the browser, which lowers production risk — but they affect your build/dev host. Several are auto-fixable (npm audit fix), several have no fix (@babel/core, esbuild via umi). Triage: patch what's fixable; for the no-fix umi-chain items, track upstream.

5. Hardcoded Google Analytics — 5/10
dashboard/config/config.ts:182 sets ga_v2: 'G-59NF1VHHPF'. This ships in production builds and exfiltrates page views/routes/browser data to Google — under a tracking ID you don't own (Ant Design's template default), so you're also feeding their analytics. Remove or replace the analytics block.

6. nginx MCP/SSE proxy on 6277 — 5/10
nginx/default.conf:61-89 proxies /config, /health, /sse, /message, /mcp, /stdio to webapp:6277/6274, and docker-compose.yml:35 publishes 6277. This is leftover MCP-inspector wiring from the template; nothing in the dashboard listens there. If any MCP/agent daemon were ever started in that container, this would expose file/command access to the network. Remove the port mapping and these location blocks — unused.

7. Containers run as root — 5/10
Dockerfile has no USER directive — webapp (dev) runs as root. A container escape or RCE then has root in-container. Add USER node for the dev stage. (The prod nginx master runs as root but spawns workers as nginx — still, consider an unprivileged nginx image.)

8. Hardcoded weak DB credentials — 4/10
.env contains POSTGRES_PASSWORD=postgrestest and a DATABASE_URL with the same. Good: .env is git-ignored (.gitignore:58) and docker-ignored (.dockerignore) — not committed and not baked into images. The risk is the weak default password reaching prod. Use a secrets manager / strong generated password for real deployments.

9. test-env proxy to third party — 4/10
dashboard/config/proxy.ts:31 proxies /api/** to https://pro-api.ant-design-demo.workers.dev under UMI_ENV=test. Only active in the test env (dev/prod unaffected), so conditional — but any real API traffic run under test goes to a third-party Worker. Repoint or remove.

10. Lockfile drift — 4/10
package-lock.json is out of sync with package.json (confirmed earlier: npm ci fails, @utoo/pack missing, dozens of Invalid:/Missing: entries). Consequences: non-reproducible builds, npm ci unusable, and audit results may not match what actually installs. Regenerate the lockfile (npm install, commit) so builds are deterministic and auditable.

11. Unpinned base images — 4/10
docker-compose.yml uses nginx:latest and postgres:latest; prod uses nginx:alpine — all mutable tags that drift. Node is pinned (22 + alpine 3.20). Pin nginx/postgres to specific minor/patch digests for reproducibility and controlled patching.

12. Client-only access control — 3/10
dashboard/src/access.ts gates canAdmin purely on currentUser.access === 'admin' in the browser. This is cosmetic — it hides UI but enforces nothing. Standard for the template, but ensure every privileged action is enforced server-side; never treat frontend access as a security boundary.

13. simple.js irreversible, no guardrail — 2/10
dashboard/scripts/simple.js does fs.rmSync(recursive), unlinkSync, even self-deletes (:148) and removes the scripts dir. No dirty-git check before destroying files. Operational footgun, not attacker-facing (no external input). Add an uncommitted-changes guard. i18n-remove.js is similar but uses safe path joins and bounded regexes — no ReDoS/traversal concern found.

14. DOM XSS surface in Yuan.tsx — 2/10
dashboard/src/pages/dashboard/analysis/utils/Yuan.tsx:10 assigns spanRef.current.innerHTML = yuan(children). children is typed string | number and yuan() formats currency, so practical risk is low — but it's a raw innerHTML sink. If children ever carries user data, it's injectable. Prefer textContent. (This is the only innerHTML/dangerouslySetInnerHTML sink in src/.)

Quick wins (highest impact / lowest effort)
npm audit fix → clears the critical immer + several highs.
Drop 9229:9229 and the 6277 block from compose/nginx → removes two RCE-adjacent surfaces.
Remove/replace the analytics block and repoint the chatbot endpoint → stops default exfiltration.
Regenerate package-lock.json → restores reproducible, auditable builds.
Want me to save this as a SECURITY-REPORT.md in the repo, and/or apply the quick wins (items 1–4 above) as actual changes?