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

  // MARK: - Public sync triggers

  /// Bootstraps observable state from persisted checkpoints. Call once
  /// at app launch (e.g. from the root scene `.task`). Failure is
  /// non-fatal — the next sync cycle still runs against an empty cache.
  func loadInitialState() async {
    await reloadStatePerAccount(failureLogPrefix: "Initial WalletSyncState load")
  }

  /// Sync any syncable account whose `lastSyncedAt` is older than
  /// `staleThreshold` (24 h by default). Used by app-launch, scene-active,
  /// and the hourly timer. A no-op when nothing is stale.
  ///
  /// Per-account error containment is preserved: failures inside the
  /// build phase write `WalletSyncState.lastError` and don't abort other
  /// accounts in the same cycle.
  func syncStaleAccounts() async {
    let stale = await accountsToSync(includeNonStale: false)
    guard !stale.isEmpty else { return }
    await syncAccounts(stale)
  }

  /// User-initiated sync of a specific account, regardless of staleness.
  /// Skips when the account is already mid-sync (the existing in-flight
  /// task wins; the user-initiated one collapses to a no-op rather than
  /// queueing a duplicate write).
  ///
  /// `fullResync: true` first deletes both the persisted `WalletSyncState`
  /// AND the synced `WalletSyncCheckpoint`, and drops the account's cached
  /// entry in `statePerAccount`, so the build phase finds no watermark
  /// anywhere (local, synced, or cached) and computes `fromBlock == 0`
  /// (full-history re-fetch), recovering transfers an earlier incremental
  /// sync skipped. Clearing only the local `WalletSyncState` would NOT be
  /// enough: `WalletSyncEngine.build` derives `fromBlock` from
  /// `max(localState, syncedCheckpoint)`, so the resync would still resume
  /// from the synced checkpoint. Clearing that checkpoint tombstones the
  /// shared row via CloudKit; a peer that hasn't seen the tombstone yet
  /// still holds its own last-seen value, but self-heals back to the
  /// correct shared maximum via `raiseToMax` on its own next cycle. Safe to
  /// repeat: the apply pass dedups on `(accountId, externalId)`, and a
  /// failed resync build leaves both watermarks at genesis rather than
  /// resurrecting the prior block — dropping the in-memory cache entry
  /// means `persistError` sees a `nil` `priorState` and writes
  /// `lastSyncedBlockNumber: 0`. Benign TOCTOU: a sync racing the
  /// in-flight guard below can still see the deleted checkpoints after
  /// this call collapses to a no-op; either kind simply refetches from
  /// block 0 — accepted rather than adding locking.
  func syncAccount(_ account: Account, fullResync: Bool = false) async {
    guard source(for: account) != nil else { return }
    guard !inProgressAccountIds.contains(account.id) else { return }
    if fullResync {
      // Both deletes are non-fatal: a failure falls back to an incremental
      // sync (resuming from whatever watermark remains) rather than
      // aborting the user's request outright.
      do {
        try await walletSyncState.delete(accountId: account.id)
      } catch {
        Self.internalsLogger.error(
          "Full-resync checkpoint reset failed for account \(account.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
      do {
        try await walletSyncCheckpoints.delete(accountId: account.id)
      } catch {
        Self.internalsLogger.error(
          "Full-resync synced-checkpoint reset failed for account \(account.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
        )
      }
      // Drop the cached checkpoint too — otherwise a build failure's
      // `persistError` would read the stale in-memory `priorState` and
      // re-save the pre-reset watermark instead of genesis.
      var trimmedState = statePerAccount
      trimmedState.removeValue(forKey: account.id)
      replaceStatePerAccount(trimmedState)
    }
    await syncAccounts([account])
  }

  // MARK: - Stale filter

  /// Filters `accounts.fetchAll()` down to syncable accounts (any
  /// account some registered `AccountSyncSource` claims) that are
  /// either stale (older than `staleThreshold`) or — when
  /// `includeNonStale == true` — every syncable account regardless.
  /// Reads `clock()` for "now" so tests can pin time.
  func accountsToSync(includeNonStale: Bool) async -> [Account] {
    let allAccounts: [Account]
    do {
      allAccounts = try await accounts.fetchAll()
    } catch {
      Self.internalsLogger.error(
        "Account fetch failed during stale check: \(error.localizedDescription, privacy: .public)"
      )
      return []
    }
    let now = clock()
    return allAccounts.filter { account in
      // `WalletSyncSource.handles` already enforces walletAddress +
      // chainId for crypto; exchange accounts have neither but are
      // claimed by `CoinstashSyncSource`. Asking the sources keeps the
      // stale-timer / scene-active path provider-neutral.
      guard source(for: account) != nil else { return false }
      if includeNonStale { return true }
      let lastSyncedAt = statePerAccount[account.id]?.lastSyncedAt ?? .distantPast
      return now.timeIntervalSince(lastSyncedAt) >= staleThreshold
    }
  }

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

  /// Logger for internals-extension diagnostics. Static and `Sendable`
  /// so the cross-actor `buildOne` / `persistError` helpers can call
  /// it without capturing `self`.
  nonisolated private static let internalsLogger = Logger(
    subsystem: "com.moolah.app", category: "SyncedAccountStore")
}
