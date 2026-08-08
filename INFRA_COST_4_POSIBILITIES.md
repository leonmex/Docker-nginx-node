# Month 1 Launch Infra Budget — 1,500 users/day

**Status:** Estimate, for planning purposes
**Date:** 2026-08-07
**Scope:** Infrastructure cash cost only for the first month after launch, at an assumed 1,500 daily active users. Not a full business budget — see §6 for what's deliberately excluded.

## Recommendation

**~$45–60/month — a single VPS + Cloudflare R2. Not Kubernetes.**

At this traffic level the whole workload fits comfortably on one modest server. Amazon EKS and Google GKE both add **$140–235/month** of pure orchestration overhead — control plane fees, load balancers, NAT gateways — before a single extra request is served. That overhead buys elastic multi-service scaling and zero-downtime rollouts across a fleet; this launch is one Fastify API, one small Postgres database, and an image bucket. Kubernetes becomes worth it later, at meaningfully higher scale or service complexity, not on day one.

The one piece worth adopting regardless of compute choice: **Cloudflare R2** for image storage. Zero egress fees make it the correct call even inside an AWS- or GCP-hosted stack — see §4.

**Pricing source key**: 🟢 = fetched live from the provider's pricing page on 2026-08-07. 🟡 = a well-established published rate, not re-verified that day — confirm against the provider's current pricing page before committing real spend.

## 1. Real numbers from the running stack

Pulled directly from the live containers in this repo, not estimated.

| Metric | Current value | What it's used for below |
|---|---|---|
| Postgres database size | 14 MB | Confirms DB cost is negligible at this scale |
| Catalog items (`product_items`) | 349 | Denominator for per-item storage average |
| Image rows (`item_images`) | 2,428 | ~7 image records per item |
| Registered accounts (test data) | 100 | Not used for projections — seed data, not real signups |
| MinIO bucket size (`blablarags-apparel`) | 1.8 GB | — |
| MinIO object count | 8,460 files | ~5.2 MB stored per catalog item (all size variants), ~24 files/item — used in §3 |
| Redis memory in use | 1.1 MB / 256 MB cap | Confirms Redis needs no dedicated tier at this scale |

Note: the 1.8 GB currently in MinIO is test/seed data, not real launch inventory — it's used here only to derive a realistic *per-item* storage footprint (image count × size), not carried forward as a starting balance.

## 2. Assumptions for 1,500 users/day

No real traffic exists yet to measure — these are launch-month planning assumptions, stated explicitly so they can be swapped for real numbers once live.

| Assumption | Value |
|---|---|
| Sessions per user per day | 1.3 |
| API requests per session | 50 |
| Image loads per session (feed + detail views) | 30 |
| Average served image size (thumbnail-weighted) | 80 KB |
| Average API response size | 5 KB |
| Share of DAU listing a new item that day | 3% |
| Share of DAU that are new signups (launch-month push) | 6% |

## 3. Resulting month-1 workload

| Derived monthly total | Amount |
|---|---|
| Sessions | 58,500 |
| API requests | ~2.93M |
| Image requests | ~1.76M |
| Image bandwidth (egress) | ~134 GB |
| API bandwidth (egress) | ~14 GB |
| New catalog items | 1,350 |
| New image storage (at 5.2 MB/item, measured) | ~6.8 GB |
| New signups | ~2,700 |

None of this stresses Postgres or Redis — both stay in the tens-of-megabytes range all month. The entire cost story here is **compute + image egress**.

## 4. Object storage: why R2 wins outright

This app is image-heavy (~1.76M image loads/month) and egress is where object storage bills usually escalate. Cloudflare R2 charges nothing for egress at all — a direct, structural cost advantage over S3 or GCS for this exact workload shape.

Same month-1 workload (6.8 GB storage, ~4,700–33,000 write ops depending on variant count, 1.76M reads, 134 GB egress) priced on each provider:

| Provider | Storage | Requests | Egress | Total | Source |
|---|---|---|---|---|---|
| Cloudflare R2 | $0.00 | $0.00 | $0.00 | **$0.00** | 🟢 entirely within free tier (10 GB / 1M writes / 10M reads, unlimited egress) |
| AWS S3 | $0.16 | $0.72 | ~$12.06 | **~$12.94** | 🟡 standard rates; less if still inside a new account's 12-month free tier |
| Google Cloud Storage | $0.14 | $0.71 | ~$16.08 | **~$16.93** | 🟡 standard rates |

The gap widens as the catalog and traffic grow — R2's egress stays $0 at any volume, S3/GCS egress scales linearly with it. Worth using R2 *even inside an AWS- or GCP-hosted compute stack* — storage doesn't have to match compute provider.

R2 pricing detail (🟢 live): $0.015/GB-month storage, $4.50/million Class A (write) ops, $0.36/million Class B (read) ops, **zero egress**. Free tier: 10 GB storage + 1M writes + 10M reads/month.

## 5. Compute platform comparison

Full month-1 stack, each priced with R2 for storage (§4) to isolate the compute/orchestration cost difference.

| Platform | Config | Total/month |
|---|---|---|
| **Single VPS (recommended)** | DigitalOcean, 4 GB / 2 vCPU | **~$45** |
| AWS EKS | 2× t3.medium worker nodes | ~$233 |
| Google GKE | 2× e2-medium worker nodes | ~$142 |

Full line-item breakdown:

| Line item | VPS (DO) | AWS EKS | GCP GKE | Source |
|---|---|---|---|---|
| Compute / control plane | $24.00 | $73.00 | $0.00 | 🟢 EKS $0.10/hr; GKE control plane fee waived by GCP's free zonal-cluster credit |
| Worker nodes | — | $60.74 | ~$49.00 | 🟢 2× t3.medium ($0.0416/hr each); 🟡 2× e2-medium |
| Load balancer | $0.00 | ~$20.00 | ~$20.00 | 🟡 nginx on the box is "free"; ALB/GCP LB both charge a base hourly fee |
| NAT gateway | $0.00 | ~$38.00 | ~$32.00 | 🟡 needed for private worker-node subnets to reach the internet |
| Managed Postgres | $0.00 (self-hosted) | ~$20.00 | ~$20.00 | 🟡 smallest RDS/Cloud SQL tier; self-hosting is reasonable at 14 MB scale |
| Object storage (R2) | $0.00 | $0.00 | $0.00 | from §4 |
| Transactional email | $20.00 | $20.00 | $20.00 | 🟢 Resend Pro (50k/mo) — free tier's 100/day cap is too tight for ~90 signups/day + notifications |
| Domain (amortized) | $1.00 | $1.00 | $1.00 | assumes already owned; ~$12/yr amortized |
| **Total / month** | **$45.00** | **$232.74** | **$142.00** | |

### Why the gap is real, not just line-item padding

- **Control plane fees exist independent of load.** EKS charges $73/month whether it's serving 10 requests or 10 million.
- **A 2-node minimum is the actual floor for "using Kubernetes properly."** A single-node cluster gets none of the availability benefit K8s exists for — so the comparison uses 2 nodes on both clouds, not 1.
- **Networking overhead (LB + NAT) is mandatory, not optional**, once workloads sit in private subnets behind an ingress controller — which is the standard, secure default for both EKS and GKE.
- **None of this buys anything yet at 1,500 DAU.** Auto-scaling across nodes, rolling zero-downtime deploys across a fleet, and multi-service orchestration are K8s's actual value — this launch is a single API service that comfortably idles under 10% CPU on one small VPS.

## 6. What this estimate deliberately excludes

Infra only — not a full launch budget.

- Payment processor fees (Stripe/similar) — these scale with GMV, not user count, and depend on final payment-provider choice.
- SMS/push notification provider costs, if added beyond email.
- Marketing/acquisition spend to actually reach 1,500 daily users.
- Engineering/ops time — this is infra cash cost only.
- EU VAT or other tax/compliance costs, despite the site serving ES/DE locales.
- A second environment (staging) — this estimate is production-only.

## Sources

Compiled 2026-08-07 from live container metrics (Postgres/MinIO/Redis, this repo's stack) and provider pricing pages fetched the same day where marked 🟢; figures marked 🟡 are well-established published rates not re-fetched that day — verify against the provider's current pricing page before committing real spend.

- DigitalOcean Droplet pricing (🟢 live-fetched)
- AWS EC2 on-demand pricing, `t3.medium` (🟢 live-fetched)
- AWS EKS pricing (🟢 live-fetched)
- Google Compute Engine pricing, `n2-standard-2` as reference point (🟢 live-fetched); `e2-medium` used in the comparison is 🟡 estimated from general GCP pricing knowledge
- Google GKE pricing / free zonal-cluster credit (🟡 well-established GCP policy, not re-fetched live this pass)
- Cloudflare R2 pricing (🟢 live-fetched)
- Resend pricing (🟢 live-fetched)
- AWS S3, Google Cloud Storage, AWS RDS, Google Cloud SQL, AWS NAT Gateway/ALB, GCP Load Balancer/Cloud NAT rates (🟡 well-established published rates, not re-fetched live this pass)
