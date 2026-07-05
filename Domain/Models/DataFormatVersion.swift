/// Highest profile data-format version this build can safely read and write.
///
/// `DataFormatVersion` is a case-less enum used as a namespace — not
/// instantiable, just a home for the constant.
///
/// Bump `current` whenever you ship a forward-incompatible change to the
/// profile data — anything an older build can't faithfully read,
/// round-trip, or sync without silent data loss / corruption.
///
/// Forward-incompatible rubric (any one of these requires a bump):
///   1. New record type added to `CloudKit/schema.ckdb`.
///   2. New non-defaulted field on a synced record type, where an older
///      build's nil decode would mis-classify the record.
///   3. New case added to a `// SyncBoundary —` marked enum where older
///      builds have a defensive fallback (e.g. unknown AccountType → .asset).
///   4. New CKSyncEngine zone introduced.
///   5. Any change explicitly tagged "forward-incompatible" in its PR
///      description / commit message.
///   6. A field on a synced record type marked `// DEPRECATED` in
///      `schema.ckdb` (the wire-struct generator drops it; older builds
///      still write it). The rename is the trigger; the bump fences off
///      the "deprecated field is suddenly invisible" race.
///
/// History (newest first):
/// - 7: CryptoCompare provider removal. The `cryptocompareSymbol` field
///      on `InstrumentRecord` is marked `// DEPRECATED` in `schema.ckdb`
///      (the wire-struct generator drops it; older builds still write
///      it). The deprecation race over the dropped field is rubric item
///      6; the bump fences it off from this build forward. The
///      `cryptocompare_symbol` GRDB column is also dropped (local-only,
///      no rubric item).
/// - 6: insight dismissals. Adds the synced `InsightDismissalRecord` type
///      (one tally per `InsightKind`). Older builds don't know the record
///      type and would silently discard downloaded dismissal records, losing
///      fatigue state cross-device; the bump fences older builds off from
///      profiles written by v6+.
/// - (no bump) 2026-05-17: `WalletSyncError` gained a `provider` field and
///   changed from a bare enum to a struct. `WalletSyncState` is per-device
///   and never synced cross-device; legacy rows decode via a bare-enum
///   compatibility path in `WalletSyncError`'s custom `Codable`. No rubric
///   item (1–6) applies — recorded here so the absence of a bump is a
///   documented decision, not an oversight.
/// - 5: account groups. Adds the synced `AccountGroupRecord` and a
///      `groupId` field on `AccountRecord` (back-reference into
///      `AccountGroup.id`). Older builds don't know about the new
///      record type (rubric item 1) and would strip `groupId` from
///      `Account` round-trips (rubric item 2 — that re-upload would
///      corrupt membership on other devices once cross-device sync
///      ships). The bump fences both downgrades off from this build
///      forward. `AccountGroup` records themselves are local-only in
///      this build — sync wiring (upload / download / apply-batch
///      dispatch) is added in a follow-up.
/// - 4: transfer-suggestion reshape. Adds the synced
///      `TransferSuggestionRecord` (a content-addressed pair of
///      transaction ids) as the canonical source of a detected
///      transfer suggestion, and deprecates the old model: the
///      legacy dismissed-transfer-pair record type and the two
///      denormalised suggestion fields on the transaction record are
///      not read or written (the wire-struct generator drops
///      them via `// DEPRECATED` in `schema.ckdb`; older builds still
///      write them). A new record type added to `schema.ckdb` is rubric
///      item 1; the deprecation race over the dropped fields is
///      rubric item 6. The bump fences both off from this build
///      forward.
/// - 3: `importOriginKind` + eight `importOriginIncoming*` + two
///      `transferSuggestion*` fields on `TransactionRecord`.
///      `importOriginKind` is nil on pre-v3 records, so an older
///      build decodes a `.merged` transaction as `.single` and
///      drops the incoming side — forward-incompatible. Also adds
///      a synced dismissed-transfer-pair record (deprecated in v4).
/// - 2: `AccountType.exchange` (centralised-exchange accounts) +
///      `Account.exchangeProvider` synced field (`exchangeProvider` on
///      `AccountRecord`). Older builds decode `.exchange` as `.asset`
///      (defensive fallback) and drop the provider on round-trip; the
///      bump fences those downgrades off from this build forward.
/// - 1: gate introduced alongside the crypto-wallet foundation.
///      `AccountType.crypto`, `Account.walletAddress` and `chainId`,
///      `TransactionLeg.externalId`, `WalletSyncState`. Older builds
///      (which also predate the gate) decode `AccountType.crypto` as
///      `.asset` and lose chain metadata on round-trip; the gate
///      protects future downgrades from this build forward.
///
/// `0` is the implicit pre-gate baseline: any profile that exists in the
/// cloud without a `dataFormatVersion` field reads as `0` and is
/// trivially compatible with any v1+ build.
enum DataFormatVersion {
  static let current: Int = 7
}
