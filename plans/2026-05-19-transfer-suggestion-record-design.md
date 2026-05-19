# Transfer-suggestion as a first-class record — design

Date: 2026-05-19
Status: approved (brainstorm), pending implementation plan

## Problem

Transfer detection currently persists two things:

1. A **positive** annotation: `TransferSuggestion { counterpartTransactionId, suggestedAt }`
   denormalised onto *both* transactions via `TransactionRecord` columns
   (`transferSuggestionCounterpartId`, `transferSuggestionSuggestedAt`).
2. A **negative** assertion: `DismissedTransferPair` — a separate
   content-addressed, synced record type + GRDB `dismissed_transfer_pair`
   table — recording "these two transactions are NOT a transfer".

The negative assertion exists only because detection can re-evaluate an
already-seen pair and would otherwise re-suggest a dismissed one. The
re-evaluation happens because the two trigger paths disagree on what
"newly imported" means:

- **CSV import** (`ImportStore`) drives detection off the genuinely-new
  persisted batch — correct.
- **Crypto/exchange sync** (`SyncedAccountStore+Internals.runTransferDetection`)
  drives detection off a **3-day rolling window of *all* transactions on
  the synced accounts**, every sync — so every periodic sync re-evaluates
  (and without the tombstone would re-suggest) every transfer in that
  window.

The `DismissedTransferPair` snapshot is also loaded and scanned to filter
detection results; PR #947 already reduced that filter from O(n) to O(1),
but the underlying negative-assertion machinery remains.

## Goal

Make a transfer suggestion a first-class, deletable, synced record.
Detection writes one when it finds a candidate pair; dismissing it simply
deletes that record. No negative-assertion table anywhere. This is only
correct if detection *only ever* runs over genuinely-new transactions, so
the crypto/exchange trigger is fixed as part of this work.

## Stated assumptions

- The transfer-detection CloudKit record types/fields and the v11/v12
  GRDB migrations landed after `v1.1.0-rc.21` (the latest RC) and have
  **not** been promoted to any production / TestFlight build.

  **Decision (final, approved): `DismissedTransferPairRecord` and the two
  `TransactionRecord.transferSuggestion*` fields are PHYSICALLY DELETED
  from `CloudKit/schema.ckdb` — not marked `// DEPRECATED`, not left
  additive.** They never shipped: there is no production zone, no
  on-device data, no user carrying these fields. The additive-only rule
  protects *shipped* schema and does not apply. Keeping deprecated-but-
  present wire fields for a never-shipped feature would be permanent dead
  weight; removal is the correct end state.

  This is expected to draw repeated objections from `@database-schema-
  review`, `@sync-review`, and human reviewers, and to trip the CI
  additivity gate (the `schema-prod-baseline.ckdb` diff /
  `tools/CKDBSchemaGen` additivity check). The sanctioned response is to
  **work around the CI gate** (advance the prod baseline to the new
  shape and/or apply the project's documented additivity-override),
  **not** to retreat to a deprecation path. The rationale is recorded in
  the PR body and a comment at the `schema.ckdb` edit site so it is not
  re-litigated each review pass. The `modifying-cloudkit-schema` runbook
  owns the exact override mechanism; `guides/DATABASE_SCHEMA_GUIDE.md`
  governs the GRDB migration shape. The prod-baseline diff is gathered
  only as PR evidence that the removal touches never-shipped schema — it
  is not a gate that can flip this decision back to deprecation.
- Dropping the `dismissed_transfer_pair` table is acceptable even if a
  developer/tester DB already has rows in it. **No data migration** from
  `dismissed_transfer_pair` to the new table — tombstones carry no
  meaning in the new model.

## Data model

New synced domain entity (replaces the denormalised annotation):

```
TransferSuggestion {
  id: UUID            // content-addressed from the unordered {txA, txB} pair
  transactionIdA: UUID
  transactionIdB: UUID
  suggestedAt: Date
}
```

`id` reuses the `DismissedTransferPair.contentAddressedID(for:)`
derivation shipped in PR #947 (relocated/shared so both the new type and
any remaining caller use one implementation). Content-addressing gives:

- Idempotent re-detection of a still-live pair (upsert same row).
- Deterministic UI lookup by pair.
- Convergent cross-device create (same id on every device).

### Removed entirely

- `DismissedTransferPair` domain model.
- `DismissedTransferPairRecord` CloudKit record type + generated wire
  layer + `CloudKitRecordConvertible` conformance + sync mapping +
  observation region + repository + contract/rollback/queue tests.
- GRDB `dismissed_transfer_pair` table.
- `TransactionRecord.transferSuggestionCounterpartId` and
  `transferSuggestionSuggestedAt` columns (CloudKit + GRDB).

### Untouched

- `importOriginKind` / `importOriginIncoming*` columns — these belong to
  the cross-account *merge* feature, not detection.
- `FuzzyTransferDetector` pairing logic and `windowSeconds` — the latter
  remains the maximum date gap *between the two sides of a candidate
  pair*; it no longer drives any scan window.

## Detection trigger — unified to "genuinely new only"

- **CSV import:** already passes the genuinely-new `imported` batch as
  `newlyImported`. Only change: detection writes a `TransferSuggestion`
  record instead of annotating transaction columns.
- **Crypto/exchange sync:** `WalletApplyEngine.apply(perAccount:)`
  already returns "the transactions actually persisted (merged-and-deduped
  survivors)" — exactly the genuinely-new set — but
  `SyncedAccountStore+Internals.runApplyPass` discards it
  (`_ = try await walletApplyEngine.apply(...)`). Change `runApplyPass`
  to return that `[Transaction]`; `SyncedAccountStore.syncAccounts`
  passes it to detection. **Delete** the candidate re-fetch + 3-day
  window in `runTransferDetection` (the
  `TransactionFilter(dateRange: windowLowerBound...distantFuture)` fetch
  and the participating-account in-memory filter). Both wallet and
  exchange flow through this one apply engine, so one change covers both.

## Lifecycle

| Action | Effect |
|---|---|
| **Detect** | For each genuinely-new tx, find a counterpart in the existing pool (existing `FuzzyTransferDetector` logic). Upsert one `TransferSuggestion` per pair. |
| **Dismiss** | Delete the `TransferSuggestion` record. Nothing else. No tombstone. |
| **Merge / manual-merge** | Replace the two txns with the merged two-leg transfer (unchanged) and delete the `TransferSuggestion` record. |
| **Unmerge** | Split back into two txns (unchanged). Split products are not genuinely-new, so no detection pass ever re-evaluates them → never re-suggested. **Remove** the `DismissedTransferPair`-on-unmerge write — no longer needed. |

## Cross-device correctness

Detection runs only on the device performing the import/sync, only over
that device's genuinely-new rows. The `TransferSuggestion` record syncs;
a dismiss-delete syncs. No device ever re-runs detection over
already-existing transactions, so there is no divergence and no negative
assertion is needed for convergence.

## Schema & migration

### CloudKit (`CloudKit/schema.ckdb`)

- **Physically delete** the entire `RECORD TYPE DismissedTransferPairRecord`
  block (not deprecate — see "Stated assumptions").
- Add `TransferSuggestionRecord` with `transactionIdA`,
  `transactionIdB` (STRING QUERYABLE SEARCHABLE SORTABLE), `suggestedAt`
  (TIMESTAMP QUERYABLE SORTABLE), standard system fields + grants
  matching peer record types.
- **Physically delete** the `transferSuggestionCounterpartId` /
  `transferSuggestionSuggestedAt` field lines from `TransactionRecord`
  (not deprecate).
- Regenerate `Backends/CloudKit/Sync/Generated/` via `just generate`.
- Run through the `modifying-cloudkit-schema` runbook. The runbook's
  additivity gate / CI `schema-prod-baseline.ckdb` check **will** object
  to the deletions — that is expected; advance the prod baseline to the
  new shape and/or apply the runbook's sanctioned additivity-override so
  CI passes with the removal intact. Do **not** deprecate to satisfy the
  gate. Confirm `DataFormatVersion` handling in the runbook (expected:
  keep current value with revised meaning, since the prior bump is
  itself unshipped; the general-rule alternative is a `3 → 4` bump —
  the runbook + `@database-schema-review` arbitrate, but neither path
  reinstates the deleted fields).

### GRDB

- A **new forward migration** (next version after v12; not an in-place
  edit of v12) that:
  - drops the `dismissed_transfer_pair` table (no data preserved);
  - drops the two `transferSuggestion*` columns from `transactions`;
  - creates `transfer_suggestion` (`id` PK, `transaction_id_a`,
    `transaction_id_b`, `suggested_at`), STRICT, with an index on each
    transaction-id column for the UI lookup.
- New forward migration (rather than editing v12 in place) so a
  developer/tester who already ran v12 converges cleanly.
  `database-schema-review` validates the final shape, PRAGMAs, indexes,
  and retention against `guides/DATABASE_SCHEMA_GUIDE.md` during
  planning.

## Sync

- `TransferSuggestionRecord` + `CloudKitRecordConvertible` conformance
  (own file/extension per CODE_GUIDE §2), GRDB row + mapping,
  observation region, queue/delete + system-fields wiring, repository
  registered on `BackendProvider` — mirroring the structure of the
  removed `DismissedTransferPair` plumbing.
- Delete is a first-class synced operation (record removed on dismiss /
  merge propagates to other devices).

## UI read path

Views currently read `transaction.transferSuggestion` (the banner in
transaction detail and the "possible transfer" pill in Recently Added).
They will instead resolve suggestions via a repository query keyed by
transaction id. Keep views thin: the lookup/aggregation lives in the
store or a repository accessor, not in a private view method.

## Testing

- `TransferSuggestionRepository` contract tests (create/upsert by
  content-addressed id, fetch by transaction id, delete).
- Coordinator tests for detect / dismiss / merge / unmerge — assert both
  coordinator state and repository state, error/rollback paths.
- Explicit test: **unmerge does not re-suggest** (split products are not
  fed to detection).
- Sync round-trip + rollback + hook-record-type + queue + mapping tests
  for `TransferSuggestionRecord` (mirror the deleted `DismissedTransferPair`
  suites; carve-out list updated).
- Migration test: new version creates `transfer_suggestion`, removes
  `dismissed_transfer_pair` and the two `transactions` columns; rollback
  test per existing pattern.
- Crypto/exchange trigger test: detection drives off
  `WalletApplyEngine`'s persisted-survivors set, **not** a date window;
  a previously-existing transaction outside the genuinely-new set is not
  re-evaluated.
- DataFormatVersion / golden-schema pins updated per the
  `modifying-cloudkit-schema` runbook.

## Out of scope

- Any change to the `FuzzyTransferDetector` matching algorithm.
- The merge feature's `importOriginKind` / `importOriginIncoming*`
  columns.
- Re-import (overlapping CSV) behaviour: genuinely-new duplicate rows
  legitimately produce fresh suggestions; unchanged by this design.
