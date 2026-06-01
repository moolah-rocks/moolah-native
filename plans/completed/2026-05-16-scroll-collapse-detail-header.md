# Scroll-Collapse Detail Header Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On macOS, when the user scrolls the transaction list down, smoothly collapse the elements above it (chart / panels / positions table) to zero height and give that space to the list; re-expand when scrolled back to the top.

**Architecture:** A `@MainActor @Observable` decision model (`TransactionScrollCollapse`) holds the collapse state. The transaction `List`'s `onScrollGeometryChange` (empirically verified to fire on macOS `List` — 2026-05-16 spike) feeds `contentOffset.y` into the model. The model is owned by `PositionsTransactionsSplit` (macOS) and injected down to the embedded `TransactionListView` via a SwiftUI environment value (a reference object survives the `NSHostingView` representable boundary that a `PreferenceKey` would not cross). `ResizableVSplit` observes the model's `isCollapsed` and animates the `NSSplitView` divider to a collapsed top while preserving the user's autosaved divider position.

**Tech Stack:** SwiftUI, AppKit (`NSSplitView` via `NSViewRepresentable`), `@Observable`, Swift Testing, `just` targets.

**Scope:** macOS only. iOS uses a segmented picker (no split) and is unchanged. Recorded-value / legacy investment accounts (`RecordedValueInvestmentLayout`, a plain `VStack`) are explicitly **out of scope and unchanged** per the 2026-05-16 design decision. Only the `ResizableVSplit` path is touched, which covers multi-currency standard accounts, position-tracked investment accounts, and crypto wallets.

**Design decisions (confirmed 2026-05-16):**
- Trigger: collapse on scroll-down past a threshold; **re-expand only when the list returns to the top** (offset ≈ 0). No mid-list re-expansion (jitter-free).
- Divider autosave: collapse is a **transient visual override**; the user's autosaved divider position is preserved and restored on expand.
- Navigation: switching account/earmark **resets to expanded**.

---

## File Structure

- **Create** `Shared/Views/Positions/TransactionScrollCollapse.swift` — the `@Observable` decision model (pure logic + thresholds). One responsibility: turn a stream of scroll offsets into a stable `isCollapsed` bool with the agreed hysteresis.
- **Create** `MoolahTests/Shared/TransactionScrollCollapseTests.swift` — Swift Testing unit tests for the model's state machine.
- **Modify** `Shared/Views/EnvironmentValues+TransactionScrollCollapse.swift` (new file) — the `@Entry` environment value carrying an optional model. Kept separate so the environment key has one home.
- **Modify** `Features/Transactions/Views/TransactionListView.swift` — read the environment value.
- **Modify** `Features/Transactions/Views/TransactionListView+List.swift` — attach `onScrollGeometryChange`; reset on navigation.
- **Modify** `Shared/Views/Positions/PositionsTransactionsSplit.swift` — own the model (macOS), inject via environment, pass `collapsed:` to `ResizableVSplit`.
- **Modify** `Shared/Views/ResizableVSplit.swift` — accept `collapsed: Bool`; animate the divider; preserve autosave; allow full collapse past `minTopHeight`.

No other call sites change: `MultiInstrumentPositionsSplitModifier`, `InvestmentAccountView.positionTrackedLayout`, and the direct `PositionsTransactionsSplit` users get the behaviour for free because the model is injected by `PositionsTransactionsSplit` and read from the environment by `TransactionListView`.

---

### Task 1: `TransactionScrollCollapse` decision model

**Files:**
- Create: `Shared/Views/Positions/TransactionScrollCollapse.swift`
- Test: `MoolahTests/Shared/TransactionScrollCollapseTests.swift`

The model is the testable core. Rules:
- Start expanded (`isCollapsed == false`).
- `update(offsetY:)`: if currently expanded and `offsetY > collapseThreshold` → collapse. If currently collapsed and `offsetY <= expandThreshold` → expand. Otherwise unchanged (hysteresis band; no mid-list re-expansion).
- Negative offsets (overscroll rubber-band at the top, observed in the spike as `-14 → -8`) are `<= expandThreshold`, so they count as "at top" → expand/stay-expanded.
- `reset()` → expanded. Called on navigation.
- `collapseThreshold = 44` (≈ one transaction row; scrolling a single row down commits to collapse). `expandThreshold = 1` (absorbs sub-pixel/overscroll jitter at the very top).

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
@testable import Moolah

@MainActor
struct TransactionScrollCollapseTests {
  @Test func startsExpanded() {
    let model = TransactionScrollCollapse()
    #expect(model.isCollapsed == false)
  }

  @Test func collapsesAfterScrollingPastThreshold() {
    let model = TransactionScrollCollapse()
    model.update(offsetY: 10)
    #expect(model.isCollapsed == false)  // within band, still expanded
    model.update(offsetY: 60)            // > 44
    #expect(model.isCollapsed == true)
  }

  @Test func staysCollapsedWhileScrollingInTheMiddle() {
    let model = TransactionScrollCollapse()
    model.update(offsetY: 60)
    #expect(model.isCollapsed == true)
    model.update(offsetY: 30)            // above expandThreshold, below collapse
    #expect(model.isCollapsed == true)   // no mid-list re-expansion
    model.update(offsetY: 200)
    #expect(model.isCollapsed == true)
  }

  @Test func reExpandsOnlyWhenBackAtTop() {
    let model = TransactionScrollCollapse()
    model.update(offsetY: 300)
    #expect(model.isCollapsed == true)
    model.update(offsetY: 0)
    #expect(model.isCollapsed == false)
  }

  @Test func overscrollBounceCountsAsTop() {
    let model = TransactionScrollCollapse()
    model.update(offsetY: 300)
    model.update(offsetY: -8)            // rubber-band bounce at top
    #expect(model.isCollapsed == false)
  }

  @Test func resetReturnsToExpanded() {
    let model = TransactionScrollCollapse()
    model.update(offsetY: 300)
    #expect(model.isCollapsed == true)
    model.reset()
    #expect(model.isCollapsed == false)
  }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `just test-mac TransactionScrollCollapseTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: FAIL — `Cannot find 'TransactionScrollCollapse' in scope`.

- [ ] **Step 3: Write the model**

```swift
import Foundation
import Observation

/// Turns a stream of transaction-list scroll offsets into a stable
/// collapse decision for the detail header above the list.
///
/// Hysteresis (confirmed design 2026-05-16): collapse once the user
/// scrolls past `collapseThreshold`; re-expand **only** when the list
/// is back at the top (`offsetY <= expandThreshold`). No mid-list
/// re-expansion — that produced jitter in earlier explorations.
@MainActor
@Observable
final class TransactionScrollCollapse {
  private(set) var isCollapsed = false

  private let collapseThreshold: CGFloat
  private let expandThreshold: CGFloat

  init(collapseThreshold: CGFloat = 44, expandThreshold: CGFloat = 1) {
    self.collapseThreshold = collapseThreshold
    self.expandThreshold = expandThreshold
  }

  func update(offsetY: CGFloat) {
    if isCollapsed {
      if offsetY <= expandThreshold { isCollapsed = false }
    } else if offsetY > collapseThreshold {
      isCollapsed = true
    }
  }

  func reset() {
    isCollapsed = false
  }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `just test-mac TransactionScrollCollapseTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: PASS — 6 tests, 0 failures. Confirm with `grep -i 'failed\|passed' .agent-tmp/t1.txt`.

- [ ] **Step 5: Format and commit**

```bash
just format
git -C "$(git rev-parse --show-toplevel)" add Shared/Views/Positions/TransactionScrollCollapse.swift MoolahTests/Shared/TransactionScrollCollapseTests.swift
git -C "$(git rev-parse --show-toplevel)" commit -m "feat(ui): TransactionScrollCollapse decision model"
rm -f .agent-tmp/t1.txt
```

---

### Task 2: Environment value carrying the model

**Files:**
- Create: `Shared/Views/EnvironmentValues+TransactionScrollCollapse.swift`

A `PreferenceKey` would not cross the `NSHostingView` boundary inside `ResizableVSplit`; an injected reference object via the environment does. The value is **optional** so every non-split caller of `TransactionListView` (All Transactions, earmarks, scheduled, iOS) is a no-op with zero wiring changes.

- [ ] **Step 1: Write the environment value**

```swift
import SwiftUI

extension EnvironmentValues {
  /// Non-nil only when a macOS `PositionsTransactionsSplit` is hosting
  /// the transaction list and wants its header to collapse on scroll.
  /// Nil everywhere else (iOS, standalone transaction lists) — the
  /// scroll observer becomes a no-op.
  @Entry var transactionScrollCollapse: TransactionScrollCollapse?
}
```

- [ ] **Step 2: Verify it compiles**

Run: `just build-mac 2>&1 | tee .agent-tmp/t2.txt | tail -5`
Expected: `** BUILD SUCCEEDED **`. (Ignore any SourceKit "cannot find type" diagnostics — known worktree/Xcode-index mismatch per CLAUDE.md; the `just build-mac` result is authoritative.)

- [ ] **Step 3: Commit**

```bash
just format
git -C "$(git rev-parse --show-toplevel)" add Shared/Views/EnvironmentValues+TransactionScrollCollapse.swift
git -C "$(git rev-parse --show-toplevel)" commit -m "feat(ui): environment value for transaction scroll-collapse"
rm -f .agent-tmp/t2.txt
```

---

### Task 3: Feed scroll offset into the model + reset on navigation

**Files:**
- Modify: `Features/Transactions/Views/TransactionListView.swift` (add the environment read near the other `@Environment` at line 24)
- Modify: `Features/Transactions/Views/TransactionListView+List.swift` (attach observer on the `List` at lines 13-20; extend the existing `.onChange(of: baseFilter)` at lines 63-69)

Empirically verified in the 2026-05-16 spike: `.onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y } action:` fires on the macOS `List` with continuous deltas. macOS-gated because the model is only ever injected by the macOS split; the `#if os(macOS)` keeps it off the iOS code path entirely.

- [ ] **Step 1: Add the environment read in `TransactionListView.swift`**

Locate (line 24):

```swift
  @Environment(ImportStore.self) private var importStore
```

Add immediately after it:

```swift
  @Environment(\.transactionScrollCollapse) private var scrollCollapse
```

- [ ] **Step 2: Attach the scroll observer in `TransactionListView+List.swift`**

Locate (lines 13-20):

```swift
    List(selection: selectedTransactionBinding) {
      listContent
    }
    #if os(macOS)
      .listStyle(.inset)
    #else
      .listStyle(.plain)
    #endif
```

Replace with:

```swift
    List(selection: selectedTransactionBinding) {
      listContent
    }
    #if os(macOS)
      .listStyle(.inset)
      .onScrollGeometryChange(for: CGFloat.self) { geometry in
        geometry.contentOffset.y
      } action: { _, newOffset in
        scrollCollapse?.update(offsetY: newOffset)
      }
    #else
      .listStyle(.plain)
    #endif
```

- [ ] **Step 3: Reset to expanded on navigation**

Locate the existing handler (lines 63-69):

```swift
    .onChange(of: baseFilter) { _, newBase in
      // Genuine context change (e.g. user navigated from one account to
      // another): clear any stale selection and reset the user-applied
      // filter so the toolbar reflects the new context.
      selectedTransaction = nil
      activeFilter = newBase
    }
```

Replace with:

```swift
    .onChange(of: baseFilter) { _, newBase in
      // Genuine context change (e.g. user navigated from one account to
      // another): clear any stale selection and reset the user-applied
      // filter so the toolbar reflects the new context.
      selectedTransaction = nil
      activeFilter = newBase
      // A new account/earmark always opens with its header expanded;
      // it collapses again only once the user scrolls (confirmed
      // design 2026-05-16). No-op when no split is hosting us.
      scrollCollapse?.reset()
    }
```

- [ ] **Step 4: Verify it compiles**

Run: `just build-mac 2>&1 | tee .agent-tmp/t3.txt | tail -5`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Commit**

```bash
just format
git -C "$(git rev-parse --show-toplevel)" add Features/Transactions/Views/TransactionListView.swift Features/Transactions/Views/TransactionListView+List.swift
git -C "$(git rev-parse --show-toplevel)" commit -m "feat(ui): feed transaction-list scroll offset into collapse model"
rm -f .agent-tmp/t3.txt
```

---

### Task 4: `PositionsTransactionsSplit` owns and injects the model

**Files:**
- Modify: `Shared/Views/Positions/PositionsTransactionsSplit.swift` (macOS branch of `body`, lines 52-61)

The split owns one model instance per split (per detail leaf). It injects it into the **bottom** (`transactions`) content via `.environment` so the embedded `TransactionListView` reads it, and passes `collapsed:` into `ResizableVSplit`. iOS branch is unchanged.

- [ ] **Step 1: Add the owned model**

Locate (lines 31-33):

```swift
  #if !os(macOS)
    @State private var selectedTab: Tab
  #endif
```

Add immediately before it:

```swift
  #if os(macOS)
    @State private var scrollCollapse = TransactionScrollCollapse()
  #endif
```

- [ ] **Step 2: Wire it into the macOS branch**

Locate the macOS branch of `body` (lines 53-61):

```swift
    #if os(macOS)
      ResizableVSplit(
        autosaveName: autosaveName,
        initialTopHeight: initialTopHeight
      ) {
        positions()
      } bottom: {
        transactions()
      }
```

Replace with:

```swift
    #if os(macOS)
      ResizableVSplit(
        autosaveName: autosaveName,
        initialTopHeight: initialTopHeight,
        collapsed: scrollCollapse.isCollapsed
      ) {
        positions()
      } bottom: {
        transactions()
          .environment(\.transactionScrollCollapse, scrollCollapse)
      }
```

- [ ] **Step 3: Verify it compiles**

Run: `just build-mac 2>&1 | tee .agent-tmp/t4.txt | tail -5`
Expected: FAIL — `ResizableVSplit` has no `collapsed:` parameter yet. This is expected; Task 5 adds it. Confirm the *only* error is the missing `collapsed:` argument: `grep -i "error:" .agent-tmp/t4.txt`.

- [ ] **Step 4: Do NOT commit yet**

This task is committed together with Task 5 (they are mutually dependent — the call site and the new parameter must land together to keep every commit buildable). Keep the working tree as-is and proceed to Task 5.

```bash
rm -f .agent-tmp/t4.txt
```

---

### Task 5: `ResizableVSplit` — instant collapse with autosave preserved

**Files:**
- Modify: `Shared/Views/ResizableVSplit.swift` (the whole `#if os(macOS)` body, lines 31-132)

This task lands the **non-animated** collapse first (instant divider jump) so the mechanics — full collapse past `minTopHeight`, autosave preservation, expand-restore — are proven in the running app before animation is layered on (Task 6). NSSplitView/NSViewRepresentable interop has bitten this codebase before (see `plans/2026-05-13-scrolling-detail-headers-redesign.md` post-mortem); proving the mechanism before polishing it is deliberate.

Mechanism:
- New `let collapsed: Bool` parameter.
- The `Coordinator` gains `var isCollapsing = false` and `var savedDividerPosition: CGFloat?`. While `isCollapsing` is true, `constrainMinCoordinate` returns `0` so the divider can travel below `minTopHeight` (the 80pt floor only constrains *user* drags, not a programmatic collapse).
- `updateNSView` compares the incoming `collapsed` to the coordinator's last-applied value and, on a change, calls `applyCollapse` / `applyExpand`.
- `applyCollapse`: snapshot the current divider position into `savedDividerPosition`; set `split.autosaveName = ""` (disables persistence so the 0 position is never written to `UserDefaults`); set `isCollapsing = true`; `split.setPosition(0, ofDividerAt: 0)`.
- `applyExpand`: set `isCollapsing = false`; `split.setPosition(savedDividerPosition ?? initialTopHeight, ofDividerAt: 0)`; restore `split.autosaveName = autosaveName` (persistence resumes from the restored position).

- [ ] **Step 1: Replace the macOS implementation**

Replace lines 31-132 (`struct ResizableVSplit … }` through the end of the `Coordinator` class, i.e. the line `    }` that closes `Coordinator` followed by the line `  }` that closes the struct) with:

```swift
  struct ResizableVSplit<Top: View, Bottom: View>: NSViewRepresentable {
    let autosaveName: String
    let initialTopHeight: CGFloat
    let minTopHeight: CGFloat
    let minBottomHeight: CGFloat
    let collapsed: Bool
    let defaults: UserDefaults
    let top: () -> Top
    let bottom: () -> Bottom

    init(
      autosaveName: String,
      initialTopHeight: CGFloat,
      minTopHeight: CGFloat = 80,
      minBottomHeight: CGFloat = 200,
      collapsed: Bool = false,
      defaults: UserDefaults = .moolahShared,
      @ViewBuilder top: @escaping () -> Top,
      @ViewBuilder bottom: @escaping () -> Bottom
    ) {
      self.autosaveName = autosaveName
      self.initialTopHeight = initialTopHeight
      self.minTopHeight = minTopHeight
      self.minBottomHeight = minBottomHeight
      self.collapsed = collapsed
      self.defaults = defaults
      self.top = top
      self.bottom = bottom
    }

    func makeCoordinator() -> Coordinator {
      Coordinator(
        autosaveName: autosaveName,
        initialTopHeight: initialTopHeight,
        minTopHeight: minTopHeight,
        minBottomHeight: minBottomHeight
      )
    }

    func makeNSView(context: Context) -> NSSplitView {
      let split = NSSplitView()
      split.isVertical = false
      split.dividerStyle = .thin
      split.delegate = context.coordinator

      let topHost = NSHostingView(rootView: top())
      let bottomHost = NSHostingView(rootView: bottom())
      topHost.translatesAutoresizingMaskIntoConstraints = false
      bottomHost.translatesAutoresizingMaskIntoConstraints = false

      split.addArrangedSubview(topHost)
      split.addArrangedSubview(bottomHost)

      context.coordinator.topHost = topHost
      context.coordinator.bottomHost = bottomHost
      context.coordinator.splitView = split

      // Order matters: autosaveName triggers a restore attempt, so we
      // only apply the initial height when no saved frame exists yet.
      let hasSavedFrames =
        defaults.object(
          forKey: "NSSplitView Subview Frames \(autosaveName)") != nil
      split.autosaveName = autosaveName

      if !hasSavedFrames {
        let height = initialTopHeight
        Task { @MainActor [weak split] in
          split?.setPosition(height, ofDividerAt: 0)
        }
      }

      context.coordinator.appliedCollapsed = false
      return split
    }

    func updateNSView(_ nsView: NSSplitView, context: Context) {
      context.coordinator.topHost?.rootView = top()
      context.coordinator.bottomHost?.rootView = bottom()
      context.coordinator.setCollapsed(collapsed, animated: false)
    }

    @MainActor
    final class Coordinator: NSObject, NSSplitViewDelegate {
      var topHost: NSHostingView<Top>?
      var bottomHost: NSHostingView<Bottom>?
      weak var splitView: NSSplitView?
      let autosaveName: String
      let initialTopHeight: CGFloat
      let minTopHeight: CGFloat
      let minBottomHeight: CGFloat

      /// True while a programmatic collapse is in effect. Lets the
      /// divider travel below `minTopHeight` (that floor only
      /// constrains user drags, not the scroll-driven collapse).
      var isCollapsing = false
      /// The divider position to restore when expanding. Captured at
      /// collapse time so the user's dragged / autosaved size returns.
      var savedDividerPosition: CGFloat?
      /// Last value handed to `setCollapsed` so a no-op `updateNSView`
      /// doesn't re-trigger the transition.
      var appliedCollapsed = false

      init(
        autosaveName: String,
        initialTopHeight: CGFloat,
        minTopHeight: CGFloat,
        minBottomHeight: CGFloat
      ) {
        self.autosaveName = autosaveName
        self.initialTopHeight = initialTopHeight
        self.minTopHeight = minTopHeight
        self.minBottomHeight = minBottomHeight
      }

      func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != appliedCollapsed else { return }
        appliedCollapsed = collapsed
        if collapsed {
          applyCollapse()
        } else {
          applyExpand()
        }
      }

      private func applyCollapse() {
        guard let split = splitView else { return }
        savedDividerPosition = split.frame(ofDividerAt: 0).minY
        // Stop NSSplitView persisting the transient 0 position.
        split.autosaveName = ""
        isCollapsing = true
        split.setPosition(0, ofDividerAt: 0)
      }

      private func applyExpand() {
        guard let split = splitView else { return }
        isCollapsing = false
        let target = savedDividerPosition ?? initialTopHeight
        split.setPosition(target, ofDividerAt: 0)
        // Resume persistence from the restored (user-chosen) position.
        split.autosaveName = autosaveName
      }

      func splitView(
        _ splitView: NSSplitView,
        constrainMinCoordinate proposedMinimumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
      ) -> CGFloat {
        // While collapsing, allow the top pane to reach 0. Otherwise
        // enforce the user-drag floor.
        isCollapsing ? 0 : max(proposedMinimumPosition, minTopHeight)
      }

      func splitView(
        _ splitView: NSSplitView,
        constrainMaxCoordinate proposedMaximumPosition: CGFloat,
        ofSubviewAt dividerIndex: Int
      ) -> CGFloat {
        min(proposedMaximumPosition, splitView.bounds.height - minBottomHeight)
      }
    }
  }
```

- [ ] **Step 2: Verify it compiles (and Task 4's call site now resolves)**

Run: `just build-mac 2>&1 | tee .agent-tmp/t5.txt | tail -5`
Expected: `** BUILD SUCCEEDED **`. Confirm no warnings (project treats warnings as errors): `grep -i "warning:\|error:" .agent-tmp/t5.txt` → no user-code hits.

- [ ] **Step 3: Manual verification in the running app**

The collapse mechanics cannot be unit-tested (NSViewRepresentable + NSSplitView divider behaviour). Verify empirically — this is the validation checkpoint the post-mortem demands.

```bash
W="$(git rev-parse --show-toplevel)"
just -d "$W" --justfile "$W/justfile" run-mac-with-logs
```

Then drive the app with the automate-app skill (confirm the profile with the user first per that skill's safety rule):

```bash
T="$W/.claude/skills/automate-app/scripts/moolah-tell"; A="$W/.build/Build/Products/Debug/Moolah.app"
"$T" --app "$A" 'get name of every profile'
# After user confirms profile P and an account with a positions panel
# (e.g. a position-tracked investment or multi-currency account):
"$T" --app "$A" 'navigate to account "<ACCOUNT>" of profile "<P>"'
"$T" --app "$A" 'capture screenshot of profile "<P>"'   # header visible (expanded)
```

Manual check (the user scrolls, or describe how they should):
- Scroll the transaction list down → the top region jumps to zero, transaction list fills the space.
- Scroll back to the very top → the top region returns to **exactly the previous size**.
- Drag the divider to a custom size, scroll down (collapses), scroll back up → divider returns to the **dragged** size (autosave preserved, not reset to default).
- Quit (`pkill -f "Moolah.app/Contents/MacOS/Moolah"`) and relaunch → the dragged divider size persisted (the transient 0 was never saved).
- Switch to another account and back → header is expanded again (Task 3's reset).

Tear down: `pkill -f "Moolah.app/Contents/MacOS/Moolah"; pkill -f "log stream.*processIdentifier"; rm -f .agent-tmp/app-logs.txt`

If any check fails, stop and use `superpowers:systematic-debugging` before proceeding — do not layer animation (Task 6) onto a broken mechanism.

- [ ] **Step 4: Commit Task 4 + Task 5 together**

```bash
just format
R="$(git rev-parse --show-toplevel)"
git -C "$R" add Shared/Views/ResizableVSplit.swift Shared/Views/Positions/PositionsTransactionsSplit.swift
git -C "$R" commit -m "feat(ui): scroll-driven collapse of detail header (instant), autosave preserved"
rm -f .agent-tmp/t5.txt
```

---

### Task 6: Animate the collapse / expand transition

**Files:**
- Modify: `Shared/Views/ResizableVSplit.swift` (`updateNSView` and the `Coordinator`'s collapse/expand methods)

`NSSplitView.setPosition(_:ofDividerAt:)` is not implicitly animated, and animating the divider directly is unreliable. The reliable AppKit pattern is to animate an explicit height constraint on the top hosting view inside an `NSAnimationContext` group, then hand control back to `NSSplitView`. Add a constraint-driven animation; fall back to the proven instant behaviour if a frame isn't available yet.

- [ ] **Step 1: Add an animated path to the `Coordinator`**

Add this stored property to `Coordinator` (next to `savedDividerPosition`):

```swift
      /// Explicit height constraint on the top host, installed only for
      /// the duration of a collapse/expand animation, then removed so
      /// `NSSplitView` resumes ownership of the divider.
      private var animationHeightConstraint: NSLayoutConstraint?
```

Replace `setCollapsed(_:animated:)`, `applyCollapse()`, and `applyExpand()` with:

```swift
      func setCollapsed(_ collapsed: Bool, animated: Bool) {
        guard collapsed != appliedCollapsed else { return }
        appliedCollapsed = collapsed
        if collapsed {
          applyCollapse(animated: animated)
        } else {
          applyExpand(animated: animated)
        }
      }

      private func applyCollapse(animated: Bool) {
        guard let split = splitView, let topHost else { return }
        savedDividerPosition = split.frame(ofDividerAt: 0).minY
        split.autosaveName = ""
        isCollapsing = true
        animate(topHost: topHost, in: split, to: 0, animated: animated) {
          [weak split] in
          split?.setPosition(0, ofDividerAt: 0)
        }
      }

      private func applyExpand(animated: Bool) {
        guard let split = splitView, let topHost else { return }
        let target = savedDividerPosition ?? initialTopHeight
        animate(topHost: topHost, in: split, to: target, animated: animated) {
          [weak self, weak split] in
          self?.isCollapsing = false
          split?.setPosition(target, ofDividerAt: 0)
          split?.autosaveName = self?.autosaveName ?? ""
        }
      }

      /// Animate the top host between heights via a temporary explicit
      /// constraint (AppKit animates constraint constants reliably,
      /// unlike `NSSplitView.setPosition`). On completion the constraint
      /// is removed and `finalize` re-establishes `NSSplitView` control.
      private func animate(
        topHost: NSView,
        in split: NSSplitView,
        to height: CGFloat,
        animated: Bool,
        finalize: @escaping () -> Void
      ) {
        guard animated else {
          finalize()
          return
        }
        let constraint =
          animationHeightConstraint
          ?? topHost.heightAnchor.constraint(equalToConstant: topHost.frame.height)
        constraint.priority = .defaultHigh
        constraint.isActive = true
        animationHeightConstraint = constraint
        split.layoutSubtreeIfNeeded()

        NSAnimationContext.runAnimationGroup { ctx in
          ctx.duration = 0.28
          ctx.allowsImplicitAnimation = true
          ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
          constraint.animator().constant = height
          split.layoutSubtreeIfNeeded()
        } completionHandler: { [weak self] in
          self?.animationHeightConstraint?.isActive = false
          self?.animationHeightConstraint = nil
          finalize()
        }
      }
```

Change `updateNSView` to request animation:

```swift
    func updateNSView(_ nsView: NSSplitView, context: Context) {
      context.coordinator.topHost?.rootView = top()
      context.coordinator.bottomHost?.rootView = bottom()
      context.coordinator.setCollapsed(collapsed, animated: true)
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `just build-mac 2>&1 | tee .agent-tmp/t6.txt | tail -5`
Expected: `** BUILD SUCCEEDED **`, no warnings.

- [ ] **Step 3: Manual verification in the running app**

Repeat Task 5 Step 3's launch + navigate. Now verify:
- Scrolling down collapses the header **smoothly** over ~0.28s (no snap, no flicker, transaction rows slide up as the header shrinks).
- Scrolling back to the top expands it smoothly to the previous size.
- Rapid scroll down-up-down does not leave the header at a wrong height or with a stuck constraint (end state always matches `isCollapsed`).
- All Task 5 Step 3 autosave/persistence/navigation checks still pass.

If the animation is janky or the constraint sticks, use `superpowers:systematic-debugging`; the instant fallback (`animated: false`) from Task 5 remains available as the degraded-but-correct behaviour.

Tear down as in Task 5.

- [ ] **Step 4: Commit**

```bash
just format
R="$(git rev-parse --show-toplevel)"
git -C "$R" add Shared/Views/ResizableVSplit.swift
git -C "$R" commit -m "feat(ui): animate detail-header scroll-collapse transition"
rm -f .agent-tmp/t6.txt
```

---

### Task 7: End-to-end verification across account types + reviews

**Files:** none (verification + review only)

- [ ] **Step 1: Full regression sweep in the running app**

Launch with logs (Task 5 Step 3). With the user's confirmed test profile, exercise each account type that routes through `PositionsTransactionsSplit`:
- A **position-tracked investment** account (`positionTrackedLayout`, `autosaveName: "positions-transactions-split.with-chart"`, chart present).
- A **multi-currency standard** account (via `MultiInstrumentPositionsSplitModifier`, chartless).
- A **crypto wallet** account.

For each: header visible on open → scroll down collapses smoothly → scroll to top expands → divider drag preserved across collapse/expand → navigate away and back resets to expanded. Capture a screenshot of one collapsed and one expanded state with `capture screenshot` for the PR.

- [ ] **Step 2: Confirm iOS and out-of-scope paths are untouched**

Run: `just build-ios 2>&1 | tail -5` → `** BUILD SUCCEEDED **`.
Confirm no behavioural change to `RecordedValueInvestmentLayout` (it imports nothing new; grep to be sure):
`grep -n "transactionScrollCollapse\|TransactionScrollCollapse" Features/Investments/Views/RecordedValueInvestmentLayout.swift` → no matches (expected; legacy layout is deliberately unchanged).

- [ ] **Step 3: Full test suite**

Run: `just test 2>&1 | tee .agent-tmp/t7.txt`
Expected: all green. `grep -i 'failed\|error:' .agent-tmp/t7.txt` → only benign matches. `rm -f .agent-tmp/t7.txt`.

- [ ] **Step 4: Code review agents**

Run the `code-review` agent (architecture / CODE_GUIDE), the `concurrency-review` agent (the model is `@MainActor @Observable`; `ResizableVSplit.Coordinator` is `@MainActor` — verify no isolation violations), and the `ui-review` agent (animation, HIG, accessibility — confirm the collapse doesn't trap VoiceOver focus and respects `accessibilityReduceMotion`).

- [ ] **Step 5: Reduce Motion**

If `ui-review` flags it (it should): gate the animation on `@Environment(\.accessibilityReduceMotion)` in `PositionsTransactionsSplit` — pass `animated: !reduceMotion` through to `ResizableVSplit` (add a `reduceMotion: Bool` parameter forwarded into `setCollapsed(_:animated:)`). Re-verify in the app with Reduce Motion on (instant collapse, no animation) and off (animated). Commit:

```bash
just format
R="$(git rev-parse --show-toplevel)"
git -C "$R" add -A
git -C "$R" commit -m "feat(ui): honour Reduce Motion for header collapse"
```

- [ ] **Step 6: Address all review findings**

Apply every Critical / Important / Minor finding from Step 4 (per the project's "apply all review findings" rule — pre-existing-elsewhere is not a skip reason; ask before deferring anything). Commit fixes. Then use `superpowers:finishing-a-development-branch` to open the PR and add it to the merge queue (per project workflow — every PR goes through the merge-queue skill).

---

## Self-Review

**Spec coverage:**
- Collapse on scroll-down, expand only at top → Task 1 model + Task 3 observer. ✓
- Transient override, autosave preserved → Task 5 (`autosaveName = ""` during collapse, restore on expand) + Task 5 Step 3 persistence checks. ✓
- Reset to expanded on navigation → Task 3 Step 3 (`scrollCollapse?.reset()` in `.onChange(of: baseFilter)`). ✓
- macOS only, iOS unchanged → `#if os(macOS)` in Tasks 3 & 4; Task 7 Step 2 `just build-ios`. ✓
- Legacy/recorded-value unchanged → explicitly out of scope; Task 7 Step 2 grep guard. ✓
- Smooth animation → Task 6; Reduce Motion → Task 7 Step 5. ✓
- All split-hosted account types covered without per-leaf churn → environment injection in Task 4; Task 7 Step 1 sweeps all three. ✓

**Placeholder scan:** No TBD/TODO; every code step has full code; commands have expected output. ✓

**Type consistency:** `TransactionScrollCollapse` (`isCollapsed`, `update(offsetY:)`, `reset()`) used identically in Tasks 1, 3, 4. `ResizableVSplit` `collapsed:` parameter defined Task 5, called Task 4 (committed together — Task 4 Step 4 / Task 5 Step 4). `Coordinator.setCollapsed(_:animated:)` signature consistent Tasks 5 → 6. Environment key `\.transactionScrollCollapse` consistent Tasks 2, 3, 4. ✓
