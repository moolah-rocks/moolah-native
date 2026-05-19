import Foundation

// Reactive transfer-suggestion observation for `TransactionStore`.
//
// A third observation surface alongside the per-filter data stream
// (`+Observation.swift`) and the rate-cache tick: the synced
// `TransferSuggestion` records. The transaction-detail banner derives
// its visibility from `hasSuggestion(for:)` (`+TransferDetection.swift`),
// a synchronous read of `suggestedTransactionIds`. This extension keeps
// that set in sync with `transferSuggestions.observeAll()`, so a
// dismiss / merge here — or a peer's dismissal arriving via
// CKSyncEngine — deletes the record, the stream emits the shrunk list,
// and the banner vanishes reactively with no `transaction.id` change.
//
// The owning `suggestionObservationTask` is spawned from `init` (only
// when a suggestion repository is wired) and torn down by
// `stopObserving()` / `deinit`, exactly like `rateObservationTask`.
extension TransactionStore {
  /// Spawns `suggestionObservationTask` when a suggestion repository
  /// is wired (no-op for previews / legacy tests). Called once from
  /// `init`. Strong `self` capture matches `rateObservationTask` —
  /// `stopObserving()` / `deinit` is the lifetime gate.
  func startSuggestionObservation() {
    guard let transferSuggestions else { return }
    suggestionObservationTask = Task { [self] in
      await self.observeSuggestionChannels(transferSuggestions)
    }
  }

  /// Subscribes to `transferSuggestions.observeAll()` /
  /// `…observeErrors()`. Each list emission rebuilds
  /// `suggestedTransactionIds` (the union of every live suggestion's
  /// `transactionIds`); an error tick is surfaced on `self.error`.
  /// Strong `self` capture matches `observeRateChannels()` — the
  /// task's lifetime is gated by `stopObserving()` / `deinit`.
  private func observeSuggestionChannels(
    _ suggestions: any TransferSuggestionRepository
  ) async {
    let stream = suggestions.observeAll()
    let errors = suggestions.observeErrors()
    await withTaskGroup(of: Void.self) { group in
      group.addTask { [self] in
        for await snapshot in stream {
          await self.applySuggestionSnapshot(snapshot)
        }
      }
      group.addTask { [self] in
        for await error in errors {
          await self.surface(observationError: error)
        }
      }
    }
  }

  /// Replaces `suggestedTransactionIds` with the union of every member
  /// id across `snapshot`. Runs on the `@MainActor`-isolated store so
  /// the `@Observable` write fires SwiftUI invalidation. A
  /// test-observation tick is yielded so suite tests can await the
  /// suggestion-set settling deterministically (the
  /// `waitForNextEmission(matching:)` idiom) rather than polling.
  private func applySuggestionSnapshot(_ snapshot: [TransferSuggestion]) {
    setSuggestedTransactionIds(Set(snapshot.flatMap(\.transactionIds)))
    testObservationTickContinuation.yield(())
  }
}
