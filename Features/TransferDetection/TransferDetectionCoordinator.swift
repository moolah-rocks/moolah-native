import Foundation
import OSLog
import Observation

/// Owns every cross-account transfer-detection action: scanning a
/// newly-imported batch for fuzzy counterpart pairs and annotating both
/// sides, collapsing a suggested or user-asserted pair into one merged
/// two-leg transfer, reversing that collapse, and recording a "not a
/// transfer" dismissal. Views bind state and dispatch; all logic lives
/// here (thin-view discipline, `CLAUDE.md`).
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
  private let dismissedPairs: any DismissedTransferPairRepository
  private let detector: FuzzyTransferDetector
  private let builder: TransferMergeBuilder
  private let clock: @Sendable () -> Date

  private let logger = Logger(
    subsystem: "com.moolah.app", category: "TransferDetectionCoordinator")

  init(
    transactions: any TransactionRepository,
    dismissedPairs: any DismissedTransferPairRepository,
    detector: FuzzyTransferDetector = .init(),
    builder: TransferMergeBuilder = .init(),
    clock: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.transactions = transactions
    self.dismissedPairs = dismissedPairs
    self.detector = detector
    self.builder = builder
    self.clock = clock
  }

  /// Scans `newlyImported` against transactions on *other* accounts
  /// dated at or after `windowLowerBound`, and writes a
  /// `TransferSuggestion` (pointing at the counterpart, stamped with
  /// `clock()`) onto **both** transactions of every detected pair.
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
  /// Idempotent: re-running over an already-suggested pair rewrites the
  /// same annotation (same counterpart id; `suggestedAt` re-stamped) —
  /// no duplicate rows, no second pairing because both sides already
  /// carry the suggestion and the detector re-pairs them identically.
  ///
  /// A detection pass writes annotations across awaits, so it shares the
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

      let dismissedIds = Set(try await self.dismissedPairs.fetchAll().map(\.id))
      let isDismissed: @Sendable (UUID, UUID) -> Bool = { first, second in
        dismissedIds.contains(
          DismissedTransferPair.contentAddressedID(for: [first, second]))
      }

      let pairs = self.detector.detect(
        newlyImported: newlyImported,
        existingNearby: existingNearby,
        isDismissed: isDismissed)

      let stamp = self.clock()
      for pair in pairs {
        try await self.annotate(
          pair.newlyImported,
          counterpart: pair.existingCounterpart.id,
          at: stamp)
        try await self.annotate(
          pair.existingCounterpart,
          counterpart: pair.newlyImported.id,
          at: stamp)
      }
    }
  }

  /// Collapses an auto-detected pair into one merged two-`.transfer`-leg
  /// transaction, deleting both single-account sources in the same
  /// atomic write. Re-entrancy is rejected, not queued.
  func merge(_ sideA: Transaction, _ sideB: Transaction) async {
    await mutate {
      let merged = try self.builder.merged(from: sideA, sideB)
      _ = try await self.transactions.replace(
        deletingIds: [sideA.id, sideB.id], creating: [merged])
    }
  }

  /// User-asserted merge over a looser ±14-day window. Validates the
  /// pair (different accounts, opposite-equal value legs in the same
  /// instrument, dates within `TransferMergeBuilder.manualMergeWindowSeconds`)
  /// throwing the matching `ManualMergeError` *before* delegating leg
  /// construction to `builder.merged`. The merged transfer replaces
  /// both sources in one atomic write.
  func manualMerge(_ sideA: Transaction, _ sideB: Transaction) async {
    await mutate {
      try self.validateManualMerge(sideA, sideB)
      let merged = try self.builder.merged(from: sideA, sideB)
      _ = try await self.transactions.replace(
        deletingIds: [sideA.id, sideB.id], creating: [merged])
    }
  }

  /// Reverses a merge: splits `transfer` back into its two single-value
  /// sides and records a `DismissedTransferPair` over them so the very
  /// next detection scan does not immediately re-suggest the pair the
  /// user just chose to separate.
  ///
  /// Atomicity scope: the `replace` call is a single `transaction`-table
  /// write (delete the merged tx, create the two splits) and is fully
  /// atomic. The follow-on `DismissedTransferPair` write is a separate
  /// table on a separate repository, so it lands *after* the split
  /// commits and is best-effort. This is not a data-loss path: if the
  /// process stops between the split and the dismissal the splits are
  /// already durably persisted; the only consequence is that a later
  /// scan re-suggests the just-split pair, which the user dismisses
  /// again. The split itself never rolls back the dismissal and the
  /// dismissal never affects the split.
  func unmerge(_ transfer: Transaction) async {
    await mutate {
      let splits = try self.builder.split(transfer)
      let created = try await self.transactions.replace(
        deletingIds: [transfer.id], creating: splits)
      let pair = DismissedTransferPair(
        transactionIds: [created[0].id, created[1].id],
        dismissedAt: self.clock())
      _ = try await self.dismissedPairs.create(pair)
    }
  }

  /// Records a user "these are NOT a transfer" assertion over the two
  /// transactions and clears the `transferSuggestion` annotation on
  /// both so the suggestion UI no longer surfaces the pair.
  func dismiss(_ sideA: Transaction, _ sideB: Transaction) async {
    await mutate {
      let pair = DismissedTransferPair(
        transactionIds: [sideA.id, sideB.id],
        dismissedAt: self.clock())
      _ = try await self.dismissedPairs.create(pair)
      try await self.clearSuggestion(sideA)
      try await self.clearSuggestion(sideB)
    }
  }

}

extension TransferDetectionCoordinator {
  /// Writes the `transferSuggestion` header onto `transaction` via the
  /// general-purpose `transactions.update`, which re-queues each of the
  /// transaction's legs to sync even though only the header changes. The
  /// write is idempotent and correct; the redundant leg re-queue is a
  /// known sync-queue inefficiency tracked in issue #937
  /// (https://github.com/ajsutton/moolah-native/issues/937).
  private func annotate(
    _ transaction: Transaction,
    counterpart: UUID,
    at stamp: Date
  ) async throws {
    var annotated = transaction
    annotated.transferSuggestion = TransferSuggestion(
      counterpartTransactionId: counterpart,
      suggestedAt: stamp)
    _ = try await transactions.update(annotated)
  }

  private func clearSuggestion(_ transaction: Transaction) async throws {
    guard transaction.transferSuggestion != nil else { return }
    var cleared = transaction
    cleared.transferSuggestion = nil
    _ = try await transactions.update(cleared)
  }

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
