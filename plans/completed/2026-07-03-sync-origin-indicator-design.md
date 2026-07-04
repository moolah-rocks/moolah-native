# Sync-origin indicator in the transaction detail panel

**Date:** 2026-07-03
**Status:** Approved design

## Goal

The transaction detail panel should show an indicator when a transaction was
automatically created by background sync. In the custom (multi-leg) view the
indicator appears on each synced leg. In the other views a single indicator
appears when any leg is auto-synced.

"Automatically created via sync" means **background sync only** — wallet sync
(`parserIdentifier "alchemy-wallet-sync"`) and exchange sync (Coinstash,
`parserIdentifier "coinstash"`). User-initiated CSV / bank / web file imports
also carry an `importOrigin` but are **not** flagged.

## Background: how sync origin is recorded

- **Transaction level:** `Transaction.importOrigin: TransactionImportOrigin?`
  (`.single(ImportOrigin)` / `.merged(MergedImportOrigin)`). `ImportOrigin`
  carries a `parserIdentifier: String` naming the source. Nil `importOrigin`
  means a manually-created transaction.
- **Leg level:** `TransactionLeg.externalId: String?` — non-nil only for legs
  produced by an id-bearing importer. Both wallet sync (Alchemy `uniqueId` /
  gas-leg id) and exchange sync set it on every leg; manually-added legs keep
  `externalId == nil`. It is nil for CSV-imported legs.
- **Merged transfers:** `MergedImportOrigin` holds exactly two optional sides,
  `outgoing` and `incoming`, each with its own `parserIdentifier`. A merged
  cross-account transfer can therefore span two different sync sources (e.g. a
  wallet outgoing leg and a Coinstash incoming leg).

There is no existing `parserIdentifier → display name` mapping; this design adds
one.

## Detection & source resolution (single testable resolver)

One pure helper is the source of truth. Both the custom leg rows and the
non-custom row read from it. It is computed from the **domain** `Transaction`
(which has real signed leg quantities), not the editor drafts.

```swift
enum BackgroundSyncSource {
  case wallet        // parserIdentifier "alchemy-wallet-sync" → "Wallet"
  case coinstash     // parserIdentifier "coinstash"           → "Coinstash"

  var displayName: String
  init?(parserIdentifier: String)   // nil for CSV / web / bank / unknown ids
}

extension Transaction {
  /// legId → source, only for legs that came from background sync.
  func backgroundSyncedLegSources() -> [UUID: BackgroundSyncSource]
}
```

Rules:

1. No `importOrigin` → empty map (manual transaction).
2. **Gate on `parserIdentifier`.** `BackgroundSyncSource(parserIdentifier:)`
   returns nil for any non-background-sync id, so CSV / bank / web imports
   produce an empty map. This is what enforces "background sync only".
3. A leg is included only when `externalId != nil` **and** its resolved source
   is non-nil. A manually-added leg (nil `externalId`) on a synced transaction
   is not flagged.
4. `.single(origin)`: every qualifying leg maps to that one source.
5. `.merged(outgoing, incoming)`: assign by leg direction — a leg with
   `quantity < 0` (outgoing) maps to `outgoing`'s source; `quantity >= 0`
   (incoming) maps to `incoming`'s source. If only one side resolves to a known
   source, qualifying legs fall back to that side.

## Custom view — per-leg icon in the section header

In `TransactionDetailLegRow`, the `Section("Sub-transaction N of M")` header
gains a trailing `Image(systemName: "arrow.triangle.2.circlepath")`, shown
**only** when that leg's id is present in the resolver map. There is **no
visible label** — the source name is a tooltip via
`.help("Synced from \(source.displayName)")`, which doubles as the
accessibility label. The icon is `.secondary`-tinted so it reads as metadata,
not an action.

## Non-custom views — one row at the bottom

Simple (income / expense / transfer), trade, and earmark-only modes get a new
`TransactionDetailSyncSection`, shown **iff any** leg is in the resolver map. It
renders a single row: the same icon plus a **visible** label
`"Synced from \(names)"`, where `names` joins the distinct sources present:

- one source → `"Synced from Wallet"` / `"Synced from Coinstash"`
- two sources (merged) → `"Synced from Wallet and Coinstash"`

Read-only caption styling.

Placement: appended at the end of the non-custom content, **above** the Delete
section (Delete is a destructive action and stays last). Open to moving it
literally last if preferred.

## Visuals

- Icon: `arrow.triangle.2.circlepath` (standard sync glyph), `.secondary` tint.
- Strings: `"Synced from Wallet"`, `"Synced from Coinstash"`,
  `"Synced from Wallet and Coinstash"`.

## Testing

- Unit tests on `Transaction.backgroundSyncedLegSources()` (the core logic):
  - single-source wallet → all synced legs mapped to `.wallet`
  - single-source Coinstash → mapped to `.coinstash`
  - single-source CSV / bank (`parserIdentifier` not in the known set) → empty
  - merged wallet + Coinstash → each leg mapped by direction
  - synced + manually-added leg mixed → only the `externalId != nil` legs mapped
  - no `importOrigin` → empty
- Optional UI-test assertion: the sync row/identifier is present for a
  synced seed and absent for a manual one. Confirm whether this is wanted.

## Files

- **New:**
  - `BackgroundSyncSource` + `Transaction.backgroundSyncedLegSources()` (Domain)
  - `TransactionDetailSyncSection.swift` (Features/Transactions/Views/Detail)
- **Edit:**
  - `TransactionDetailLegRow.swift` — trailing header icon + tooltip
  - `TransactionDetailView+FormContent.swift` — render the section in the
    non-custom branches; make the resolver map available to the leg rows

## Review gate

Run `@code-review` and `@ui-review` and fix all findings before committing, per
the repo's mandatory AI review gate.
