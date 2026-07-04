# AmountField — shared component, iOS negative entry, select-on-focus

**Date:** 2026-06-30
**Status:** Design (approved pending spec review)

## Problem

Two iOS usability defects in the transaction amount entry field:

1. **No negative entry.** The amount field uses the iOS `.decimalPad` keyboard,
   which has no minus key. Users cannot enter a negative *display* amount — which
   is needed for refunds (an expense whose display value is negative), negative
   income, and signed trade legs. The parser already accepts a leading `-`; only
   the keyboard can't produce one.
2. **Awkward focus.** Tapping into the field drops the caret beside the existing
   value (commonly `0`), so the user must manually delete before typing. Focus
   should select the existing content (`0` or non-zero) so the first keystroke
   replaces it — but **only** when focus first enters the field, so a subsequent
   tap can still position the caret.

Compounding both: there is **no shared amount-input component**. The same
`TextField` + modifier stack is duplicated across five transaction-detail
sections, so any fix would otherwise be copied five times.

## Goal

Extract a single reusable `AmountField` and fix both defects in that one place.

## Non-goals

- No change to how amounts are parsed, signed, or stored. The display-negation
  model (`TransactionDraft+Negation`) is unchanged; we only make it possible to
  *type* a leading minus on iOS and to replace the value more easily.
- No change to `CompactInstrumentPickerButton`; it stays a separate sibling.
- No macOS behavior change beyond consolidation (see Select-on-focus below).

## Current state

The duplicated block lives in (all under
`Features/Transactions/Views/Detail/`):

- `TransactionDetailDetailsSection.swift` — primary simple-mode amount
- `TransactionDetailCrossCurrencyRow.swift` — counterpart amount
- `TransactionDetailTradeSection.swift` — Paid / Received legs
- `TransactionDetailFeeSection.swift` — trade fee
- `TransactionDetailLegRow.swift` — custom-mode legs

Each is a plain `TextField` bound to a `String`, with:
`.labelsHidden()` · `.multilineTextAlignment(.trailing)` · `.monospacedDigit()` ·
`#if os(iOS) .keyboardType(.decimalPad) #endif` ·
`.focused($focusedField, equals: <TransactionDetailFocus case>)`, paired with a
`CompactInstrumentPickerButton`.

Focus is a shared `@FocusState` of `TransactionDetailFocus?` owned by
`TransactionDetailView`, threaded into each section as a
`@FocusState.Binding`.

## Design

### Component: `Shared/Views/AmountField.swift`

A thin view encapsulating only the amount text field (the instrument picker
remains a separate sibling, because its instrument source differs per call site).

Interface:

```swift
struct AmountField: View {
    @Binding var text: String
    let focus: FocusState<TransactionDetailFocus?>.Binding
    let field: TransactionDetailFocus   // this field's focus case
    var onSubmit: (() -> Void)? = nil
}
```

Owns the shared modifier stack (`labelsHidden`, trailing, `monospacedDigit`, iOS
`decimalPad`, `.focused(focus, equals: field)`, `onSubmit`). No business logic.

### 1. Negative entry on iOS — keyboard-toolbar ± button

`AmountField` attaches an **iOS-only** keyboard accessory:

```swift
#if os(iOS)
.toolbar {
    ToolbarItemGroup(placement: .keyboard) {
        Button { text = AmountText.toggledSign(text) } label: { … "±" … }
        Spacer()
    }
}
#endif
```

- Only appears while the field is being edited; no permanent layout cost.
- The toggle is a **pure string function** living in a model/util extension
  (`AmountText.toggledSign(_:)`), so it is unit-testable independently of the
  view. It flips a single leading `-` on the display text — it never calls
  `abs()` and never infers sign from position (respects the trade-leg sign rule).
- Because the bound `text` is the existing display-text binding, the existing
  `parseDisplayText` un-negation makes refunds / signed legs fall out correctly.

### 2. Select-on-focus-in

Uses the native `TextField(_:text:selection:)` initializer (available iOS 18+ /
macOS 15+, both covered by the iOS 26 / macOS 26 deployment targets).

- **iOS:** `AmountField` holds `@State private var selection: TextSelection?` and
  watches `focus.wrappedValue`. On the **false→true transition only** (field
  becomes focused), it sets `selection` to the field's full text range, so the
  first keystroke replaces the value. It does **not** re-select while already
  focused, so a second tap positions the caret normally. Guarded `#if os(iOS)`.
  May require deferring the selection assignment one runloop turn
  (`Task { @MainActor in … }` / `.task`) so it lands after the keyboard /
  first-responder settles — to be confirmed against a live device/preview.
- **macOS:** No custom select logic. Rely on the AppKit default already inherited
  by SwiftUI `TextField`: tabbing into the field selects its contents; clicking
  positions the caret. This is exactly the requested macOS behavior, so macOS
  keeps the plain (non-`selection`) path or simply never triggers the iOS-only
  transition handler.

### 3. Refactor call sites

Replace the duplicated `TextField` block in all five sections with `AmountField`,
passing each section's existing text binding, focus binding, and focus case.
`onSubmit` carries the existing cross-currency advance behavior in
`TransactionDetailDetailsSection`.

## Testing

- **Unit (TDD, write first):** `AmountText.toggledSign(_:)` — one uniform rule:
  strip a single leading `-` if present, otherwise prepend `-`. No special-casing
  of zero or empty (this lets the user set the sign *before* typing digits, which
  is the natural "tap ±, then type" flow).
  - `"50"` → `"-50"`, `"-50"` → `"50"`
  - `"-12.34"` → `"12.34"` (decimals preserved)
  - `"0"` → `"-0"`, `"-0"` → `"0"` (`"-0"` parses to `0`, harmless)
  - `""` → `"-"`, `"-"` → `""` (toggle sign first, then type)
  - Malformed / multi-sign input is out of scope — the parser rejects it; only
    the well-formed cases above are asserted.
- **View behavior:** select-on-focus and the ± toolbar are view-level; verify via
  `#Preview` / `RenderPreview`. Check whether an existing macOS UI test should be
  extended to cover negative entry; if cheap, add one asserting a refund can be
  entered. (UI tests are macOS-only here, where the ± button does not exist, so
  the ± path is preview-verified on iOS rather than UI-tested.)
- No new store/repository logic, so no contract/store tests needed.

## Open implementation risks

- **Selection timing on iOS:** setting `selection` exactly at focus-in may race
  the keyboard presentation; confirm the deferred-assignment approach renders
  correctly (cross-reference the inspector in-place focus memory note about
  `.task` focus claims racing AppKit/UIKit teardown).
- **Keyboard toolbar duplication:** five `AmountField` instances each declare a
  keyboard toolbar; confirm only the focused field's accessory shows (expected
  SwiftUI behavior) and there is no doubled toolbar.
