// Features/Sync/SyncedAccountStore+SyncTriggers.swift
import Foundation
import OSLog

/// Public sync-trigger entry points (`loadInitialState`, `syncStaleAccounts`,
/// `syncAccount(_:fullResync:)`) plus their stale-filter helper. Split out of
/// `SyncedAccountStore+Internals.swift` — which owns the parallel-build →
/// sequential-apply → transfer-detection pipeline these triggers dispatch
/// into — to keep both files under the project's `file_length` budget along
/// a semantic seam (trigger surface vs. pipeline internals) rather than an
/// arbitrary line split.
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
    var syncedCheckpointResetFailed = false
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
        syncedCheckpointResetFailed = true
      }
      // Drop the cached checkpoint too — otherwise a build failure's
      // `persistError` would read the stale in-memory `priorState` and
      // re-save the pre-reset watermark instead of genesis.
      var trimmedState = statePerAccount
      trimmedState.removeValue(forKey: account.id)
      replaceStatePerAccount(trimmedState)
    }
    await syncAccounts([account])
    if syncedCheckpointResetFailed {
      // Recorded *after* `syncAccounts` (not alongside the log above)
      // because a successful build/apply pass for this same account would
      // otherwise immediately overwrite it: `WalletApplyEngine.updateSyncState`
      // writes `lastError: nil` on success, and `syncAccounts` refreshes
      // `statePerAccount` from that write right before returning. Recording
      // here, last, means the account's `lastError` survives regardless of
      // whether the resync's own build succeeded — this failure means the
      // "full" resync actually resumed from the stale synced checkpoint
      // instead of genesis, which the user needs to see even when the sync
      // otherwise looks like it worked.
      await recordSyncedCheckpointResetFailure(for: account)
    }
  }

  /// Surfaces a failed synced-checkpoint reset (see `syncAccount`'s
  /// `fullResync` doc comment) onto the account's `WalletSyncState.lastError`
  /// so the user sees the resync didn't fully reset, instead of the failure
  /// being silently swallowed as a log line. Preserves the block number /
  /// timestamp `syncAccounts` just persisted — only `lastError` changes.
  /// Non-fatal: a failure to persist this is logged and otherwise ignored.
  private func recordSyncedCheckpointResetFailure(for account: Account) async {
    let priorState = statePerAccount[account.id]
    let state = WalletSyncState(
      id: account.id,
      lastSyncedBlockNumber: priorState?.lastSyncedBlockNumber ?? 0,
      lastSyncedAt: priorState?.lastSyncedAt ?? .distantPast,
      lastError: .network(
        underlyingDescription:
          "Full resync could not clear the synced checkpoint; the account may have resumed from a stale watermark instead of genesis."
      ))
    do {
      try await walletSyncState.save(state)
    } catch {
      Self.internalsLogger.error(
        "Failed to persist synced-checkpoint reset failure for account \(account.id, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
    await refreshStateFromRepository()
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
}
