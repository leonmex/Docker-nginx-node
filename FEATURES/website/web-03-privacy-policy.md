# web-03 — Privacy Policy page (`/legal/privacy-policy`)

## Why

Google Play's automated store review inspects the Privacy Policy URL
submitted in Play Console and rejects or suspends listings where that URL
is a direct `.pdf` or covers cookies only. Until this change, the only
legal document on `www.blablarags.com` was `/legal/cookies-policy-{lang}.pdf`
(a converted PDF, cookies-scoped) — not a submittable Privacy Policy URL.
There was no source Privacy Policy document (docx or PDF) anywhere in this
repo or its git history to convert 1:1, unlike the Cookies Policy — content
here was drafted directly, grounded in this codebase's actual data flows
rather than boilerplate, since inaccurate claims in a privacy policy are a
real legal liability, not just a copy problem.

## What changed

- `src/i18n/ui.ts` — new `privacyPolicy` dictionary (en/es/de), structured
  as `intro` paragraphs + a `sections[]` array (`heading`/`intro`/`bullets`/
  `closing`), following the file's existing per-feature nested-dictionary
  convention (mirrors `deleteAccount`/`notFound`).
- `src/components/PrivacyPolicyPage.astro` — new page component, same
  header/card/footer shell as `DeleteAccountPage.astro` (logo, wordmark,
  back-home link, `BlablaRagsAndRigs` copyright line), rendering the
  dictionary's sections as plain `<h2>`/`<p>`/`<ul>` — no `set:html`
  anywhere in this feature.
- `src/pages/{,es/,de/}legal/privacy-policy.astro` — three thin locale
  delegates, matching the `index.astro`/`delete-account.astro` pattern.
  Picked up by the existing `@astrojs/sitemap` integration automatically —
  no config change needed.
- `src/components/NotFoundPage.astro` — the footer's "Legal → Privacy
  Policy" link, which routed to the homepage (there was nowhere else for
  it to go, per that file's own header comment), now points at the real
  page. Terms/Sustainability links are untouched — those destinations
  still don't exist, so per the same file's established rule they keep
  routing home rather than to a fabricated URL.

## Content basis (what's real vs. drafted)

Grounded in confirmed facts about this codebase, not generic boilerplate:

- Account/profile/listing/order/returns data categories match the
  server's real domain model (users, apparel listings with camera- or
  gallery-sourced photos, cart/orders, credit-notes/return-requests).
- Camera + photo-gallery collection matches the Flutter app's capture flow
  (including the gallery-import path added this session).
- Push-notification tokens and the optional, revocable framing of location
  permission match the Android manifest audit done earlier this session.
- Waitlist and account-deletion request handling (email + optional reason,
  stored in Cloudflare KV, no email-sending capability) is described
  exactly per `src/pages/api/waitlist.ts` and
  `src/pages/api/delete-account-request.ts` — read directly, not assumed.
- Analytics section matches the real GA4 property + Consent Mode v2 setup
  in `Base.astro`/`CookieConsent.astro`.
- Deliberately generic/unconfirmed: the specific payment processor(s) is
  never named (not verified from this codebase), and no physical company
  address or DPO contact is included — only `privacy@blablarags.com`.
  Both are flagged as open items below rather than fabricated.

## i18n coverage

Full en/es/de translations, matching the site's established informal
register (`tú`/`du`) used throughout the rest of `ui.ts`, not a
formal-register legal tone that would clash with the brand voice
elsewhere on the site.

## Security / injection review

- Fully static, prerendered — no per-request server templating, no
  request-derived values echoed anywhere on this page.
- Zero `set:html` usage in any new/changed file (grepped to confirm).
- No new form, input, or data-collection surface — this page only reads
  from the static `ui.ts` dictionary.

## Open items before this goes live

- **Not legal advice / needs counsel review** — drafted directly from this
  codebase's real data flows, but should be reviewed by
  blablaragsandrigs GmbH's legal counsel before being submitted as the
  Play Console Privacy Policy URL.
- **Contact email**: `privacy@blablarags.com` needs to exist as a real,
  monitored inbox.
- **Payment processor name**: currently described generically as "our
  payment service provider(s)" — should be named once confirmed.
- **Company registration details** (registered address, register
  court/HRB number): intentionally omitted here rather than fabricated;
  typically lives in a separate Impressum/legal-notice page under German
  TMG/DDG requirements, which doesn't exist yet in this repo.
