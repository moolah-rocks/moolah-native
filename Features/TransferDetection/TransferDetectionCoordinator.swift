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

  // MARK: - Detection

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
    _ = await mutate {
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

  // MARK: - Merge

  /// Collapses an auto-detected pair into one merged two-`.transfer`-leg
  /// transaction, deleting both single-account sources in the same
  /// atomic write. Re-entrancy is rejected, not queued. The atomicity
  /// covers the `transactions.replace` only; `suggestions.delete` is a
  /// separate best-effort follow-on write — a process stop between the
  /// two leaves an orphan `TransferSuggestion` row whose transaction ids
  /// both point at deleted records, making it invisible to any
  /// transaction-id-keyed query and harmless.
  func merge(_ sideA: Transaction, _ sideB: Transaction) async {
    _ = await mutate {
      let merged = try self.builder.merged(from: sideA, sideB)
      try await self.persistMerge(deleting: sideA, sideB, into: merged)
    }
  }

  /// Auto-merges CERTAIN same-`externalId` cross-account transfer pairs
  /// that are BOTH within `newlyPersisted` (same-cycle) into one two-
  /// `.transfer`-leg transfer each. Returns `newlyPersisted` with each
  /// merged pair replaced by its single merged transfer (unpaired entries
  /// unchanged), so a subsequent fuzzy `runDetection` never re-suggests
  /// them. Certainty = the value legs satisfy the shared
  /// `LiveCrossAccountTransferMerger.isPair` predicate (a shared on-chain
  /// `externalId`, opposing equal-magnitude legs in the same instrument on
  /// different accounts) — never a fuzzy heuristic.
  ///
  /// Restores the single-shot apply path's build-time cross-account
  /// auto-merge for the windowed path, where the two sides land in
  /// separate per-account-per-window applies and so never share one
  /// `CrossAccountTransferMerger` batch. Only same-cycle pairs are merged:
  /// a mate persisted in a PRIOR cycle is out of scope and left for the
  /// fuzzy pass, exactly as before.
  ///
  /// Deterministic: pairs are formed by sorting on transaction id and
  /// greedily matching, and each transaction is consumed by at most one
  /// merge, so replays over the same set converge. Idempotent: an
  /// already-merged transfer carries two `.transfer` legs → a nil
  /// `transferDetectionValueLeg` → it is never re-paired.
  ///
  /// The whole batch runs under the one-at-a-time `mutate` gate as a
  /// SINGLE atomic `transactions.replace` covering EVERY pair — all pairs
  /// collapse or none do, so there is no partial-write state. The
  /// suggestion sweep is a best-effort follow-on (per-pair, logged on
  /// failure) that never fails the batch: once the atomic replace has
  /// committed the merges, the reduced set must be returned so it matches
  /// the persisted truth. The return is gated on `mutate`'s outcome (NOT a
  /// post-`await` `error` read, which a concurrent rejected call could
  /// clobber): if the batch is rejected (a mutation already in flight) or
  /// the replace throws, nothing is written and the ORIGINAL set is
  /// returned unchanged, so the still-separate rows fall through to the
  /// fuzzy pass rather than being dropped on a phantom merge.
  func mergeCertainSameCycleTransfers(
    among newlyPersisted: [Transaction]
  ) async -> [Transaction] {
    let pairs = Self.certainSameCyclePairs(among: newlyPersisted)
    // Build each merged transfer once, up front, so the row persisted by
    // `replace` and the row returned to the caller share one identity (a
    // fresh `merged(from:)` would mint a new id per call).
    var built: [PlannedMerge] = []
    built.reserveCapacity(pairs.count)
    for pair in pairs {
      do {
        built.append(
          PlannedMerge(
            sideA: pair.a, sideB: pair.b, merged: try builder.merged(from: pair.a, pair.b)))
      } catch {
        // `certainSameCyclePairs` already proved the pair mergeable via the
        // shared `isPair` predicate, so this is unreachable unless that
        // predicate and `builder.merged`'s precondition ever drift — log
        // rather than swallow, and leave the pair for the fuzzy pass.
        logger.error(
          "Certain same-cycle pair failed the merge-builder precondition; leaving it for the fuzzy pass: \(error.localizedDescription)"
        )
      }
    }
    let plan = built
    guard !plan.isEmpty else { return newlyPersisted }

    let succeeded = await mutate {
      // One atomic write for the whole batch: every pair's two sources are
      // deleted and its merged transfer created together, so a throw rolls
      // back all pairs (no partial-merge state ever surfaces).
      _ = try await self.transactions.replace(
        deletingIds: plan.flatMap { [$0.sideA.id, $0.sideB.id] },
        creating: plan.map(\.merged))
      // Best-effort suggestion sweep — the merges are already committed, so a
      // delete failure must not fail the batch (that would return the stale
      // pre-merge set for rows that no longer exist). Log and continue.
      for entry in plan {
        do {
          try await self.suggestions.delete(
            id: TransferSuggestion.contentAddressedID(for: [entry.sideA.id, entry.sideB.id]))
        } catch {
          self.logger.error(
            "Same-cycle merge suggestion sweep failed for pair; leaving orphan suggestion: \(error.localizedDescription)"
          )
        }
      }
    }
    guard succeeded else { return newlyPersisted }

    let consumed = Set(plan.flatMap { [$0.sideA.id, $0.sideB.id] })
    var reduced = newlyPersisted.filter { !consumed.contains($0.id) }
    reduced.append(contentsOf: plan.map(\.merged))
    return reduced
  }

  /// One planned same-cycle collapse: the two source transactions and the
  /// pre-built merged transfer that will replace them. Built before the
  /// `mutate` write so the persisted row and the returned row share identity.
  private struct PlannedMerge {
    let sideA: Transaction
    let sideB: Transaction
    let merged: Transaction
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
    _ = await mutate {
      try self.validateManualMerge(sideA, sideB)
      let merged = try self.builder.merged(from: sideA, sideB)
      try await self.persistMerge(deleting: sideA, sideB, into: merged)
    }
  }

  /// Reverses a merge: splits `transfer` back into its two single-value
  /// sides. No tombstone is needed — the split products are not "newly
  /// imported", so a later detection pass never re-evaluates them and
  /// cannot re-suggest the pair the user just chose to separate.
  func unmerge(_ transfer: Transaction) async {
    _ = await mutate {
      let splits = try self.builder.split(transfer)
      _ = try await self.transactions.replace(
        deletingIds: [transfer.id], creating: splits)
    }
  }

  /// Records a user "these are NOT a transfer" assertion by deleting the
  /// `TransferSuggestion` record over the two transactions so the
  /// suggestion UI no longer surfaces the pair.
  func dismiss(_ sideA: Transaction, _ sideB: Transaction) async {
    _ = await mutate {
      try await self.suggestions.delete(
        id: TransferSuggestion.contentAddressedID(for: [sideA.id, sideB.id]))
    }
  }

}

extension TransferDetectionCoordinator {
  // MARK: - Private helpers

  /// Shared atomic collapse body for the single-pair merge paths (`merge`
  /// and `manualMerge`): replaces both source transactions with the
  /// already-built `merged` transfer in one atomic write, then deletes the
  /// pair's `TransferSuggestion`. NOT self-guarded — callers invoke it
  /// inside `mutate`. (`mergeCertainSameCycleTransfers` does not use this:
  /// it issues ONE atomic replace across the whole batch instead of one per
  /// pair.) The atomicity covers the
  /// `transactions.replace` only; `suggestions.delete` is a best-effort
  /// follow-on (a process stop between the two leaves an orphan
  /// suggestion whose transaction ids both point at deleted records,
  /// invisible to any transaction-id-keyed query and harmless).
  private func persistMerge(
    deleting sideA: Transaction, _ sideB: Transaction, into merged: Transaction
  ) async throws {
    _ = try await transactions.replace(
      deletingIds: [sideA.id, sideB.id], creating: [merged])
    try await suggestions.delete(
      id: TransferSuggestion.contentAddressedID(for: [sideA.id, sideB.id]))
  }

  /// Selects the CERTAIN same-cycle cross-account transfer pairs within
  /// `newlyPersisted`. Only transactions with a single value-bearing leg
  /// (`transferDetectionValueLeg`) carrying a non-nil `externalId` are
  /// candidates; a pair is certain when the two legs satisfy
  /// `LiveCrossAccountTransferMerger.isPair` (shared `externalId`,
  /// opposing equal-magnitude quantities, same instrument, different
  /// accounts). Candidates are sorted by transaction id and matched
  /// greedily so pairing is deterministic across replays, and each
  /// transaction is consumed by at most one pair.
  nonisolated private static func certainSameCyclePairs(
    among newlyPersisted: [Transaction]
  ) -> [(a: Transaction, b: Transaction)] {
    let candidates =
      newlyPersisted
      .compactMap { transaction -> (transaction: Transaction, leg: TransactionLeg)? in
        guard let leg = transaction.transferDetectionValueLeg, leg.externalId != nil
        else { return nil }
        return (transaction, leg)
      }
      .sorted { $0.transaction.id.uuidString < $1.transaction.id.uuidString }

    var consumed: Set<Int> = []
    var pairs: [(a: Transaction, b: Transaction)] = []
    for i in candidates.indices where !consumed.contains(i) {
      for j in candidates.indices where j > i && !consumed.contains(j) {
        guard LiveCrossAccountTransferMerger.isPair(candidates[i].leg, candidates[j].leg)
        else { continue }
        consumed.insert(i)
        consumed.insert(j)
        pairs.append((candidates[i].transaction, candidates[j].transaction))
        break
      }
    }
    return pairs
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
  ///
  /// Returns `true` iff `body` ran to completion without throwing.
  /// Callers that branch program logic on the outcome (e.g.
  /// `mergeCertainSameCycleTransfers`, which returns a reduced set only
  /// when the write committed) MUST gate on this return value rather than
  /// reading the shared `error` property afterward: a concurrent rejected
  /// call can clobber `error` with `.mutationInProgress` while this call's
  /// body is suspended on an `await`, and the success path does not reset
  /// `error`, so a post-`await` `error == nil` read is racy. Deliberately
  /// NOT `@discardableResult` — the display-only call sites (`merge`,
  /// `manualMerge`, `unmerge`, `dismiss`, `runDetection`) must `_ =` the
  /// result to make ignoring the outcome a visible, reviewed choice.
  private func mutate(_ body: @Sendable () async throws -> Void) async -> Bool {
    guard !isMutating else {
      error = TransferMergeError.mutationInProgress
      return false
    }
    isMutating = true
    error = nil
    defer { isMutating = false }
    do {
      try await body()
      return true
    } catch {
      logger.error("Transfer mutation failed: \(error.localizedDescription)")
      self.error = error
      return false
    }
  }
}
