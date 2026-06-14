# Converting Moolah away from SwiftUI — research & recommendation

**Status:** Research / decision support. No code changes proposed yet.
**Date:** 2026-06-14
**Question:** What would it take to move the app off SwiftUI, and what are the
pros and cons? The goal is the most *Mac-assed* (idiomatically native, Finder-
/ Mail-quality) and highest-quality UI possible.

---

## TL;DR

- **A full rewrite to pure AppKit is not recommended.** It would discard ~41k
  LOC of working UI, throw away the universal iOS/macOS strategy, multiply the
  test-rewrite cost, and — critically — it is *not* what the best Mac apps do
  in 2026. The state of the art is **hybrid: SwiftUI for structure and the
  90% of UI it does well, AppKit reached into precisely where SwiftUI can't
  deliver native fidelity.**
- **Moolah is already on that hybrid path and ahead of most apps.** The
  sidebar is already a full `NSOutlineView` (1,700 LOC of AppKit), the split
  views are `NSSplitView`, window access goes through `NSViewRepresentable`,
  and there is a dedicated `FOCUS_GUIDE.md` documenting SwiftUI's macOS focus
  fragility. The team has *already paid the "leave SwiftUI" tax at exactly the
  points where it matters.*
- **The highest-leverage move is to formalise and extend the hybrid strategy**,
  not to rip SwiftUI out. Pick the next few highest-pain surfaces (transaction
  table, toolbars, text editing/undo, menus) and selectively drop to AppKit
  with the same `NSViewRepresentable` discipline already in use — while keeping
  the thin-view / store / repository architecture that makes the UI layer
  swappable in the first place.

The architecture the team chose (thin views, all logic in `@Observable`
stores, stores talk only to repository protocols) is the single most important
asset here: **it means "the UI framework" is a thin, replaceable shell over a
large, framework-agnostic core.** That is what makes *selective* replacement
cheap and a *total* rewrite unnecessary.

---

## 1. What "convert away from SwiftUI" can actually mean

Apple ships three app models on the Mac. Only one of these is a genuine "away
from SwiftUI" option, and it is the most expensive:

| Model | What it is | Fit for "Mac-assed, highest quality" |
|---|---|---|
| **Pure AppKit** | `NSWindow` / `NSViewController` / `NSTableView` / `NSOutlineView`, no SwiftUI | The historical gold standard for native feel — but a *total UI rewrite* and abandons the shared-iOS strategy |
| **Mac Catalyst** | Run the iOS (UIKit) UI on macOS | **Wrong direction.** Catalyst apps are the *least* Mac-assed of the three; this is for shipping an iPad app on the Mac, not for raising native quality |
| **Hybrid SwiftUI + AppKit** | SwiftUI shell, AppKit via `NSViewRepresentable` / `NSViewControllerRepresentable` where needed | **What shipping high-quality Mac apps do in 2026, and what Moolah already does** |

Catalyst can be dismissed immediately for this goal — it sacrifices native
fidelity, which is the opposite of the stated aim. The real choice is between
**(A) a full AppKit rewrite** and **(C) doubling down on the hybrid**. ("B" is
Catalyst, kept in the table only to rule it out explicitly.)

---

## 2. Where the codebase stands today

Measured on `claude/swiftui-migration-research-krh20u` (2026-06-14):

| Layer | Files | ~LOC | Touched by a UI-framework change? |
|---|---:|---:|---|
| `App/` (scenes, sessions, lifecycle) | 36 | 5,705 | Partly — scene/window setup is SwiftUI |
| `Features/` (the SwiftUI UI) | 260 | 35,633 | **Yes — this is the UI layer** |
| `Shared/` (utilities, some views) | 175 | 20,011 | Mostly no (utilities); a few views |
| `Domain/` (models, repo protocols) | 159 | 11,556 | **No — framework-agnostic** |
| `Backends/` (GRDB + CloudKit sync) | 231 | 28,847 | **No** |
| `MoolahTests/` (unit/contract/store) | 768 | 109,337 | **Mostly no** (store/contract tests run headless) |
| `MoolahUITests_macOS/` (XCUITest) | 49 | 4,824 | **Yes — driven through the UI** |
| Other (benchmarks, automation, support) | — | ~9k | Mixed |
| **Total** | 1,823 | **227,363** | |

**The UI blast radius of any framework change is roughly `App` + `Features` ≈
41k LOC**, plus knock-on rework of the ~4.8k LOC of macOS UI tests. The other
~150k+ LOC — domain, backends, sync, and the vast headless test suite — is
*deliberately insulated* from the UI framework by the architecture in
`plans/completed/NATIVE_APP_PLAN.md` and CLAUDE.md's "Thin Views, Testable
Stores" rule.

### How SwiftUI-heavy the UI is

- 205 files `import SwiftUI`; the app uses the *modern* stack (`@Observable`
  ×49, `@Environment` ×136, `NavigationSplitView`/`NavigationStack`,
  `Table`, `.inspector`, `@FocusState` ×29) — not legacy `ObservableObject`.
- It is genuinely cross-platform: ~194 `#if os(...)` sites already fork
  macOS/iOS behaviour, and there is a live `MoolahTests_iOS` target and
  `build-ios` flow. **This is a universal binary, not a Mac app that happens
  to compile on iOS.**

### AppKit is already woven in — at exactly the right places

18 non-test files already `import AppKit`. These are not accidents; each is a
documented escape hatch where SwiftUI couldn't deliver native quality:

- **Sidebar — full `NSOutlineView` (`Features/Navigation/AppKitSidebar/`,
  ~1,700 LOC across 16 files).** Built specifically because SwiftUI `List`
  cannot do Mail.app-style drag-and-drop (reorder-between vs drop-onto are
  mutually exclusive in SwiftUI `List` on macOS 26 — confirmed by Apple DTS;
  see `plans/completed/2026-05-27-sidebar-nsoutlineview-rewrite-design.md`).
- **`ResizableVSplit` → `NSSplitView`** because SwiftUI `VSplitView` has no
  binding for the divider position and won't persist it.
- **`WindowAccessor` → `NSViewRepresentable`** to reach `NSWindow` at all.
- **`SidebarOutline`** and **pasteboard / drag helpers** for native DnD.
- An entire **`guides/FOCUS_GUIDE.md`** exists because SwiftUI focus on macOS
  is a "declarative reflection of the AppKit responder chain" that breaks in
  predictable ways (plain `Button` won't activate on Space; `.defaultFocus`
  no-ops when the container isn't key; sibling focusables steal the seed).

**Read the right way, this is the answer to the user's question already being
lived out:** the team has been *incrementally migrating away from SwiftUI*
surface-by-surface, AppKit-wrapping each spot where SwiftUI's native fidelity
runs out — and the app builds, ships, and keeps a single iOS/macOS codebase.

---

## 3. The pros & cons, by option

### Option A — Full rewrite to pure AppKit

**Pros**
- Ceiling on native fidelity is the highest available. `NSTableView` /
  `NSOutlineView` give cell reuse, column customisation, precise selection
  emphasis, mature drag-and-drop, and decades-correct text editing/undo for
  free — the exact things SwiftUI fumbles.
- No fighting SwiftUI's layout/focus/toolbar opacity; full control of the
  responder chain, menus, and window behaviour.
- Performance headroom for very large transaction lists (cell reuse vs
  SwiftUI's diffing).

**Cons**
- **Throws away ~41k LOC of working, tested UI** to rebuild the same features.
  Realistically a multi-month effort for a solo/small team, during which
  feature work largely stops.
- **Kills the universal-binary strategy.** AppKit is macOS-only. You would
  either abandon iOS or maintain *two* separate UI codebases (AppKit on Mac,
  SwiftUI/UIKit on iOS) — doubling UI maintenance forever. Given ~194 existing
  `#if os` forks and a live iOS target, this is a strategic reversal, not a
  refactor.
- **UI-test rework + churn.** The 4.8k LOC of `MoolahUITests_macOS` and their
  screen drivers assume the current accessibility tree; large parts would need
  rewriting against AppKit views.
- AppKit is more verbose and slower to iterate; the brand-new UI guides
  (`UI_GUIDE`, `FOCUS_GUIDE`) are written in SwiftUI terms and would need
  rewriting.
- **It's not even what the best apps do.** The 2026 consensus (below) is
  *hybrid*, not pure AppKit. A full rewrite over-corrects.

### Option C — Double down on the hybrid (recommended)

**Pros**
- **Keeps everything that works; pays cost only where it buys native quality.**
  Each surface migrated to AppKit is a contained `NSViewRepresentable`, exactly
  like the sidebar already is.
- **Preserves the universal binary.** SwiftUI stays the shared shell; AppKit
  drop-downs are `#if os(macOS)` and don't touch iOS.
- **Lowest risk, incremental, shippable per surface.** No big-bang; no feature
  freeze. The sidebar rewrite already proved the playbook (spike → skeleton →
  drag → rename → menus/keyboard/a11y → UI-test refit, each its own PR).
- **Matches the architecture.** Thin views over stores over repositories means
  swapping a view's rendering layer never touches business logic or tests.
- It is the documented industry-standard approach for 2026 (see §4).

**Cons**
- The SwiftUI/AppKit boundary has real friction: re-render cost on selection
  when hosting SwiftUI cells in AppKit, responder-chain seams (e.g. Option+F6
  divider focus doesn't cross the `NSSplitView` wrap — noted in
  `ResizableVSplit`), and two mental models in one codebase.
- You never reach *pure*-AppKit ceiling on the surfaces left in SwiftUI; you're
  accepting "very good" on those rather than "perfect."
- Requires fluency in *both* frameworks (already true here).
- Dependency/`NSViewRepresentable` plumbing accrues; each bridge is bespoke
  code to maintain (the sidebar is 1,700 LOC).

---

## 4. What the 2026 landscape says

The user's own phrasing — "Mac-assed app" — is a live 2026 debate, and the
expert consensus lands squarely on hybrid:

- **Paulo Andrade, *Using SwiftUI to Build a Mac-assed App in 2026*:** "SwiftUI
  is productive, modern, and often delightful, right up until you try to make a
  *really good* Mac app. Then suddenly you're fighting the framework for things
  the Mac solved 20 years ago." His concrete gaps — context-menu/selection
  emphasis you can't observe, drag-session info unavailable to the *source*,
  keyboard nav (`.onMoveCommand` macOS-only, TextFields hijacking keys),
  unpredictable semantic toolbar placement — and his practice is to **mix in
  AppKit strategically**, which is what Moolah already does.
- **John Gruber, *SwiftUI Only Makes It Easy to Develop Bad Apps* (Jun 2026):**
  argues SwiftUI makes mediocre apps easy and great ones hard, citing a Journal
  undo bug "solved since 1989" in AppKit. Implicitly favours AppKit for
  correctness-critical surfaces (text editing/undo) — an argument for *targeted*
  AppKit, not a wholesale framework, since most of an app isn't a text editor.
- General guidance (TrozWare, DigitalBlake, Michael Tsai): **SwiftUI unless you
  need lists of thousands / cell reuse / pixel-precise selection**, where
  `NSTableView`/`NSOutlineView` still win. SwiftUI's `List` is itself backed by
  `NSTableView`, so the gap is controllability, not raw capability.

The throughline: **build in SwiftUI, reach into AppKit where the framework
doesn't cover what a native Mac app needs.** Moolah is already doing this; the
question is really *how aggressively to extend it*, not *whether to leave*.

---

## 5. If we extend the hybrid — the highest-value next targets

Ranked by native-quality payoff per unit of effort, drawing on the gaps the
team and the literature have flagged:

1. **The transaction table / large lists → `NSTableView`.** This is the app's
   core surface and the place SwiftUI's lack of cell reuse and selection
   emphasis hurts most for "high information density" (a stated UI-guide goal).
   Highest payoff. Mirror the sidebar's `NSViewControllerRepresentable`
   pattern.
2. **Text editing & undo correctness** wherever free-form text + undo matters
   (notes, descriptions). AppKit's `NSTextView` gives correct, decades-tested
   undo — the Gruber/Journal failure mode.
3. **Toolbars & menus** where SwiftUI's semantic placement is unpredictable —
   drop to `NSToolbar` / `NSMenu` for precise, idiomatic layout.
4. **Focus / responder-chain seams** — continue hardening per `FOCUS_GUIDE`;
   some flows may be cleaner as AppKit controllers than as `@FocusState`
   choreography.

Each is independently shippable, `#if os(macOS)`-scoped, and leaves iOS and the
domain/store/test layers untouched — exactly like the sidebar migration.

---

## 6. Recommendation

**Do not convert away from SwiftUI. Formalise and accelerate the hybrid you
already have.**

1. **Keep SwiftUI as the app shell and for the surfaces it does well** (forms,
   settings, detail panes, navigation structure, iOS entirely).
2. **Treat AppKit as a first-class, sanctioned tool** for the handful of
   surfaces where native fidelity demands it — codify a short "when to drop to
   AppKit" section in `UI_GUIDE.md` so it's a deliberate decision, not an
   emergency.
3. **Migrate the transaction table to `NSTableView` next** as the highest-value
   surface, using the proven sidebar playbook (spike → skeleton → behaviour →
   a11y → UI-test refit, one PR each).
4. **Protect the architecture that makes all of this cheap:** thin views,
   logic in stores, stores → repository protocols. As long as that holds, the
   UI framework is a replaceable shell and you never face a forced all-or-
   nothing rewrite.

The reason *not* to go pure-AppKit isn't that AppKit is worse — for a few
surfaces it's clearly better, which is why it's already in the tree. It's that
a *total* switch would discard a large, working, tested, cross-platform UI to
chase a ceiling you can reach surface-by-surface at a fraction of the cost and
risk — while the 2026 best practice for exactly this "Mac-assed, highest
quality" goal *is* the hybrid.

---

## Appendix — evidence index (in-repo)

- Architecture / swappable-UI rationale: `plans/completed/NATIVE_APP_PLAN.md`,
  CLAUDE.md §"Thin Views, Testable Stores".
- SwiftUI `List` DnD ceiling + the AppKit decision:
  `plans/completed/2026-05-27-sidebar-nsoutlineview-rewrite-design.md`,
  `…-sidebar-unified-appkit-plan.md`, and the `Features/Navigation/AppKitSidebar/`
  implementation (~1,700 LOC).
- SwiftUI focus fragility on macOS: `guides/FOCUS_GUIDE.md`.
- AppKit escape hatches already shipped: `App/WindowAccessor.swift`,
  `Shared/Views/ResizableVSplit.swift`, `Features/Navigation/AppKitSidebar/*`,
  drag/pasteboard helpers under `Features/Navigation/`.
- Cross-platform reality: ~194 `#if os(...)` sites in `App`+`Features`+`Shared`;
  `MoolahTests_iOS` / `build-ios` in `project.yml` / `justfile`.

## Appendix — external sources

- [Using SwiftUI to Build a Mac-assed App in 2026 — Paulo Andrade](https://pfandrade.me/blog/mac-assed-swiftui-app/)
- [Using SwiftUI to Build a Mac-assed App in 2026 — Ankur Sethi](https://ankursethi.com/links/using-swiftui-to-build-a-mac-assed-app-in-2026/)
- [SwiftUI Only Makes It Easy to Develop Bad Apps — Daring Fireball (Jun 2026)](https://daringfireball.net/2026/06/swiftui_only_makes_it_easy_to_develop_bad_apps)
- [Native macOS, SwiftUI, and Mac Catalyst: The 3 Apple App Models — Doran Gao](https://medium.com/@dorangao/native-macos-swiftui-and-mac-catalyst-the-3-apple-app-models-every-developer-should-understand-017e1fbff4eb)
- [SwiftUI vs AppKit on macOS: Layout, Performance, Trade-offs — DigitalBlake](https://digitalblake.com/2026/04/28/swiftui-vs-appkit-macos-ui-performance/)
- [SwiftUI for Mac 2025 — TrozWare](https://troz.net/post/2025/swiftui-mac-2025/)
- [NSTableView With SwiftUI — Michael Tsai](https://mjtsai.com/blog/2024/04/15/nstableview-with-swiftui/)
- [The State of Mac Catalyst in 2026 — Apple Developer Forums](https://developer.apple.com/forums/thread/811728)
- [Apple DTS: `.onMove` drag-and-drop `List` limitation — Forums 763013](https://developer.apple.com/forums/thread/763013)
