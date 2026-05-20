# Hide Spam-Token Transactions From the Transaction List

**Status:** Design — not yet implemented.
**Date:** 2026-05-20.
**Author:** brainstormed with Claude.

## Problem

Users with on-chain wallets accumulate airdrop "spam" — token transfers
they did not initiate, from tokens with no real value, often used to
phish or to clutter wallet history. The spam visual indicator
(red "⚠️ Spam" badge on rows, shipped per
`plans/completed/2026-05-10-spam-transaction-row-indicator-plan.md`) makes
each spam-touching row identifiable, but the rows still occupy the list
and dominate it for active wallet users. The user wants spam
transactions hidden by default, with a one-click way to bring them back
when needed.

## Goal

- Spam-only transactions (e.g. airdrop receives, the dominant case) are
  hidden from every `TransactionListView` consumer by default.
- A View menu item (macOS) or toolbar control (iOS) toggles the hide on
  and off. The preference persists across launches and applies app-wide.
- Mixed transactions — where at least one leg references a real
  instrument — remain visible. The user explicitly does *not* want a
  real-balance-affecting transaction disappearing just because one leg
  happens to be a spam token.
- Aggregate values (account balances, totals, reports) are unchanged.
  In practice spam tokens are unpriced and contribute $0 anyway, but the
  scope boundary is part of the spec.

## Non-Goals

- **No new spam detection.** The set of spam-flagged instruments
  (`spamInstruments`, derived from `CryptoRegistration.pricingStatus ==
  .spam`) already exists and is injected into the environment. This
  feature consumes that set; it does not change how instruments become
  spam-flagged.
- **No per-token "always show this spam token" preference.** The toggle
  is a single global Bool.
- **No "N spam transactions hidden" footer.** Matches the "Show Hidden
  Accounts" precedent; revisit only if user feedback says the empty
  state confuses people.
- **No change to the row-level "⚠️ Spam" indicator.** It continues to
  flag *any* leg referencing a spam instrument — informational, not
  removal. This intentionally differs from the hide rule (see below).

## Definition: When Is a Transaction "Spam"?

A transaction is hidden when, and only when:

```
!transaction.legs.isEmpty
  && transaction.legs.allSatisfy { spamInstruments.contains($0.instrument) }
```

That is: at least one leg, and **every** leg references a spam
instrument. Cases:

| Legs | Spam? | Hidden by default? |
|---|---|---|
| Single leg, spam token (typical airdrop receive) | all spam | Yes |
| Swap USDC → SPAM token (one spam, one not) | mixed | **No — visible** |
| Swap SPAM → SPAM (rare) | all spam | Yes |
| Multi-leg transfer of one spam token between wallets | all spam | Yes |
| Fee paid in spam token while moving USDC | mixed | No — visible |
| Zero legs (defensive — shouldn't occur in practice) | n/a | No — visible |

This is intentionally **stricter** than the row indicator rule
(`legs.contains { spamInstruments.contains($0.instrument) }`). The two
serve different purposes:

- **Indicator (any leg):** informs the user that a transaction touched a
  spam token. Mixed-leg transactions still get the badge on the spam
  leg.
- **Hide rule (all legs):** removes pure noise. Anything touching a real
  balance must remain visible so the user is not surprised by a missing
  transaction in their account history.

## User-Facing Behaviour

### macOS — View menu item

A `Button` in the View menu, immediately after the existing "Show
Hidden Accounts" entry. Label flips between the two states per UI_GUIDE
§14 "Toggle State" (mirrors `ShowHiddenCommands` at
`App/MoolahDomainCommands.swift:63-77`):

- Currently hidden (default): `"Show Spam Transactions"`
- Currently shown: `"Hide Spam Transactions"`

No keyboard shortcut in this iteration. (The Show Hidden Accounts
shortcut is ⇧⌘H; if a follow-up issue requests one we can pick a free
combination then. Not in scope for the first ship.)

The menu item is disabled (`.disabled(showSpam == nil)`) when no scene
provides the focused-value binding — same defensive pattern as
`ShowHiddenCommands`.

### iOS — toolbar item on `TransactionListView`

A toolbar button (placement: `.primaryAction` next to the existing
filter button) that toggles the same `@AppStorage` preference.

- Hidden state (default): `eye.slash` SF Symbol,
  `accessibilityLabel("Show Spam Transactions")`.
- Shown state: `eye` SF Symbol,
  `accessibilityLabel("Hide Spam Transactions")`.

No textual label in the toolbar; icon-only with accessibility label is
consistent with the other iOS toolbar controls.

### Persistence

- `@AppStorage("showSpamTransactions") private var showSpam = false`
- macOS: bound in `SidebarView` and published via
  `.focusedSceneValue(\.showSpamTransactions, $showSpam)` so the menu
  command binds to the active scene's preference. Mirrors the
  `showHiddenAccounts` wiring at `Features/Navigation/SidebarView.swift:29,57`.
- iOS: read directly with `@AppStorage` inside `TransactionListView`,
  no focused-value plumbing required.
- `false` (default) = transactions hidden. `true` = transactions shown.

## Architecture: Where the Filter Runs

The filter runs in `TransactionStore`. It does **not** live in
`TransactionFilter`, in `filteredTransactions`, or in any view-private
computed property.

### Wiring

1. `TransactionStore` gains a `showSpam: Bool` property (defaults to
   `false`) and a `spamInstruments: Set<Instrument>` property fed from
   `CryptoTokenStore`.
2. The store's published transactions list filters out any transaction
   that satisfies the all-legs-spam predicate above, unless
   `showSpam == true`.
3. `SidebarView` syncs the `@AppStorage` preference into the store via
   `.onChange(of: showSpam) { transactionStore.showSpam = newValue }`,
   exactly like the existing `accountStore.showHidden = newValue` wiring
   at `Features/Navigation/SidebarView.swift:60-66`.
4. The store also observes `cryptoTokenStore.spamInstruments` (already
   `@Observable`) and re-filters when the spam set changes — so marking
   a new token as spam in Settings ripples through the list immediately.

### Why the store and not the filter

- Matches the **established precedent**: `accountStore.showHidden`
  is a store-level property, not a field on a query filter, and is
  exactly the analogous "global UI preference applied to a published
  list" case.
- Keeps `TransactionFilter` semantically about *what data to query*
  (account, category, date range), not about *how to display* the
  results. Spam-hiding is presentation, not query.
- Logic in the store is unit-testable against `TestBackend` per
  CLAUDE.md "Thin Views, Testable Stores".
- The filter must run in memory regardless: spam membership is a
  runtime set, not a database column. Pushing it into
  `TransactionFilter` would not give it any database-index leverage.

### Why not the view's `filteredTransactions`

`TransactionListView.filteredTransactions` (currently a single payee
search-text filter) is a thin presentation hook. Multi-condition,
multi-input filtering (spam set + preference) is business logic and
belongs in the store per CLAUDE.md §"Thin Views, Testable Stores".

## Scope of the Effect

The store-level filter applies wherever `TransactionStore`'s published
list is consumed:

- Main "All Transactions" list — affected.
- Account-detail transaction list — affected.
- `.searchable` payee search inside the list — affected (hidden spam
  transactions also don't surface in search). Matches Show Hidden
  Accounts behaviour: hidden things stay hidden, including from search.

Out of scope and explicitly **unaffected**:

- Account balances, sidebar totals, reports, dashboards.
- Spam-token settings UI in `Features/Settings/SpamTokensView.swift` —
  it lists registrations, not transactions, and is unaffected.

## Tests

Store tests live in `MoolahTests/Features/Transactions/`, run against
`TestBackend` (CloudKitBackend + in-memory SwiftData), and use Swift
Testing (`@Suite` / `@Test`) per the project's testing convention.

Required cases:

1. **Single-leg all-spam → hidden.** Default state (`showSpam == false`)
   filters out a transaction with one leg referencing a spam instrument.
2. **Multi-leg all-spam → hidden.** Default state filters out a
   transaction whose every leg references a spam instrument.
3. **Mixed-leg → always visible.** A transaction with at least one
   non-spam leg is included regardless of `showSpam`.
4. **Toggling `showSpam` republishes.** Setting `showSpam = true` causes
   previously-hidden all-spam transactions to reappear in the published
   list without requiring a re-`observe`.
5. **`spamInstruments` change re-filters.** Marking a new instrument as
   spam (so that a previously-visible all-spam transaction now meets the
   hide predicate) updates the published list live.
6. **Empty-legs transaction → visible.** Defensive: zero-legs cannot
   satisfy the predicate (we require `!legs.isEmpty`).

Optional UI test (`MoolahUITests_macOS`, gated by host availability):
toggle the View menu item; assert visibility of a seeded
spam-transaction row before and after, then again after relaunching
the app to verify persistence.

## Implementation Surface

Concrete files to touch:

| File | Change |
|---|---|
| `Domain/Models/Transaction.swift` | Add `func isAllSpam(in: Set<Instrument>) -> Bool` (or compute the predicate inline in the store; pick whichever the code-review agent prefers). |
| `Features/Transactions/TransactionStore.swift` | Add `var showSpam: Bool`, `var spamInstruments: Set<Instrument>`, observation of spam-set changes, and apply the predicate when publishing transactions. |
| `Features/Transactions/Views/TransactionListView.swift` | iOS: add toolbar button with flipped icon + a11y label, bound to `@AppStorage("showSpamTransactions")`. macOS: no change here — driven from sidebar. |
| `Features/Navigation/SidebarView.swift` | Add `@AppStorage("showSpamTransactions") private var showSpam = false`, `.focusedSceneValue(\.showSpamTransactions, $showSpam)`, and `.onChange(of: showSpam) { transactionStore.showSpam = newValue }`. Mirror the `showHidden` block at lines 29, 57, 60-66. |
| `Shared/FocusedValues.swift` | Add `ShowSpamTransactionsKey: FocusedValueKey` with `Value = Binding<Bool>`, plus the `FocusedValues` accessor extension. Place immediately after `ShowHiddenAccountsKey` at line 34. |
| `App/MoolahDomainCommands.swift` | Add a `ShowSpamTransactionsCommands: Commands` struct alongside `ShowHiddenCommands` (lines 63-77), and register it in the app's `.commands` block where `ShowHiddenCommands` is registered. Button label flips per the verb-pair pattern. |
| `MoolahTests/Features/Transactions/TransactionStoreTests.swift` (or a new file beside it) | Add the six store tests listed above. |

No CloudKit schema changes. No new domain types beyond the optional
`Transaction.isAllSpam(in:)` helper.

## Open Questions

None blocking. Two minor decisions deferred to implementation review:

- Whether `isAllSpam(in:)` lives on `Transaction` as an extension, or as
  a free private helper in `TransactionStore`. The `code-review` agent's
  judgement on extension organisation (CODE_GUIDE.md §"one extension
  per protocol/purpose") settles this; the spec does not pre-judge.
- Whether the macOS menu item gets a keyboard shortcut in this
  iteration. Default: no. Easy to add in a follow-up.
