# moolah.rocks Website Migration — Plan

> Replace the legacy moolah-web Vue SPA at moolah.rocks with a static
> single-page brand site for moolah-native, hosted on GitHub Pages, served
> from the existing `moolah.rocks` domain. Single call to action: register
> interest by email.

## Goals

1. Ship a static, brand-compliant moolah.rocks site that introduces
   moolah-native (currently in private beta, not on the App Store).
2. Drive a single action: **get in touch by email to register interest.**
3. Move hosting off the legacy server onto GitHub Pages, served from the
   `moolah.rocks` apex domain over HTTPS.
4. Decommission the old moolah-web SPA and its deploy pipeline.

## Non-Goals

- App Store / public-availability messaging (the app is beta-only for now).
- Any sign-in, account, or web-app functionality (the old SPA's reason for
  existing — explicitly dropped).
- **No download links** — no Mac GitHub-release link, no TestFlight link.
  Access is handled off-site after someone registers interest by email.
- A build framework / SSG. Plain HTML + one CSS file + static assets.
- Carrying over any of the old SPA's app code (Vue, Vuetify, Pinia,
  router, API client) — only the logged-out marketing view is reused.
- Blog, docs portal, or changelog site.

## Key Findings (researched 2026-05-16, legacy repo cloned & read)

The legacy site is the Vue SPA in **`ajsutton/moolah`**. Its logged-out
landing view — exactly what a visitor to moolah.rocks sees today — is a
single component, **`src/components/welcome/Welcome.vue`**, which is:

- **Already brand-compliant**: Poppins, Brand Space/Void backgrounds,
  Income-Blue/Gold/Coral accents, the approved hero headline ("Your
  *money*, rock *solid*."), hero subhead, "We sweat the details. You
  don't.", the "locked down / wide open" pull-quote, and "Solid money.
  Chill vibes." — all straight from `guides/BRAND_GUIDE.md §11`.
- **Almost entirely static**: plain template markup + a self-contained
  `<style lang="scss">`. The SCSS uses only nesting (no variables/mixins)
  → flattens to plain CSS mechanically.
- **Coupled to sign-in in exactly two places**: `<google-sign-in-button
  theme="dark" />` appears once in the hero and once in the bottom CTA.
  These are the only elements to remove. (The SPA's `App.vue` app-bar also
  has a "Sign In" `v-btn` and a Vuetify shell — all discarded; the new site
  is a standalone HTML page with no app shell.)
- **Three `<v-icon>` (mdi)** in the feature cards (`accountBalance`,
  `chartLine`, `checkCircle`) — replace with inline SVGs (no icon-font dep).

So this is a **port, not a from-scratch build**: lift `Welcome.vue`'s
markup + styles, drop the two sign-in buttons, swap the CTA for a single
`mailto:`, inline three icons, convert SCSS→CSS. Low risk, high fidelity to
"mostly the same site, without sign-in."

Other findings:

- **Legacy hosting & deploy**: `ajsutton/moolah` builds via CircleCI
  (`yarn build`) and `deploy.sh` rsyncs `dist/` to
  `moolah@do2.symphonious.net:moolah.rocks/` then runs a remote
  `deployMoolah.sh`. `public/.htaccess` is Apache-specific (old server) and
  is **not** carried over. Decommission = stop that CircleCI deploy and
  retire the server content after DNS cutover.
- **DNS is on Cloudflare.** Nameservers `elaine`/`gabe.ns.cloudflare.com`;
  apex `A` (`104.21.14.16`, `172.67.133.192`) are Cloudflare proxy IPs to
  the old server. Cutover is a Cloudflare-dashboard change (300s TTL, fast
  rollback), no registrar involvement.
- **No MX records yet.** The single CTA is a `mailto:` to a moolah.rocks
  address; **the user sets up moolah.rocks email separately**. The site
  only needs the link — no email infra is built or blocked here. Email
  records (`MX`/`TXT`) are independent of the Pages `A`/`AAAA` records and
  coexist fine.
- **Brand assets** live in *this* repo (`Brand/`). Use `Brand/Web/`
  (favicon, apple-touch-icon, og-image, `site.webmanifest`) per
  `BRAND_GUIDE.md §7` rather than the legacy `public/static/favicon/` set
  (which predates the guide). Hero icon: `Brand/Logo/icon-only/icon.svg`
  (equivalent of the legacy `src/assets/logo-icon.svg`).
- **Repo conventions.** `CLAUDE.md` reserves `docs/` and routes plans to
  `plans/`. Site lives in `site/`. `just format-check`/CI only inspect
  `.swift`, so web files won't trip Swift tooling.

## Decisions (confirmed with user)

| Decision | Choice |
|---|---|
| Site source location | `site/` in this repo, deployed via GitHub Actions to Pages |
| Approach | Port `Welcome.vue` → static HTML/CSS (not from scratch) |
| Custom domain | Keep `moolah.rocks` (apex), GitHub Pages over HTTPS |
| Call to action | **Single CTA:** register interest via `mailto:` to a moolah.rocks address |
| Downloads | None on the site (no Mac/TestFlight links) |
| Domain email | User sets up moolah.rocks email separately; site just links `mailto:` |

## Architecture

### Repository layout

```
site/
  index.html            # ported Welcome.vue markup, single page
  styles.css            # Welcome.vue SCSS flattened to plain CSS
  CNAME                 # contains: moolah.rocks
  404.html              # brand-styled, links home
  robots.txt
  favicon.ico           # from Brand/Web/
  apple-touch-icon.png  # from Brand/Web/
  android-chrome-192x192.png
  android-chrome-512x512.png
  og-image-1200x630.png # from Brand/Web/
  site.webmanifest      # from Brand/Web/
  assets/
    icon.svg            # from Brand/Logo/icon-only/icon.svg (hero icon)
    lockup-horizontal-on-dark.png  # nav wordmark (from Brand/Logo/)
```

Brand assets are **copied** into `site/` (not symlinked) so the Pages
artifact is self-contained. Documented that `site/` assets derive from
`Brand/` and must be re-copied if source changes.

### Hosting & deploy

- **GitHub Pages via Actions** (not branch-based Pages).
- New workflow `.github/workflows/deploy-site.yml`:
  - Triggers: `push` to `main` on `site/**`, plus `workflow_dispatch`.
  - `actions/configure-pages` → `actions/upload-pages-artifact`
    (path: `site/`) → `actions/deploy-pages`.
  - `permissions: pages: write, id-token: write`; `concurrency: pages`.
  - All actions pinned to commit SHAs (matches repo convention).
- One-time repo settings: **Settings → Pages → Source: GitHub Actions**;
  custom domain `moolah.rocks`; enable **Enforce HTTPS** after the cert
  provisions.
- `site/CNAME` ⇒ `moolah.rocks` survives every deploy.

### DNS cutover (Cloudflare)

1. Replace the old-server apex records with GitHub Pages records:
   - `A @ 185.199.108.153 / .109.153 / .110.153 / .111.153` **and** the
     AAAA equivalents (`2606:50c0:8000::153` … `8003::153`).
   - Optional `CNAME www → ajsutton.github.io` + a `www` redirect.
2. **Set them to "DNS only" (grey cloud), not proxied** — GitHub Pages
   provisions its own cert; an orange-cloud proxy over an unprovisioned
   cert causes redirect/cert errors. Re-enabling proxy later needs
   Cloudflare SSL = Full (strict) + confirmed Pages cert (follow-up).
3. The user's email `MX`/`TXT` records are independent and coexist.
4. Verify **Settings → Pages** shows the domain green, tick Enforce HTTPS.
5. Keep the old server up until `https://moolah.rocks` is verified, then
   decommission. Rollback = restore old proxy IPs (300s TTL).

### Decommission legacy moolah-web

- After cutover verified: disable the CircleCI deploy in `ajsutton/moolah`
  (or stop the `master`-branch deploy step) and retire the
  `do2.symphonious.net` site content. Archiving `ajsutton/moolah` is the
  user's call (separate repo, outside this plan's scope/access).
- Pages `404.html` handles legacy SPA deep links (`/account/...`,
  `/login`, …) — they simply 404 with a brand-styled page.
- No data migration: the SPA's backend is a separate concern; the site
  itself is just the logged-out marketing view.

## Site Content (port of `Welcome.vue`, single page)

Reproduce the existing section flow exactly, minus sign-in:

1. **Hero** — `assets/icon.svg` (rounded, glow shadow as in source),
   headline "Your *money*, rock *solid*." (blue/gold accent spans), hero
   subhead, then **single primary CTA "Register your interest"** (Income
   Blue button) → `mailto:`. (Replaces the hero `google-sign-in-button`.)
2. **Beta notice** — *new*, small, honest line under the hero CTA: the app
   is in private beta, not yet on the App Store; getting in touch is the
   way in. Calm/transparent tone (`BRAND_GUIDE §2`).
3. **Features** — the three existing cards verbatim ("Every transaction,
   handled" / "The picture, crystal clear" / "Simple. Refreshingly
   simple."), section label "The serious part", title "We sweat the
   details. You don't." Three `<v-icon>` → inline SVG (blue/red/gold tiles
   preserved).
4. **Quote strip** — "The boring money stuff? *Locked down*. The rest of
   your life? *Wide open*." (verbatim).
5. **Bottom CTA** — "Solid money. Chill vibes." + "Your money, your device,
   your rules." + the same **email CTA button** (replaces the second
   `google-sign-in-button`).
6. **Footer** — *new*, minimal: wordmark, copyright, link to the GitHub
   repo. (Legacy had none — it was an SPA.)
7. **`<head>`** — meta per `BRAND_GUIDE §7`: favicon, apple-touch-icon,
   `og:title`/`og:description`/**`og:image`** (legacy omitted the image),
   Twitter card, `theme-color: #07102E`, `site.webmanifest`, viewport,
   description, Poppins via Google Fonts (as legacy `index.html` did).

Styling: flatten `Welcome.vue`'s SCSS to `styles.css` (nesting → explicit
selectors; keep gradients, `clamp()` type scale, hover lifts, responsive
`@media (max-width: 640px)`). No Vuetify, no SCSS toolchain.

Accessibility: semantic landmarks, alt text on imagery, visible focus
states, WCAG-AA contrast against Brand Space, the `mailto:` is a real
focusable screen-reader-labelled link with a plain-text fallback address.

## Task Breakdown

1. Scaffold `site/` (`index.html`, `styles.css`, `CNAME`, `robots.txt`,
   `404.html`).
2. Copy brand assets from `Brand/Web/` and `Brand/Logo/` into `site/` +
   `site/assets/`.
3. Port `Welcome.vue` template → `index.html`; flatten its SCSS →
   `styles.css`; inline the three feature SVGs.
4. Remove both sign-in buttons; wire both CTAs to the `mailto:` placeholder
   (`hello@moolah.rocks`, with `?subject=`); flag address for user to
   confirm. Add beta-notice line, footer, full `<head>` meta.
5. Add `.github/workflows/deploy-site.yml` (Actions → Pages, SHA-pinned,
   path-filtered to `site/**`). **The agent environment cannot push
   workflow files** (OAuth token lacks `workflow` scope; the GitHub App
   API returns 404 for the same reason) — the file content is supplied in
   the PR/chat and the **user must add it** via the web UI or a local
   commit with `workflow` scope.
6. Local check: open `site/index.html`; verify layout/responsive/links,
   HTML validity and contrast.
7. Commit & push to `claude/migrate-to-moolah-native-V1Ygs`; open a PR
   (`main` is protected — PR only).
8. Post-merge, one-time **user** actions (documented in the PR):
   - Settings → Pages → Source = GitHub Actions; custom domain
     `moolah.rocks`.
   - Set up moolah.rocks email; confirm the CTA mailbox; (optionally)
     update the placeholder before cutover.
   - Cloudflare DNS cutover (Pages `A`/`AAAA` grey-cloud) + email records.
   - Verify `https://moolah.rocks`; enable Enforce HTTPS.
   - Disable the `ajsutton/moolah` CircleCI deploy; retire the old server.

## Optional / Follow-ups

- `just site-assets` recipe to re-copy `Brand/` → `site/`.
- `www → moolah.rocks` redirect.
- Lighthouse/htmltest CI check on the Pages artifact.
- Re-enable Cloudflare proxy (SSL Full strict) once the Pages cert is
  confirmed, if edge caching/DDoS protection is wanted.
- Privacy policy / support page later if an App Store submission needs one.

## Risks & Open Questions

- **CTA mailbox address** — ships as a `hello@moolah.rocks` placeholder;
  user confirms the real address when setting up moolah.rocks email.
  Site can deploy before email is live (link just won't deliver yet);
  recommend confirming the address before DNS cutover.
- **Cloudflare proxy vs. Pages cert** — cutover must use grey-cloud DNS or
  HTTPS breaks (called out above).
- **Legacy repo/pipeline retirement** — disabling the `ajsutton/moolah`
  CircleCI deploy and archiving that repo is outside this repo's access;
  flagged so it isn't forgotten after cutover.
- **Workflow file must be user-added** — this environment cannot create or
  update files under `.github/workflows/` (no `workflow` token scope). The
  site and assets are pushed; `deploy-site.yml` content is provided
  verbatim for the user to commit. Until it lands, no deploy runs.
