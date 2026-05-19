import Foundation

/// Persistence surface for detected transfer suggestions. Detection
/// upserts via `create`; dismiss / merge / unmerge `delete`. The UI
/// resolves the suggestion (if any) for a transaction via
/// `suggestions(touching:)`.
protocol TransferSuggestionRepository: Sendable {
  /// One-shot snapshot of all current suggestions. Distinct from the
  /// live `observeAll()` stream — use this for a single read.
  func fetchAll() async throws -> [TransferSuggestion]
  /// Reactive observation. Emits the full list once immediately, then
  /// on every `transfer_suggestion` table change (GRDB
  /// `ValueObservation` with `removeDuplicates()`). The stream itself is
  /// non-throwing, so a caller can `for await` it and never crash on a
  /// transient SQLite condition — errors are surfaced out-of-band on
  /// `observeErrors()`. Cross-device convergence: a peer that detects or
  /// dismisses a pair uploads/deletes the record; CKSyncEngine applies
  /// it locally, which fires this stream.
  func observeAll() -> AsyncStream<[TransferSuggestion]>
  /// Companion error stream for `observeAll()`. A healthy observation
  /// stays quiet for its lifetime; one non-recoverable error is yielded
  /// and then the stream completes. Stores typically surface this to a
  /// banner / log path.
  func observeErrors() -> AsyncStream<any Error>
  func create(_ suggestion: TransferSuggestion) async throws -> TransferSuggestion
  func delete(id: UUID) async throws
  /// Every suggestion whose unordered transaction-id set includes
  /// `transactionId`. The UI read path + the dismiss/merge lookup.
  func suggestions(touching transactionId: UUID) async throws -> [TransferSuggestion]
}
