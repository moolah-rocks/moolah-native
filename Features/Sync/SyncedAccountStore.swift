// Features/Sync/SyncedAccountStore.swift
import Foundation
import OSLog
import Observation
import SwiftUI
import os

/// `@MainActor @Observable` orchestrator for provider-neutral account
/// auto-import (on-chain wallets and centralised exchanges). Owns the
/// foreground sync timer, the per-account "Sync now" command, and
/// per-account observable state (last-synced, sync-in-progress,
/// last-error). It never branches on account type — every provider is
/// expressed as an `AccountSyncSource`.
///
/// Cancellation discipline (per design §"Sync trigger taxonomy"):
///
/// - On scenePhase `.active`: cancel any prior `timerTask`, then assign
///   a new `Task { await runTimerLoop() }` to `timerTask`.
/// - On `.background` / `.inactive`: cancel `timerTask` and clear it.
/// - The loop body checks `Task.isCancelled` immediately after every
///   `Task.sleep(for:)` suspension before dispatching the next sync
///   batch and before sleeping again. A cancelled task exits cleanly
///   without writing state.
///
/// `BackgroundTasks` (`BGAppRefreshTask`) is explicitly out of scope.
///
/// Concurrency model: parallel build via `withTaskGroup` (up to 4
/// concurrent per-account tasks), then a single sequential `@MainActor`
/// apply pass via `WalletApplyEngine`. Per-account error containment is
/// built into the build phase — a failing account writes
/// `WalletSyncState.lastError` and does not abort other accounts.
@MainActor
@Observable
final class SyncedAccountStore {
  /// Per-account in-flight markers. Used both as observable view state
  /// (so a row can show a spinner) and as a guard against concurrent
  /// duplicate launches: `syncStaleAccounts` and `syncAccount` skip an
  /// account already present here, so a second trigger while the first
  /// is still running collapses to the single in-flight sync.
  private(set) var inProgressAccountIds: Set<UUID> = []

  /// Per-account sync state (`lastSyncedAt`, `lastSyncedBlockNumber`,
  /// `lastError`) keyed by account id. Loaded from
  /// `WalletSyncStateRepository.loadAll()` at launch and refreshed after
  /// every apply pass so the wallet account view + settings UI re-render
  /// without another round-trip.
  private(set) var statePerAccount: [UUID: WalletSyncState] = [:]

  /// Banner-level error visible across the crypto-settings UI when a
  /// process-wide Alchemy-key failure (`.missingApiKey` /
  /// `.invalidApiKey`) means no **crypto** account can sync at all. Set
  /// by `updateGlobalError(from:)` after every build phase, scoped to
  /// crypto accounts only — the banner powers
  /// `CryptoSettingsView.alchemyStatusBadge`, which is Alchemy-specific;
  /// an exchange credential failure must not light it. Cleared back to
  /// `nil` on the next cycle with no such crypto failure. Per-account
  /// network / rate-limit / malformed errors are stored on
  /// `statePerAccount[id].lastError` instead.
  private(set) var globalError: WalletSyncError?

  // Internal (default) access so the helpers in
  // `SyncedAccountStore+Internals.swift` can read these without
  // bouncing through accessor methods. The properties remain `let` so
  // the store is still effectively immutable from outside this
  // module's extensions.
  //
  // `sources` is the provider-neutral seam: each `AccountSyncSource`
  // claims the accounts it can sync via `handles(_:)`. The store never
  // inspects `account.type` — it asks the sources. `private(set) var`
  // (not `let`) only so the test-only `appendSourceForTesting(_:)` can
  // register an extra source post-construction; production sets it once
  // in `init`.
  private(set) var sources: [any AccountSyncSource]
  let walletApplyEngine: WalletApplyEngine
  let walletSyncState: any WalletSyncStateRepository
  let accounts: any AccountRepository

  /// Cross-account transfer-detection coordinator. Owns every detection
  /// and merge action; the store only orchestrates the post-apply call.
  let transferDetection: TransferDetectionCoordinator

  let clock: @Sendable () -> Date
  let staleThreshold: TimeInterval
  let timerInterval: Duration
  let maxConcurrentBuilds: Int

  /// Hourly stale-check timer. Owned by the store; cancelled on
  /// scenePhase `.background`/`.inactive`; recreated on `.active`.
  /// `nil` outside an active scene. Module-internal write so the
  /// `+Internals` extension can swap the task on `.active`.
  var timerTask: Task<Void, Never>?

  /// Tracks the last `.active`-triggered immediate sync so a rapid
  /// scene-phase cycle (e.g. dragging a window across Spaces) cancels
  /// the prior fire-and-forget instead of stacking. Per
  /// `guides/CONCURRENCY_GUIDE.md` §8 — fire-and-forget tasks must be
  /// tracked so teardown can cancel them.
  var sceneActiveSyncTask: Task<Void, Never>?

  /// Fire-and-forget initial-sync tasks dispatched by the create-account
  /// form, keyed by account id. The form spawns one of these per newly
  /// created crypto account (via `scheduleInitialSync(for:)`) so the
  /// sheet can dismiss the moment the account is persisted instead of
  /// awaiting the network round-trip. Tracked here per
  /// `guides/CONCURRENCY_GUIDE.md` §8 so `cancelTimer()` (called from
  /// `ProfileSession.cleanupSync`) can cancel any in-flight sync that
  /// outlives the form, and so tests can await completion via
  /// `waitForPendingInitialSyncs()`.
  private(set) var initialSyncTasks: [UUID: Task<Void, Never>] = [:]

  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "SyncedAccountStore")

  /// - Parameters:
  ///   - sources: Provider-neutral sync sources. The store asks each
  ///     `handles(_:)` to decide which accounts it can sync — it never
  ///     branches on `account.type` itself.
  ///   - walletApplyEngine: Sequential `@MainActor` apply pass — runs
  ///     after the parallel build phase completes.
  ///   - walletSyncState: Per-device sync checkpoint store.
  ///   - accounts: Account repository — read on every stale check to
  ///     filter to syncable accounts (via `sources`).
  ///   - transferDetection: Cross-account transfer-detection
  ///     coordinator. The store calls `runDetection` once per sync pass
  ///     after the apply + state refresh.
  ///   - clock: Closure returning "now". The clock injection is for
  ///     per-account `lastSyncedAt` decisions; the timer's
  ///     `Task.sleep` uses the real Swift clock regardless. Tests pass
  ///     a pinned closure.
  ///   - staleThreshold: Seconds before an account is considered stale
  ///     since the last successful sync. Default 24 hours.
  ///   - timerInterval: Hourly stale-check cadence. Default 1 hour.
  ///   - maxConcurrentBuilds: Cap on simultaneous per-account fetches in
  ///     the parallel build phase. Default 4.
  init(
    sources: [any AccountSyncSource],
    walletApplyEngine: WalletApplyEngine,
    walletSyncState: any WalletSyncStateRepository,
    accounts: any AccountRepository,
    transferDetection: TransferDetectionCoordinator,
    clock: @Sendable @escaping () -> Date = { Date() },
    staleThreshold: TimeInterval = 86_400,
    timerInterval: Duration = .seconds(3_600),
    maxConcurrentBuilds: Int = 4
  ) {
    self.sources = sources
    self.walletApplyEngine = walletApplyEngine
    self.walletSyncState = walletSyncState
    self.accounts = accounts
    self.transferDetection = transferDetection
    self.clock = clock
    self.staleThreshold = staleThreshold
    self.timerInterval = timerInterval
    self.maxConcurrentBuilds = max(1, maxConcurrentBuilds)
  }

  /// The first registered `AccountSyncSource` that claims `account`, or
  /// `nil` if none do. Centralises the provider-neutral lookup so the
  /// store never branches on `account.type` itself. Module-internal (not
  /// `private`) so the `+Internals` extension's `accountsToSync` can
  /// share the same predicate.
  func source(for account: Account) -> (any AccountSyncSource)? {
    sources.first(where: { $0.handles(account) })
  }

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
  func syncAccount(_ account: Account) async {
    guard source(for: account) != nil else { return }
    guard !inProgressAccountIds.contains(account.id) else { return }
    await syncAccounts([account])
  }

  /// Fire-and-forget kick-off of `syncAccount(_:)` for a newly created
  /// syncable account (crypto or exchange). Returns immediately so the
  /// create-account sheet
  /// can `dismiss()` the moment the account is persisted; the network
  /// sync continues in the spawned task, which is tracked in
  /// `initialSyncTasks` so `cancelTimer()` can tear it down on profile
  /// teardown. A second call for an account that already has a pending
  /// initial-sync task is a no-op — the original task wins, mirroring
  /// the duplicate-collapse rule on `syncAccount(_:)` itself.
  func scheduleInitialSync(for account: Account) {
    let id = account.id
    guard initialSyncTasks[id] == nil else { return }
    initialSyncTasks[id] = Task { [weak self] in
      await self?.syncAccount(account)
      self?.initialSyncTasks.removeValue(forKey: id)
    }
  }

  /// Test seam — awaits every tracked initial-sync task to completion.
  /// Production code never needs this: the sheet dismisses on
  /// `.created` and the sync runs out-of-band. Tests use it to
  /// synchronise on the post-sync state (e.g. asserting that the
  /// alchemy stub recorded the build call).
  func waitForPendingInitialSyncs() async {
    while let task = initialSyncTasks.first?.value {
      await task.value
    }
  }

  // MARK: - Lifecycle

  /// Call from `.onChange(of: scenePhase)` in the root scene. Owns the
  /// timer's lifecycle: started fresh on `.active` (after cancelling any
  /// prior task) and torn down on `.background` / `.inactive`.
  func handleScenePhaseChange(_ newPhase: ScenePhase) {
    switch newPhase {
    case .active:
      restartTimer()
      sceneActiveSyncTask?.cancel()
      sceneActiveSyncTask = Task { [weak self] in
        await self?.syncStaleAccounts()
      }
    case .background, .inactive:
      cancelTimer()
    @unknown default:
      break
    }
  }

  /// Cancels and clears the hourly stale-check timer, any in-flight
  /// scene-active sync, and any pending initial-sync tasks scheduled by
  /// the create-account form. Safe to call when no task is running.
  /// Exposed for `ProfileSession.cleanupSync` so no task outlives a
  /// profile teardown.
  func cancelTimer() {
    timerTask?.cancel()
    timerTask = nil
    sceneActiveSyncTask?.cancel()
    sceneActiveSyncTask = nil
    for task in initialSyncTasks.values { task.cancel() }
    initialSyncTasks.removeAll()
  }

  // MARK: - Sync algorithm (parallel build → sequential apply)

  /// Sync the given accounts via the parallel-build → sequential-apply
  /// algorithm. Internal seam — used by `syncStaleAccounts`,
  /// `syncAccount`, and the timer loop. Marked `internal` so tests can
  /// drive a deterministic account list directly.
  ///
  /// Algorithm:
  /// 1. Mark every account as in-flight on `@MainActor`.
  /// 2. Run up to `maxConcurrentBuilds` parallel build tasks via
  ///    `withTaskGroup`. Each task either produces a
  ///    `WalletSyncBuildResult` or records a `lastError` on the account's
  ///    `WalletSyncState` and surfaces a `.failed` outcome.
  /// 3. Scan the per-account outcomes for process-wide errors
  ///    (`.missingApiKey` / `.invalidApiKey`) and update `globalError`.
  /// 4. Apply successful results sequentially through `WalletApplyEngine`.
  /// 5. Refresh `statePerAccount` from the repository so observable view
  ///    state matches the persisted truth.
  /// 6. Clear in-flight markers.
  func syncAccounts(_ accountList: [Account]) async {
    let inputs = accountList.filter { account in
      guard source(for: account) != nil else { return false }
      // Re-skip anything already in flight from a prior trigger; this
      // is the load-bearing collapse-duplicates check exercised by the
      // concurrent-trigger test.
      guard !inProgressAccountIds.contains(account.id) else { return false }
      return true
    }
    guard !inputs.isEmpty else { return }

    let signpostID = OSSignpostID(log: Signposts.cryptoSync)
    os_signpost(
      .begin,
      log: Signposts.cryptoSync,
      name: "syncedAccountStore.syncAccounts",
      signpostID: signpostID,
      "%{public}d accounts",
      inputs.count)
    defer {
      os_signpost(
        .end,
        log: Signposts.cryptoSync,
        name: "syncedAccountStore.syncAccounts",
        signpostID: signpostID)
    }

    for account in inputs { inProgressAccountIds.insert(account.id) }
    defer {
      for account in inputs { inProgressAccountIds.remove(account.id) }
    }

    let perAccountResults = await runParallelBuilds(for: inputs)
    updateGlobalError(from: perAccountResults)
    let genuinelyNew = await runApplyPass(perAccountResults: perAccountResults)
    await refreshStateFromRepository()
    // Detection runs over the apply pass's genuinely-new survivors only
    // — the transactions this pass actually merged-and-deduped-and-
    // persisted. There is no date-window scan, so a previously-existing
    // row (e.g. a dismissed/merged pair) is never re-evaluated. Transfers
    // already collapsed by `CrossAccountTransferMerger` (same-`externalId`
    // opposing legs) carry a nil `transferDetectionValueLeg` and are
    // structurally skipped by the detector.
    await runTransferDetection(
      genuinelyNew: genuinelyNew,
      participatingAccountIds: Set(inputs.map(\.id)))
  }

  // MARK: - Internal mutators

  /// Setter shim so `SyncedAccountStore+Internals.swift` extension
  /// methods can update observable state. The store's public surface
  /// keeps `private(set)` for `globalError` so views can only observe —
  /// the shim is internal, not public.
  func setGlobalError(_ error: WalletSyncError?) {
    globalError = error
  }

  #if DEBUG
    /// Test-only: register an extra `AccountSyncSource` after
    /// construction. The integration harness builds the store first,
    /// then registers a `CoinstashSyncSource` that uses harness-owned
    /// collaborators (you cannot reference the harness inside its own
    /// init).
    ///
    /// Mutation is confined to @MainActor because SyncedAccountStore is
    /// @MainActor (the compiler enforces this) — no data-race risk.
    /// Gated `#if DEBUG` so production cannot mutate the source list.
    func appendSourceForTesting(_ source: any AccountSyncSource) {
      sources.append(source)
    }
  #endif

  /// Replaces the entire `statePerAccount` map. Used by the apply-phase
  /// refresh after a sync cycle so the in-memory view of checkpoint
  /// state matches the persisted truth.
  func replaceStatePerAccount(_ map: [UUID: WalletSyncState]) {
    statePerAccount = map
  }

  /// Loads every persisted checkpoint into `statePerAccount`. Shared
  /// between launch bootstrap and the post-apply refresh; the
  /// `failureLogPrefix` distinguishes the two call sites in the log.
  func reloadStatePerAccount(failureLogPrefix: String) async {
    do {
      let states = try await walletSyncState.loadAll()
      var map: [UUID: WalletSyncState] = [:]
      map.reserveCapacity(states.count)
      for state in states { map[state.id] = state }
      replaceStatePerAccount(map)
    } catch {
      Self.logger.error(
        "\(failureLogPrefix, privacy: .public) failed: \(error.localizedDescription, privacy: .public)"
      )
    }
  }

  // Implementation helpers (parallel build, apply pass, timer loop)
  // live in `SyncedAccountStore+Internals.swift`.
}
