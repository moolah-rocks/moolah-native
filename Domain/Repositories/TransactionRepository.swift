import Foundation

protocol TransactionRepository: Sendable {
  func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage
  /// Returns every matching transaction without pagination. Used by bulk
  /// consumers (profile export, profile import) where paginating forces the
  /// backend to re-filter and re-sort the whole dataset per page. Skips the
  /// prior-balance computation since it is not meaningful for the bulk path.
  func fetchAll(filter: TransactionFilter) async throws -> [Transaction]
  /// Reactive observation of a single page. Emits the current page once
  /// immediately, then re-emits whenever the underlying tables change in a
  /// way that affects the page or its `priorBalance` / `totalCount`. The
  /// `filter`, `page`, and `pageSize` are captured into the GRDB tracking
  /// closure — changing any of them requires cancelling the prior
  /// subscription and starting a new one with the new values.
  ///
  /// Errors are surfaced out-of-band on `observeErrors()`.
  func observe(
    filter: TransactionFilter, page: Int, pageSize: Int
  ) -> AsyncStream<TransactionPage>
  /// Reactive observation of the bulk projection. Emits every matching
  /// transaction once immediately, then re-emits on any underlying-table
  /// change that produces a different snapshot. `removeDuplicates()`
  /// (applied inside the retry helper) coalesces re-fetches that produce
  /// the same `[Transaction]` value.
  ///
  /// Used by consumers that already process the full filtered set and
  /// want a single live projection (e.g. small whole-account feeds, the
  /// scheduled-transactions card). Bulk paginated views should prefer
  /// `observe(filter:page:pageSize:)` so the observation cost scales
  /// with the page, not the dataset.
  func observeAll(filter: TransactionFilter) -> AsyncStream<[Transaction]>
  /// Companion error stream for `observe(...)` and `observeAll(...)`.
  /// A healthy observation stays quiet here for its lifetime; a
  /// programmer-bug or non-recoverable I/O error from the underlying
  /// observation is yielded once and then the stream completes. Stores
  /// typically surface this to a banner / log path.
  func observeErrors() -> AsyncStream<any Error>
  func create(_ transaction: Transaction) async throws -> Transaction
  /// Atomic bulk insert. Inserts every transaction (with its legs) inside
  /// a single write transaction; on any failure none of the transactions
  /// persist. Returns the inserted transactions in input order. Change /
  /// instrument hooks fire once per inserted row after the write commits,
  /// matching the per-row fan-out of `create(_:)`. Used by the CSV import
  /// pipeline so a half-written session can never be left on disk.
  func createMany(_ transactions: [Transaction]) async throws -> [Transaction]
  func update(_ transaction: Transaction) async throws -> Transaction
  func delete(id: UUID) async throws
  /// Atomically deletes every transaction in `deletingIds` (header + its
  /// legs) and inserts every transaction in `creating` (header + its
  /// legs) inside a single write transaction. On any failure none of the
  /// deletes or inserts persist. Returns the created transactions in
  /// input order. Change / instrument hooks fire once per deleted and
  /// per created row after the write commits, matching the per-row
  /// fan-out of `delete(id:)` / `createMany(_:)`. Used by transfer
  /// merge (delete two sources, create one merged transfer) and unmerge
  /// (delete the merged transfer, create two split sides) so a partially
  /// applied collapse can never be left on disk. A missing id in
  /// `deletingIds` throws `BackendError.notFound` and rolls the whole
  /// write back.
  func replace(deletingIds: [UUID], creating: [Transaction]) async throws -> [Transaction]
  /// Frequency-sorted payee strings beginning with `prefix`. When
  /// `excludingTransactionId` is supplied, the matching transaction does
  /// not contribute to the frequency count and its payee will not appear
  /// in the result if no other transaction shares it. Unknown ids — and
  /// unsaved drafts — leave the unfiltered list intact.
  func fetchPayeeSuggestions(prefix: String, excludingTransactionId: UUID?) async throws
    -> [String]
  /// Returns every persisted leg whose `external_id` equals `externalId`.
  /// Used by the wallet importer's cross-account merge pass to pair an
  /// in-batch candidate against legs already persisted on a prior cycle
  /// (so the same on-chain hash arriving via two accounts on different
  /// devices still merges into one transaction).
  ///
  /// Domain return type — the leg's instrument is resolved during the
  /// fetch the same way `fetch(filter:…)` and `fetchAll(filter:)` resolve
  /// it. The schema's partial unique index on
  /// `(account_id, external_id)` keeps this lookup cheap.
  func legs(matchingExternalId externalId: String) async throws -> [TransactionLeg]
  /// Returns every transaction that has at least one leg whose
  /// `external_id` matches any value in `externalIds`, with full leg
  /// payloads loaded. Used by `CrossDeviceLegDeduper` to scope its post-
  /// CKSyncEngine sweep to transactions that the just-applied fetch could
  /// have touched — the deduper needs each leg's parent `Transaction.id`
  /// to know which row to route through `delete(id:)`. Empty input
  /// returns an empty result without hitting the database. The schema's
  /// partial unique index `leg_dedup_by_account_external` covers the
  /// underlying leg-side `IN` predicate, so even thousand-id sweeps stay
  /// cheap.
  func transactions(touchingExternalIds externalIds: Set<String>) async throws
    -> [Transaction]
  /// `true` iff the wallet importer has already persisted a leg keyed by
  /// `(accountId, externalId)`. Used by the per-leg dedup step of the
  /// apply pass — re-fetches that span the reorg window cover already-
  /// imported transactions, so each leg is checked against the partial
  /// unique index before insertion.
  func legExists(accountId: UUID, externalId: String) async throws -> Bool
  /// Distinct instrument ids appearing on any persisted transaction leg.
  /// Used only by exchange-import resolution's rare registry-fallback
  /// tie-break; cheap (`SELECT DISTINCT`), not on a hot path.
  func distinctLegInstrumentIds() async throws -> Set<String>
  /// Count of posted (non-scheduled) transactions whose every leg is
  /// uncategorised (`Transaction.needsReview`). A SQL `COUNT` — never
  /// materialises history. Drives the categorise-backlog insight nudge.
  func countNeedsReview() async throws -> Int
}

extension TransactionRepository {
  /// Convenience overload with `excludingTransactionId` defaulting to
  /// `nil`. Returns the unfiltered frequency-sorted prefix matches.
  func fetchPayeeSuggestions(prefix: String) async throws -> [String] {
    try await fetchPayeeSuggestions(prefix: prefix, excludingTransactionId: nil)
  }
}
