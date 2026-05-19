import Foundation

// Transfer-suggestion orchestration for the transaction-detail surface.
//
// A suggested transfer is a synced `TransferSuggestion` record over an
// unordered pair of transaction ids; the detail surface has no loaded
// transaction set to look the counterpart up in. These methods resolve
// the suggestion (and its counterpart) through the
// `TransferSuggestionRepository` and delegate the actual collapse /
// dismissal to `TransferDetectionCoordinator`, so the suggestion
// section stays a thin renderer dispatching one-line
// `Task { await transactionStore.mergeSuggestedTransfer(...) }` calls.
extension TransactionStore {

  /// Collapses the suggested pair into one merged two-leg transfer.
  /// Resolves the suggested counterpart through the
  /// `TransferSuggestion` record (never the denormalised model) and
  /// hands both sides to the coordinator. A no-op when the store has no
  /// coordinator wired, no suggestion record touches the transaction,
  /// or the counterpart row can no longer be found. The coordinator
  /// surfaces any failure on its own `error` channel.
  func mergeSuggestedTransfer(_ transaction: Transaction) async {
    guard let coordinator = transferDetection else { return }
    do {
      guard let counterpart = try await suggestedCounterpart(of: transaction)
      else { return }
      await coordinator.merge(transaction, counterpart)
    } catch {
      logger.error(
        "Failed to resolve transfer counterpart: \(error.localizedDescription)")
      setError(error)
    }
  }

  /// Records a "not a transfer" dismissal over the suggested pair and
  /// clears the suggestion annotation on both sides. Same guards and
  /// no-op semantics as `mergeSuggestedTransfer(_:)`.
  func dismissSuggestedTransfer(_ transaction: Transaction) async {
    guard let coordinator = transferDetection else { return }
    do {
      guard let counterpart = try await suggestedCounterpart(of: transaction)
      else { return }
      await coordinator.dismiss(transaction, counterpart)
    } catch {
      logger.error(
        "Failed to resolve transfer counterpart: \(error.localizedDescription)")
      setError(error)
    }
  }

  /// Collapses two user-selected transactions into one merged two-leg
  /// transfer over the looser ±14-day manual-merge window. The
  /// coordinator performs its own validation (different accounts,
  /// opposite-equal value legs in the same instrument, dates within
  /// `TransferMergeBuilder.manualMergeWindowSeconds`) and records any
  /// `ManualMergeError` on its own `error` channel without mutating —
  /// so this is a thin pass-through with no try/catch. A no-op when no
  /// coordinator is wired (previews / legacy tests).
  func manualMerge(_ sideA: Transaction, _ sideB: Transaction) async {
    guard let coordinator = transferDetection else { return }
    await coordinator.manualMerge(sideA, sideB)
  }

  /// Splits a merged transfer back into its two original single-account
  /// sides and records a dismissal so the next detection scan does not
  /// immediately re-suggest the pair. The coordinator owns error state;
  /// this is a thin pass-through. A no-op when no coordinator is wired.
  func unmerge(_ transfer: Transaction) async {
    guard let coordinator = transferDetection else { return }
    await coordinator.unmerge(transfer)
  }

  /// Whether a `TransferSuggestion` record currently touches
  /// `transaction`. The transaction-detail banner observes this to
  /// decide whether to render the merge / dismiss section via a
  /// synced-record read. `false` when no suggestion repository is
  /// wired (previews / legacy tests) or the lookup fails.
  func hasSuggestion(for transaction: Transaction) async -> Bool {
    guard let transferSuggestions else { return false }
    do {
      return try await
        !transferSuggestions
        .suggestions(touching: transaction.id).isEmpty
    } catch {
      logger.error(
        "Failed to resolve transfer suggestion: \(error.localizedDescription)")
      return false
    }
  }

  /// Loads the counterpart `Transaction` of a suggested pair. Resolves
  /// the counterpart id from the `TransferSuggestion` record touching
  /// `transaction` (never the denormalised model), then fetches that
  /// transaction. The repository exposes no fetch-by-id, so the second
  /// step scans the unfiltered projection and matches on id —
  /// acceptable because merge / dismiss are deliberate, infrequent user
  /// actions on the detail surface, not a hot path. Returns `nil` when
  /// no suggestion repository is wired, no suggestion record touches
  /// the transaction, or the counterpart row is gone (already merged /
  /// deleted on another device).
  private func suggestedCounterpart(
    of transaction: Transaction
  ) async throws -> Transaction? {
    guard let transferSuggestions else { return nil }
    let touching = try await transferSuggestions.suggestions(
      touching: transaction.id)
    guard let counterpartId = touching.first?.counterpart(of: transaction.id)
    else { return nil }
    let all = try await repository.fetchAll(filter: TransactionFilter())
    return all.first { $0.id == counterpartId }
  }
}
