// Shared/CryptoImport/WalletApplyEngine.swift
import Foundation
import os

/// Sequential `@MainActor` apply pass for the crypto-wallet importer.
/// Runs after Stage 6's parallel build phase. Owns: cross-account
/// merge, per-leg dedup, persistence, import rules, and per-account
/// `WalletSyncState` updates.
///
/// Order: merge → dedup → persist → rules → sync-state update. This is
/// the single writer in the build → apply pipeline; every other type
/// produces value-shaped data only.
///
/// Construction is `Sendable` despite `@MainActor` because every stored
/// property is itself a `Sendable` reference.
@MainActor
final class WalletApplyEngine {

  /// Per-account input to the apply pass. `SyncedAccountStore`
  /// builds one entry per account that completed its build pass
  /// successfully;
  /// failed accounts produce no entry and have their `lastError` set
  /// elsewhere.
  struct AccountInput: Sendable {
    let account: Account
    let headBlockNumber: UInt64
    let candidates: [BuiltTransaction]
  }

  private let transactions: any TransactionRepository
  private let walletSyncState: any WalletSyncStateRepository
  private let checkpoints: any WalletSyncCheckpointRepository
  private let importRules: any WalletImportRulesEngine
  private let merger: any CrossAccountTransferMerger
  private let clock: @Sendable () -> Date

  init(
    transactions: any TransactionRepository,
    walletSyncState: any WalletSyncStateRepository,
    checkpoints: any WalletSyncCheckpointRepository,
    importRules: any WalletImportRulesEngine,
    merger: any CrossAccountTransferMerger = LiveCrossAccountTransferMerger(),
    clock: @Sendable @escaping () -> Date = { Date() }
  ) {
    self.transactions = transactions
    self.walletSyncState = walletSyncState
    self.checkpoints = checkpoints
    self.importRules = importRules
    self.merger = merger
    self.clock = clock
  }

  /// Applies the build-phase output for a single sync cycle.
  ///
  /// Steps:
  /// 1. Cross-account merge — pair same-`externalId` opposing legs.
  /// 2. Per-leg dedup against persisted legs (drops legs already in the
  ///    repository; whole transactions drop when every leg is dropped).
  /// 3. Persist remaining transactions through `TransactionRepository`.
  /// 4. Run `WalletImportRulesEngine` over the persisted set.
  /// 5. Update `WalletSyncState` for every account that participated.
  ///
  /// Returns the transactions actually persisted (the merged-and-deduped
  /// survivors). Failed accounts that arrived with empty `candidates`
  /// still get their `WalletSyncState` updated so the next cycle's
  /// `fromBlock` advances.
  ///
  /// Throws on repository failure during merge / dedup / persist /
  /// sync-state. Stage 9's orchestrator owns per-account error
  /// containment; this method either succeeds or throws as a unit.
  func apply(perAccount: [AccountInput]) async throws -> [Transaction] {
    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "walletApplyEngine.apply",
      signpostID: signpostID,
      "%{public}d accounts",
      perAccount.count)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "walletApplyEngine.apply",
        signpostID: signpostID)
    }
    let allCandidates = perAccount.flatMap { $0.candidates }
    let lookup = makeExistingLegLookup()
    let merged = try await merger.merge(
      candidates: allCandidates, existingLegLookup: lookup)
    let deduped = try await runDedupSignposted(merged, signpostID: signpostID)
    let persisted = try await runPersistSignposted(deduped, signpostID: signpostID)
    let ruled = try await runRulesSignposted(persisted, signpostID: signpostID)
    try await updateSyncState(for: perAccount)
    return ruled
  }

  // MARK: - Signposted wrappers

  /// Wraps `dedup` in a `walletApplyEngine.dedup` signpost region. Kept
  /// out-of-line so the public `apply` body stays readable.
  private func runDedupSignposted(
    _ candidates: [BuiltTransaction],
    signpostID: OSSignpostID
  ) async throws -> [BuiltTransaction] {
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "walletApplyEngine.dedup",
      signpostID: signpostID,
      "%{public}d candidates",
      candidates.count)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "walletApplyEngine.dedup",
        signpostID: signpostID)
    }
    return try await dedup(candidates)
  }

  /// Wraps `persist` in a `walletApplyEngine.persist` signpost region.
  private func runPersistSignposted(
    _ candidates: [BuiltTransaction],
    signpostID: OSSignpostID
  ) async throws -> [Transaction] {
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "walletApplyEngine.persist",
      signpostID: signpostID,
      "%{public}d candidates",
      candidates.count)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "walletApplyEngine.persist",
        signpostID: signpostID)
    }
    return try await persist(candidates)
  }

  /// Wraps `importRules.apply` in a `walletApplyEngine.rules` signpost
  /// region. Records the input count so per-cycle rule cost is visible
  /// in Instruments without instrumenting every rule implementation.
  private func runRulesSignposted(
    _ persisted: [Transaction],
    signpostID: OSSignpostID
  ) async throws -> [Transaction] {
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "walletApplyEngine.rules",
      signpostID: signpostID,
      "%{public}d transactions",
      persisted.count)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "walletApplyEngine.rules",
        signpostID: signpostID)
    }
    return try await importRules.apply(transactions: persisted)
  }

  // MARK: - Pipeline steps

  /// Captures the repository in a `@Sendable` closure so the merger can
  /// look up prior-cycle legs by `externalId`.
  private func makeExistingLegLookup()
    -> @Sendable (String) async throws -> [TransactionLeg]
  {
    let transactions = self.transactions
    return { externalId in
      try await transactions.legs(matchingExternalId: externalId)
    }
  }

  /// Drops legs that already exist in the repository (matched by
  /// `(accountId, externalId)`). When every leg of a transaction is
  /// dropped the whole transaction is skipped.
  private func dedup(_ candidates: [BuiltTransaction]) async throws -> [BuiltTransaction] {
    var output: [BuiltTransaction] = []
    output.reserveCapacity(candidates.count)
    for candidate in candidates {
      let surviving = try await survivingLegs(for: candidate)
      guard !surviving.isEmpty else { continue }
      let pruned = Transaction(
        id: candidate.transaction.id,
        date: candidate.transaction.date,
        payee: candidate.transaction.payee,
        notes: candidate.transaction.notes,
        recurPeriod: candidate.transaction.recurPeriod,
        recurEvery: candidate.transaction.recurEvery,
        legs: surviving,
        importOrigin: candidate.transaction.importOrigin)
      output.append(
        BuiltTransaction(
          originAccountId: candidate.originAccountId,
          transaction: pruned))
    }
    return output
  }

  private func survivingLegs(
    for candidate: BuiltTransaction
  ) async throws -> [TransactionLeg] {
    var legs: [TransactionLeg] = []
    legs.reserveCapacity(candidate.transaction.legs.count)
    for leg in candidate.transaction.legs {
      guard
        let externalId = leg.externalId,
        let accountId = leg.accountId
      else {
        legs.append(leg)
        continue
      }
      let exists = try await transactions.legExists(
        accountId: accountId, externalId: externalId)
      if !exists {
        legs.append(leg)
      }
    }
    return legs
  }

  /// Persists the deduped survivors in a single atomic bulk insert.
  ///
  /// `createMany` writes every transaction (with its legs) inside one
  /// write transaction; on any failure none persist. That all-or-nothing
  /// boundary is safe here because the apply pipeline dedups exactly on
  /// `(accountId, externalId)` — a rolled-back batch is re-fetched within
  /// the reorg window next cycle and every already-landed leg dedups to a
  /// no-op. It also avoids the per-`create` commit/fsync that made a busy
  /// wallet's persist pass O(transactions) write transactions.
  private func persist(_ candidates: [BuiltTransaction]) async throws -> [Transaction] {
    try await transactions.createMany(candidates.map(\.transaction))
  }

  /// Writes both the per-device `WalletSyncState` and the cross-device synced
  /// `WalletSyncCheckpoint` for every account that participated in the cycle.
  ///
  /// The synced checkpoint is max-merged (`max(existing, head)`) so a device
  /// whose fetch trailed a peer never lowers the shared value — the read side
  /// (`WalletSyncEngine.build`) trusts the checkpoint to skip re-scanning
  /// blocks a peer already covered.
  ///
  /// Eventual-consistency caveat: a synced checkpoint can arrive on a peer
  /// device *before* the transactions it summarises (CloudKit delivers the
  /// two record types independently and out of order). That peer would then
  /// start its next fetch from the higher `fromBlock` and could skip the
  /// still-in-flight transactions — but they converge: the transactions
  /// arrive via CloudKit sync of the `TransactionRecord`s, and any re-fetch
  /// dedups against the persisted legs by `externalId`, so no duplicate and
  /// no permanent gap results.
  private func updateSyncState(for perAccount: [AccountInput]) async throws {
    let now = clock()
    for input in perAccount {
      let state = WalletSyncState(
        id: input.account.id,
        lastSyncedBlockNumber: input.headBlockNumber,
        lastSyncedAt: now,
        lastError: nil)
      try await walletSyncState.save(state)

      let existing =
        (try? await checkpoints.load(accountId: input.account.id))?.lastSyncedBlockNumber ?? 0
      try await checkpoints.save(
        WalletSyncCheckpoint(
          id: input.account.id,
          lastSyncedBlockNumber: max(existing, input.headBlockNumber)))
    }
  }
}
