// Features/Sync/SyncedAccountStore+Internals.swift
import Foundation
import OSLog

/// Outcome of one per-account build task. The apply pass only consumes
/// `.success`; `.failed` accounts have their errors persisted inside the
/// build task itself, and `.skipped` accounts (cancelled, no matching
/// source) contribute nothing.
///
/// `.failed` carries the account's `AccountType` so `updateGlobalError`
/// can scope the Alchemy-key banner to crypto accounts — an exchange
/// credential failure must not light the (Alchemy-specific) global
/// banner.
enum PerAccountBuildResult: Sendable {
  case success(WalletApplyEngine.AccountInput)
  case failed(UUID, WalletSyncError, AccountType)
  case skipped(UUID)
}

extension SyncedAccountStore {

  // MARK: - Parallel build

  /// Runs the parallel build phase for `accountList` via
  /// `withTaskGroup`, capping concurrency at `maxConcurrentBuilds`. A
  /// per-account failure is captured as a `lastError` write on
  /// `WalletSyncState` (preserving the prior `lastSyncedBlockNumber`)
  /// and contributes nothing to the apply phase. Native `WalletSyncError`
  /// values are stored as-is; unexpected `Error` types are wrapped in
  /// `.network(...)` so the persisted value stays inside the closed
  /// taxonomy `WalletSyncError` defines.
  ///
  /// Returns the full `PerAccountBuildResult` set (not just the
  /// successful inputs) so callers can scan failures for process-wide
  /// errors (`.missingApiKey` / `.invalidApiKey`) and surface them on
  /// `globalError`. The apply pass filters to `.success` itself.
  func runParallelBuilds(
    for accountList: [Account]
  ) async -> [PerAccountBuildResult] {
    let limit = maxConcurrentBuilds
    let sources = self.sources
    let walletSyncState = self.walletSyncState
    let statesById = self.statePerAccount

    return await withTaskGroup(
      of: PerAccountBuildResult.self,
      returning: [PerAccountBuildResult].self
    ) { group in
      var iterator = accountList.makeIterator()
      var dispatched = 0
      // Prime the group with the first `limit` tasks…
      while dispatched < limit, let account = iterator.next() {
        group.addTask {
          await Self.buildOne(
            account: account,
            sources: sources,
            walletSyncState: walletSyncState,
            priorState: statesById[account.id])
        }
        dispatched += 1
      }
      var collected: [PerAccountBuildResult] = []
      collected.reserveCapacity(accountList.count)
      // …then add a new task as each finishes so the group never holds
      // more than `limit` in-flight tasks at once.
      while let result = await group.next() {
        collected.append(result)
        if let next = iterator.next() {
          group.addTask {
            await Self.buildOne(
              account: next,
              sources: sources,
              walletSyncState: walletSyncState,
              priorState: statesById[next.id])
          }
        }
      }
      return collected
    }
  }

  /// One per-account build task. Static because `withTaskGroup` runs
  /// the body off `@MainActor` and a `nonisolated` static avoids
  /// capturing `self`. All dependencies are passed in.
  ///
  /// Cancellation propagates: a cancelled cycle never writes a
  /// half-resolved error row.
  nonisolated static func buildOne(
    account: Account,
    sources: [any AccountSyncSource],
    walletSyncState: any WalletSyncStateRepository,
    priorState: WalletSyncState?
  ) async -> PerAccountBuildResult {
    guard let source = sources.first(where: { $0.handles(account) }) else {
      internalsLogger.notice(
        "Skipping account \(account.id, privacy: .public) — no matching sync source"
      )
      return .skipped(account.id)
    }
    do {
      let built = try await source.build(account: account)
      // AccountInput construction is the same for crypto and exchange
      // accounts. For exchange accounts headBlockNumber is 0 (no block
      // watermark); for crypto the wallet engine fills it from fetched
      // transfers.
      let input = WalletApplyEngine.AccountInput(
        account: account,
        headBlockNumber: built.headBlockNumber,
        candidates: built.candidates)
      return .success(input)
    } catch is CancellationError {
      // Cooperative cancellation — never write a half-resolved row.
      return .skipped(account.id)
    } catch let walletError as WalletSyncError {
      await persistError(
        walletError,
        accountId: account.id,
        priorState: priorState,
        walletSyncState: walletSyncState)
      return .failed(account.id, walletError, account.type)
    } catch {
      let mapped = WalletSyncError.network(
        underlyingDescription: error.localizedDescription)
      await persistError(
        mapped,
        accountId: account.id,
        priorState: priorState,
        walletSyncState: walletSyncState)
      return .failed(account.id, mapped, account.type)
    }
  }

  /// Writes `lastError` onto the account's `WalletSyncState` while
  /// preserving the prior `lastSyncedBlockNumber` (so the next cycle's
  /// reorg-window math doesn't restart from genesis after a transient
  /// failure). On a fresh account with no prior state, writes a
  /// genesis-style row at block 0 so the `lastError` surfaces in the
  /// UI on the first failed attempt.
  ///
  /// `lastSyncedAt` is intentionally **not** updated on failure — the
  /// staleness check should still treat the account as overdue.
  nonisolated static func persistError(
    _ error: WalletSyncError,
    accountId: UUID,
    priorState: WalletSyncState?,
    walletSyncState: any WalletSyncStateRepository
  ) async {
    let state = WalletSyncState(
      id: accountId,
      lastSyncedBlockNumber: priorState?.lastSyncedBlockNumber ?? 0,
      lastSyncedAt: priorState?.lastSyncedAt ?? .distantPast,
      lastError: error)
    do {
      try await walletSyncState.save(state)
    } catch {
      internalsLogger.error(
        "Failed to persist sync error for account \(accountId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // MARK: - Sequential apply

  /// Runs the sequential `@MainActor` apply pass over the build-phase
  /// outputs. A throwing apply pass is logged but does not surface to
  /// callers — per-account errors were already persisted in the build
  /// phase. `WalletApplyEngine` throws repository errors (GRDB /
  /// CloudKit), not `WalletSyncError`, so the global banner is driven
  /// entirely from the build-phase scan in `updateGlobalError(from:)`.
  ///
  /// Returns the apply engine's merged-and-deduped survivors — the
  /// transactions this sync pass genuinely persisted. Transfer detection
  /// is driven over exactly this set (never a date-window scan), so a
  /// previously-existing transaction is never re-evaluated. On a throwing
  /// apply pass nothing was persisted, so the survivor set is empty.
  func runApplyPass(
    perAccountResults: [PerAccountBuildResult]
  ) async -> [Transaction] {
    let inputs: [WalletApplyEngine.AccountInput] = perAccountResults.compactMap {
      if case let .success(input) = $0 { return input }
      return nil
    }
    do {
      return try await walletApplyEngine.apply(perAccount: inputs)
    } catch {
      Self.internalsLogger.warning(
        "WalletApplyEngine apply pass failed: \(error.localizedDescription, privacy: .public)"
      )
      return []
    }
  }

  /// Updates `globalError` based on the build phase's per-account
  /// outcomes, **scoped to crypto accounts**. The banner powers
  /// `CryptoSettingsView.alchemyStatusBadge` (Alchemy-specific): the
  /// shared Alchemy key means an `.invalidApiKey` / `.missingApiKey` from
  /// any one *crypto* account implies no crypto account can sync, so we
  /// surface it once — preferring `.missingApiKey` (add a key) over
  /// `.invalidApiKey` (replace a key) when both are present. An exchange
  /// account's per-account token failure is deliberately ignored here —
  /// folding it in would wrongly blame the Alchemy key.
  ///
  /// Clears when no crypto process-wide error appears this cycle.
  /// Per-account errors (`.network`, `.rateLimited`,
  /// `.providerMalformedResponse`) go on the per-row
  /// `WalletSyncState.lastError` instead, not the banner.
  func updateGlobalError(from results: [PerAccountBuildResult]) {
    var sawMissing = false
    var sawInvalid = false
    for result in results {
      if case let .failed(_, error, accountType) = result, accountType == .crypto {
        // Match `.kind`, not the whole value: production errors are
        // stamped with a `provider`, so a whole-value match against the
        // unattributed `.missingApiKey` factory would never fire.
        switch error.kind {
        case .missingApiKey:
          sawMissing = true
        case .invalidApiKey:
          sawInvalid = true
        default:
          break
        }
      }
    }
    if sawMissing {
      setGlobalError(.missingApiKey)
    } else if sawInvalid {
      setGlobalError(.invalidApiKey)
    } else {
      setGlobalError(nil)
    }
  }

  /// Re-loads `statePerAccount` from the repository so observable view
  /// state matches the persisted truth after the apply pass writes
  /// `lastSyncedBlockNumber` / `lastSyncedAt` (success) or `lastError`
  /// (failure). Errors here are non-fatal — the next launch reloads.
  func refreshStateFromRepository() async {
    await reloadStatePerAccount(failureLogPrefix: "WalletSyncState refresh")
  }

  // MARK: - Transfer detection

  /// Runs detection over exactly the transactions this sync pass
  /// genuinely created (`WalletApplyEngine.apply`'s merged-and-deduped
  /// survivors). No date-window scan: a previously-existing transaction
  /// is never re-evaluated, so a dismissed/merged pair is never
  /// re-suggested (the record model has no negative-assertion tombstone).
  ///
  /// `windowLowerBound` bounds the coordinator's `existingNearby`
  /// counterpart fetch — the maximum age of a candidate counterpart.
  ///
  /// The `transferDetection.isMutating` pre-check keeps a background sync
  /// pass from writing `mutationInProgress` into the coordinator's
  /// user-visible `error` while the user is mid-merge/dismiss; the
  /// coordinator's `mutate` gate remains the final arbiter.
  func runTransferDetection(
    genuinelyNew: [Transaction], participatingAccountIds: Set<UUID>
  ) async {
    guard !transferDetection.isMutating else {
      // Computed once per pass and never re-fetched, so a skipped pass
      // means these rows are never evaluated for detection. Rare trigger
      // (sync finishing mid-merge/dismiss); accepted rather than
      // buffer-and-replay.
      Self.internalsLogger.notice(
        "Transfer detection skipped — coordinator busy; genuinely-new rows from this pass will not be evaluated"
      )
      return
    }
    let eligible = genuinelyNew.filter { $0.transferDetectionValueLeg != nil }
    // Anchor on the earliest eligible transaction's `date` (the trade /
    // transfer date), not `clock()` — a bulk historical exchange import
    // produces survivors dated months or years in the past, and a
    // wall-clock floor would drop every peer candidate before the
    // detector ever saw them. Same pattern as `ImportStore.ingest`.
    guard let earliest = eligible.min(by: { $0.date < $1.date }) else {
      return
    }
    let windowLowerBound = earliest.date.addingTimeInterval(
      -FuzzyTransferDetector.windowSeconds)
    await transferDetection.runDetection(
      newlyImported: eligible,
      participatingAccountIds: participatingAccountIds,
      windowLowerBound: windowLowerBound)
  }

  /// Logger for the build/apply/detection pipeline (and, via
  /// `SyncedAccountStore+SyncTriggers.swift`, the public sync-trigger
  /// entry points too). Static and `Sendable` so the cross-actor
  /// `buildOne` / `persistError` helpers can call it without capturing
  /// `self`; module-internal (not `private`) so the sibling
  /// `+SyncTriggers` extension file can share it rather than declaring
  /// its own duplicate logger.
  nonisolated static let internalsLogger = Logger(
    subsystem: "com.moolah.app", category: "SyncedAccountStore")
}
