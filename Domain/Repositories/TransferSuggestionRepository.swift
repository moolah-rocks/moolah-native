import Foundation

/// Persistence surface for detected transfer suggestions. Detection
/// upserts via `create`; dismiss / merge / unmerge `delete`. The UI
/// resolves the suggestion (if any) for a transaction via
/// `suggestions(touching:)`.
protocol TransferSuggestionRepository: Sendable {
  func fetchAll() async throws -> [TransferSuggestion]
  /// Reactive observation. Emits the full list once immediately, then
  /// on every `transfer_suggestion` table change. Backed by GRDB
  /// `ValueObservation` with `removeDuplicates()`. Cross-device
  /// convergence: a peer that detects/dismisses a pair uploads/deletes
  /// the record; CKSyncEngine applies it locally, firing this stream.
  func observeAll() -> AsyncStream<[TransferSuggestion]>
  /// Companion error stream — surface-then-finish (a healthy
  /// observation stays quiet; one non-recoverable error is yielded then
  /// the stream completes).
  func observeErrors() -> AsyncStream<any Error>
  func create(_ suggestion: TransferSuggestion) async throws -> TransferSuggestion
  func delete(id: UUID) async throws
  /// Every suggestion whose unordered transaction-id set includes
  /// `transactionId`. The UI read path + the dismiss/merge lookup.
  func suggestions(touching transactionId: UUID) async throws -> [TransferSuggestion]
}
