import Foundation
import OSLog
import Observation

/// Owns every cross-account transfer-detection action: scanning a
/// newly-imported batch for fuzzy counterpart pairs and writing a
/// `TransferSuggestion` record per pair, collapsing a suggested or
/// user-asserted pair into one merged two-leg transfer, reversing that
/// collapse, and dismissing a pair. Dismiss, merge, and manual-merge
/// delete the pair's `TransferSuggestion` record; unmerge does not —
/// the suggestion was already deleted by the merge it reverses. Views
/// bind state and dispatch; all logic lives here (thin-view discipline,
/// `CLAUDE.md`).
///
/// State (`error`, `isMutating`) is `private(set)` and observed by
/// views. Errors are caught here and surfaced via `error`; typed
/// `ManualMergeError` / `TransferMergeError` values flow through the
/// same untyped `error` channel.
@MainActor
@Observable
final class TransferDetectionCoordinator {
  /// Last failure from any coordinator action, or `nil` after a
  /// successful one. `ManualMergeError` / `TransferMergeError` /
  /// repository errors all surface here.
  private(set) var error: (any Error)?
  /// `true` while a `runDetection` / `merge` / `manualMerge` /
  /// `unmerge` / `dismiss` write is in flight. A second
  /// detection-or-mutation call observed while this is `true` is
  /// rejected with `TransferMergeError.mutationInProgress` rather than
  /// queued — the action surface is one-at-a-time.
  private(set) var isMutating = false

  private let transactions: any TransactionRepository
  private let suggestions: any TransferSuggestionRepository
  private let detector: FuzzyTransferDetector
  private let builder: TransferMergeBuilder
  private let clock: @Sendable () -> Date

  private let logger = Logger(
    subsystem: "com.moolah.app", category: "TransferDetectionCoordinator")

  init(
    transactions: any TransactionRepository,
    suggestions: any TransferSuggestionRepository,
    detector: FuzzyTransferDetector = .init(),
    builder: TransferMergeBuilder = .init(),
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transactions = transactions
    self.suggestions = suggestions
    self.detector = detector
    self.builder = builder
    self.clock = clock
  }

  /// Scans `newlyImported` against transactions on *other* accounts
  /// dated at or after `windowLowerBound`, and writes one
  /// `TransferSuggestion` record (content-addressed from the unordered
  /// pair, stamped with `clock()`) per detected pair.
  ///
  /// `participatingAccountIds` are the accounts the import touched; an
  /// existing transaction is a counterpart candidate only when none of
  /// its legs sit on one of those accounts (a same-account "pair" is
  /// never a cross-account transfer). The caller supplies the window
  /// lower bound (the importer knows the earliest imported date).
  ///
  /// `TransactionFilter` cannot express "exclude this set of accounts"
  /// nor an open-ended lower bound, so the date floor is applied via a
  /// `windowLowerBound ... .distantFuture` range and the account
  /// exclusion is done in-memory here over that minimal superset.
  ///
  /// Idempotent: re-running over an already-suggested pair re-creates a
  /// record with the same content-addressed id, which the repository
  /// upserts — no duplicate rows.
  ///
  /// A detection pass writes records across awaits, so it shares the
  /// one-at-a-time gate with the mutating actions: a pass observed while
  /// any detection or mutation is in flight is rejected with
  /// `TransferMergeError.mutationInProgress` rather than queued.
  func runDetection(
    newlyImported: [Transaction],
    participatingAccountIds: Set<UUID>,
    windowLowerBound: Date
  ) async {
    await mutate {
      let dateFloor = TransactionFilter(
        dateRange: windowLowerBound...Date.distantFuture)
      let candidatesInWindow = try await self.transactions.fetchAll(
        filter: dateFloor)
      let newlyImportedIds = Set(newlyImported.map(\.id))
      let existingNearby = candidatesInWindow.filter { transaction in
        !newlyImportedIds.contains(transaction.id)
          && transaction.accountIds.isDisjoint(with: participatingAccountIds)
      }

      let pairs = self.detector.detect(
        newlyImported: newlyImported,
        existingNearby: existingNearby)

      let stamp = self.clock()
      for pair in pairs {
        _ = try await self.suggestions.create(
          TransferSuggestion(
            transactionIds: [pair.newlyImported.id, pair.existingCounterpart.id],
            suggestedAt: stamp))
      }
    }
  }

  /// Collapses an auto-detected pair into one merged two-`.transfer`-leg
  /// transaction, deleting both single-account sources in the same
  /// atomic write. Re-entrancy is rejected, not queued. The atomicity
  /// covers the `transactions.replace` only; `suggestions.delete` is a
  /// separate best-effort follow-on write — a process stop between the
  /// two leaves an orphan `TransferSuggestion` row whose transaction ids
  /// both point at deleted records, making it invisible to any
  /// transaction-id-keyed query and harmless.
  func merge(_ sideA: Transaction, _ sideB: Transaction) async {
    await mutate {
      let merged = try self.builder.merged(from: sideA, sideB)
      _ = try await self.transactions.replace(
        deletingIds: [sideA.id, sideB.id], creating: [merged])
      try await self.suggestions.delete(
        id: TransferSuggestion.contentAddressedID(for: [sideA.id, sideB.id]))
    }
  }

  /// User-asserted merge over a looser ±14-day window. Validates the
  /// pair (different accounts, opposite-equal value legs in the same
  /// instrument, dates within `TransferMergeBuilder.manualMergeWindowSeconds`)
  /// throwing the matching `ManualMergeError` *before* delegating leg
  /// construction to `builder.merged`. The merged transfer replaces
  /// both sources in one atomic write. The atomicity covers the
  /// `transactions.replace` only; `suggestions.delete` is a separate
  /// best-effort follow-on write — a process stop between the two
  /// leaves an orphan `TransferSuggestion` row whose transaction ids
  /// both point at deleted records, making it invisible to any
  /// transaction-id-keyed query and harmless.
  func manualMerge(_ sideA: Transaction, _ sideB: Transaction) async {
    await mutate {
      try self.validateManualMerge(sideA, sideB)
      let merged = try self.builder.merged(from: sideA, sideB)
      _ = try await self.transactions.replace(
        deletingIds: [sideA.id, sideB.id], creating: [merged])
      try await self.suggestions.delete(
        id: TransferSuggestion.contentAddressedID(for: [sideA.id, sideB.id]))
    }
  }

  /// Reverses a merge: splits `transfer` back into its two single-value
  /// sides. No tombstone is needed — the split products are not "newly
  /// imported", so a later detection pass never re-evaluates them and
  /// cannot re-suggest the pair the user just chose to separate.
  func unmerge(_ transfer: Transaction) async {
    await mutate {
      let splits = try self.builder.split(transfer)
      _ = try await self.transactions.replace(
        deletingIds: [transfer.id], creating: splits)
    }
  }

  /// Records a user "these are NOT a transfer" assertion by deleting the
  /// `TransferSuggestion` record over the two transactions so the
  /// suggestion UI no longer surfaces the pair.
  func dismiss(_ sideA: Transaction, _ sideB: Transaction) async {
    await mutate {
      try await self.suggestions.delete(
        id: TransferSuggestion.contentAddressedID(for: [sideA.id, sideB.id]))
    }
  }

}

extension TransferDetectionCoordinator {
  nonisolated private func validateManualMerge(
    _ sideA: Transaction,
    _ sideB: Transaction
  ) throws {
    guard
      let legA = sideA.transferDetectionValueLeg,
      let legB = sideB.transferDetectionValueLeg,
      let accountA = legA.accountId,
      let accountB = legB.accountId
    else { throw ManualMergeError.notOppositeAmount }
    guard accountA != accountB else { throw ManualMergeError.sameAccount }
    guard
      legA.instrument == legB.instrument,
      legA.quantity == -legB.quantity
    else { throw ManualMergeError.notOppositeAmount }
    let gap = abs(sideA.date.timeIntervalSince(sideB.date))
    guard gap <= TransferMergeBuilder.manualMergeWindowSeconds else {
      throw ManualMergeError.datesTooFarApart
    }
  }

  /// Runs `body` under the one-at-a-time mutation guard. A call observed
  /// while another mutation is in flight is rejected immediately by
  /// setting `error = TransferMergeError.mutationInProgress` and
  /// returning — the second call is *not* queued behind the first. The
  /// `isMutating` check-and-set runs synchronously before the first
  /// `await`, and the MainActor serialises synchronous code, so two
  /// overlapping calls can never both pass the guard.
  private func mutate(_ body: @Sendable () async throws -> Void) async {
    guard !isMutating else {
      error = TransferMergeError.mutationInProgress
      return
    }
    isMutating = true
    error = nil
    defer { isMutating = false }
    do {
      try await body()
    } catch {
      logger.error("Transfer mutation failed: \(error.localizedDescription)")
      self.error = error
    }
  }
}
