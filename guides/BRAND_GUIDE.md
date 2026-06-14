# moolah.rocks — Brand Style Guide

> **For AI agents and collaborators.** This document defines the brand identity, voice, visual system, and asset locations for moolah.rocks. Follow it when generating copy, designs, UI, marketing materials, or any brand-facing output.

---

## 1. Brand Concept

moolah.rocks is a full-featured personal finance tracker for iPhone, iPad, and Mac.

**Core tension:** Money management is serious, structured, and locked down — so the rest of your life can be fun, open, and relaxed.

The app handles the boring stuff (budgets, categories, recurring bills) with precision, giving users the confidence to enjoy everything else. The brand reflects both sides of this equation: rock-solid reliability paired with an easygoing, human tone.

**One-liner:** *Solid money. Chill vibes.*

**Tagline:** *Your money, rock solid.*

**Hero copy:** *Money stuff should be boring. Locked down, sorted out, taken care of — so the rest of your life doesn't have to be.*

**Key pull quote:** *The boring stuff — budgets, categories, recurring bills — locked down. The rest of your life? Wide open.*

---

## 2. Brand Voice

### Personality

- **Confident but warm** — we know what we're doing, but we're not smug about it.
- **Playful on the surface, rigorous underneath** — the tone is casual; the product is serious.
- **Permission-giving** — we're here so you can stop worrying.
- **Plain-spoken** — "where your money goes" beats "expenditure allocation."

### Tone spectrum

| Context | Tone |
|---|---|
| Marketing / hero copy | Playful, cheeky, punchy |
| Feature descriptions | Clear, confident, concise |
| Onboarding / UI | Warm, encouraging, low-friction |
| Error states / alerts | Calm, helpful, no alarm |
| Legal / privacy | Direct, transparent, no jargon |

### Do

- Use short sentences. Fragments are fine.
- Contrast "serious money stuff" with "the fun part of life."
- Use "you" and "your" — speak to one person.
- Let the product name do the wordplay (moolah = money, rocks = solid / great).

### Don't

- Use corporate speak: "leverage," "optimize," "empower," "take control."
- Be preachy or guilt-trippy about spending.
- Promise automation or bank sync — the app uses manual entry.
- Exaggerate features. Say what the app actually does.
- Use "just" dismissively ("just enter your transactions").

### Example copy patterns

- **Serious → chill:** "Know exactly where you stand, so you can make the most of what you've got."
- **Feature → benefit:** "Categories, splits, notes, search — the full toolkit. Less time worrying, more time doing literally anything else."
- **Privacy → confidence:** "Your data lives on your device. No accounts, no cloud servers, no one looking over your shoulder."

---

## 3. Color System

The palette pairs a deep-navy "space" background with a blue/red income-expense dichotomy and a warm gold accent for balance and highlights.

### Primary Palette

| Token | Hex | RGB | Usage |
|---|---|---|---|
| Brand Space | `#07102E` | 7, 16, 46 | Primary dark surfaces, app backgrounds, hero sections |
| Ink Navy | `#0A2370` | 10, 35, 112 | Headings and body text on light surfaces |
| Income Blue | `#1E64EE` | 30, 100, 238 | Positive numbers, income, primary CTAs, links |
| Light Blue | `#7ABDFF` | 122, 189, 255 | Highlights on dark surfaces, hover states |
| Expense Red | `#DC223B` | 220, 34, 59 | Negative numbers, expenses, destructive actions |
| Coral Red | `#FF787F` | 255, 120, 127 | Highlights on dark surfaces, secondary accent |
| Balance Gold | `#FFD56B` | 255, 213, 107 | Balance, net figures, celebrations, sparingly |

### Neutral Palette

| Token | Hex | RGB | Usage |
|---|---|---|---|
| Deep Void | `#02050F` | 2, 5, 15 | Deepest backgrounds, page edges |
| Paper | `#F8FAFD` | 248, 250, 253 | Light surfaces, cards |
| Muted | `#AAB4C8` | 170, 180, 200 | Secondary text, borders, disabled states |
| Subtle | `#6A7388` | 106, 115, 136 | Tertiary text, captions |

### Usage ratios

- 60% — Brand Space or Paper (surfaces)
- 25% — Ink Navy or Income Blue (primary content)
- 10% — Expense Red (expenses and negative values)
- 5% — Balance Gold (highlights, celebrations, net-positive moments)

### Semantic mapping

- **Income / positive / up** → Income Blue
- **Expense / negative / down** → Expense Red
- **Balance / net / highlight** → Balance Gold
- **Primary CTA** → Income Blue background, white text
- **Secondary CTA** → transparent with white/light border

---

## 4. Typography

**Brand typeface:** Poppins (Google Fonts)

| Role | Weight | Size | Notes |
|---|---|---|---|
| Display / hero | Bold (700) or ExtraBold (800) | 48–72pt | Tight letter-spacing (-0.03em) |
| H1 | Bold (700) | 32pt | |
| H2 | SemiBold (600) | 24pt | |
| Body | Regular (400) | 16pt | Line height 1.5–1.6 |
| Caption / label | Medium (500) | 12pt | Tracking +0.01em, uppercase for section labels |
| Numerics | Bold (700) | Varies | Tabular-nums, right-aligned in tables |

**Fallback stack:** `'Poppins', 'SF Pro Display', 'Segoe UI', Roboto, sans-serif`

**Rules:**
- Section labels: uppercase, 0.15em letter-spacing, Balance Gold color.
- Never use light or thin weights for body text.
- Headlines can use color spans for emphasis (blue for "money," gold for "solid," etc.).

---

## 5. Logo & Mark

### The mark

Two faceted crystal peaks forming an "M" with a split blue/red hexagonal gem at the valley.

- **Left peak (blue):** represents income
- **Right peak (red):** represents expenses
- **Center gem (blue/red split, gold spine):** represents balance
- **Background:** Brand Space navy with subtle starfield

### Wordmark

"moolah.rocks" set in Poppins Bold, lowercase.

- "moolah" in white (dark bg) or Ink Navy (light bg)
- The dot is a small diamond gem shape
- "rocks" in Coral Red (dark bg) or Expense Red (light bg)

### Available lockups

| Lockup | Use case | Path |
|---|---|---|
| Horizontal | Default — nav bars, headers, wide placements | `Brand/Logo/horizontal-lockup/` |
| Stacked | Square placements, social avatars | `Brand/Logo/stacked-lockup/` |
| Icon only | App icons, favicons, small spaces | `Brand/Logo/icon-only/` |
| Wordmark only | When the icon is already visible nearby | `Brand/Logo/wordmark-only/` |

Each lockup is provided in four variants: transparent on dark, transparent on light, solid dark background, solid light background.

### Clearspace

Maintain clearspace equal to **1/4 of the icon height** on all sides. Never place competing elements inside this zone.

### Minimum sizes

- Icon only: 16px (system favicon)
- Horizontal lockup: 32px height
- Stacked lockup: 80px height

### Don'ts

- Don't rotate, skew, or add drop shadows
- Don't recolor the peaks or gem
- Don't swap peak positions (blue is always left, red is always right)
- Don't replace the gem with other glyphs or text
- Don't place on busy or low-contrast backgrounds

---

## 6. App Icons

The iOS and macOS app icons live in `App/Assets.xcassets/AppIcon.appiconset/` and are already wired into the Xcode project. Don't drag new copies in — edit in place when regenerating.

Contents:

- **iOS:** all required sizes (20/29/40/60/76/83.5pt at @1x/@2x/@3x) plus the 1024px App Store marketing icon and iOS 18+ appearance variants (`Icon-1024-any/dark/light/tinted.png`).
- **macOS:** 16–512 at @1x and @2x (`mac_16x16.png` … `mac_512x512@2x.png`).

iOS 18+ appearance variants:

- **Any (default):** dark crystalline peaks on navy
- **Dark:** same as Any
- **Light:** peaks on light gradient background
- **Tinted:** grayscale version for system tinting

---

## 7. Web Assets

All in `Brand/Web/`:

| File | Size | Use |
|---|---|---|
| `favicon.ico` | 16/32/48 | Browser tab icon |
| `apple-touch-icon.png` | 180px | iOS home screen bookmark |
| `android-chrome-192x192.png` | 192px | Android home screen |
| `android-chrome-512x512.png` | 512px | Android splash |
| `og-image-1200x630.png` | 1200x630 | Open Graph / Twitter card |
| `site.webmanifest` | — | PWA manifest |

### Meta tags

```html
<link rel="icon" href="/favicon.ico" sizes="any">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<meta property="og:title" content="moolah.rocks — Solid money. Chill vibes.">
<meta property="og:description" content="Personal finance for iPhone, iPad, and Mac. Lock down the money stuff so the rest of your life stays wide open. Private, powerful, yours.">
<meta property="og:image" content="/og-image-1200x630.png">
```

---

## 8. Social & Marketing Banners

All in `Brand/Social/`:

| File | Dimensions | Platform |
|---|---|---|
| `twitter-header-1500x500.png` | 1500 x 500 | X / Twitter header |
| `linkedin-banner-1584x396.png` | 1584 x 396 | LinkedIn cover |
| `facebook-cover-1640x624.png` | 1640 x 624 | Facebook page cover |
| `instagram-square-1080x1080.png` | 1080 x 1080 | Instagram post |
| `instagram-story-1080x1920.png` | 1080 x 1920 | Instagram / TikTok story |
| `website-hero-2560x1440.png` | 2560 x 1440 | Website hero (dark) |
| `website-hero-light-2560x1440.png` | 2560 x 1440 | Website hero (light) |
| `email-header-1200x300.png` | 1200 x 300 | Email campaigns |
| `product-hunt-1270x760.png` | 1270 x 760 | Product Hunt |

---

## 9. Motion & Interaction

- **Scroll reveals:** Elements fade up (translateY 28px → 0, opacity 0 → 1, 700ms ease). Trigger at 15% intersection.
- **Hover states:** Cards lift 4px with border brightening. Buttons lift 1–2px.
- **Numeric counters:** Tick up with ease motion (200–300ms).
- **Balance transitions:** Brief gold-pulse glow when crossing $0.
- **No bouncing or looping animations** on static elements like the icon.

---

## 10. Product Facts

Use these when writing about the app. Do not invent features.

| Fact | Detail |
|---|---|
| Platforms | iPhone, iPad, Mac (native) |
| Data input | Manual entry |
| Data storage | On-device, local-first |
| Sync | Optional iCloud sync (user's own iCloud, end-to-end) |
| Accounts | No sign-up required, no user accounts |
| Cloud servers | None — no third-party servers touch user data |
| Key features | Transaction tracking, custom categories, split transactions, notes, search, recurring transactions, multiple accounts, earmarks (savings goals) & budgets, investment & crypto holdings tracking, reports, charts (spending trends, income vs expenses, category breakdowns, net worth & forecast), filters, CSV import, export |
| What it's not | Not a bank, not a payment processor, no bank-sync/open-banking |

---

## 11. Key Brand Copy (approved)

These lines are approved and can be reused or adapted:

- **Tagline:** "Your money, rock solid."
- **CTA:** "Solid money. Chill vibes."
- **Hero subhead:** "Money stuff should be boring. Locked down, sorted out, taken care of — so the rest of your life doesn't have to be."
- **Pull quote:** "The boring stuff — budgets, categories, recurring bills — locked down. The rest of your life? Wide open."
- **Privacy:** "Private. Like, actually private."
- **Privacy detail:** "Your data lives on your device. No accounts, no cloud servers, no one looking over your shoulder."
- **OG description:** "Personal finance for iPhone, iPad, and Mac. Lock down the money stuff so the rest of your life stays wide open. Private, powerful, yours."
- **Feature framing:** "We sweat the details. You don't."
- **Onboarding:** "Set it up. Then go live your life."
- **At-a-glance:** "Everything you need to know, visible in seconds. Less time worrying, more time doing literally anything else."
