// Features/Sync/SyncedAccountStore+WindowedSync.swift
import Foundation

/// Windowed direct-RPC routing for `syncAccounts`. Splits an in-flight
/// account list into the crypto accounts the resumable, determinate
/// `WindowedWalletSyncRunner` can scan window-by-window and the rest (the
/// Alchemy path plus every non-crypto source) that keep today's single-shot
/// build → apply batch. Kept out of `SyncedAccountStore+Internals.swift` so
/// both files stay under the project's `file_length` budget along a
/// semantic seam (windowed routing vs. the shared build/apply pipeline).
extension SyncedAccountStore {

  /// Outcome of routing one account to the windowed runner. `.windowed`
  /// carries the account's genuinely-new survivors (the runner already
  /// built + applied + checkpointed every window); `.fallBackToSingleShot`
  /// means the provider couldn't report a head (Alchemy path) so the
  /// account must take the generic build → apply batch instead — nothing
  /// was read or written by the runner in that case.
  private enum WindowedSyncOutcome {
    case windowed([Transaction])
    case fallBackToSingleShot
  }

  /// Routes each in-flight account, returning the union of every windowed
  /// account's genuinely-new survivors plus the accounts that must still go
  /// through the single-shot batch.
  ///
  /// The runners run **sequentially** — they are `@MainActor` and apply
  /// serially anyway, and a deterministic order keeps cross-account transfer
  /// pairing (via the apply pass's persisted-leg lookup) reproducible rather
  /// than interleaving per-window applies across accounts. An account with
  /// no windowed runner wired, or no resolvable `ChainConfig` (exchanges,
  /// unsupported chains), goes straight to the single-shot list.
  func routeThroughWindowedRunner(
    _ inputs: [Account]
  ) async -> (windowedNew: [Transaction], singleShotInputs: [Account]) {
    var windowedNew: [Transaction] = []
    var singleShotInputs: [Account] = []
    for account in inputs {
      guard let runner = windowedRunner, let chain = windowedChain(for: account) else {
        singleShotInputs.append(account)
        continue
      }
      switch await runWindowedSync(account: account, chain: chain, runner: runner) {
      case .windowed(let genuinelyNew):
        windowedNew.append(contentsOf: genuinelyNew)
      case .fallBackToSingleShot:
        singleShotInputs.append(account)
      }
    }
    return (windowedNew, singleShotInputs)
  }

  /// Resolves the `ChainConfig` an account should be windowed on, or `nil`
  /// when the account is not a supported on-chain wallet (no `chainId`, or a
  /// `chainId` outside the supported set — exchanges land here). Uses the
  /// single global `ChainConfig` lookup so the routing stays provider-neutral
  /// (the store never inspects `account.type`).
  private func windowedChain(for account: Account) -> ChainConfig? {
    guard let chainId = account.chainId else { return nil }
    return ChainConfig.config(for: chainId)
  }

  /// Runs one account through the windowed runner, translating its result
  /// (and any thrown error) into a `WindowedSyncOutcome`. Progress is
  /// published through `setSyncProgress` as the runner walks its windows;
  /// the `syncAccounts` `defer` clears it once the cycle ends.
  ///
  /// Error containment mirrors the single-shot build phase. Both a per-window
  /// build/apply failure AND a mid-scan cancellation come back inside
  /// `RunResult` (NOT as a throw): every transaction the windows before the
  /// stop already persisted-and-checkpointed still flows into `.windowed(...)`
  /// so it reaches this cycle's single transfer-detection pass (which runs
  /// regardless of `Task.isCancelled`). A per-window failure carries a
  /// non-nil `windowError` → `lastError` is recorded (without rewinding the
  /// checkpoint); a cancellation carries `windowError == nil` → no error row.
  /// Only a PRE-scan throw (`currentHead` succeeded but
  /// `validatedWalletAddress` / `resolveFromBlock` / their cancellation
  /// checks threw, or — on the already-caught-up branch — `resolvePriorBlock`
  /// or the empty-`candidates` watermark-refresh `apply` threw, all before any
  /// window was scanned) propagates out of `run`; the `catch` clauses below
  /// handle just that case. Either way the account is done for this cycle — it
  /// is never also sent through the single-shot batch, which would re-scan
  /// from the same checkpoint.
  private func runWindowedSync(
    account: Account, chain: ChainConfig, runner: WindowedWalletSyncRunner
  ) async -> WindowedSyncOutcome {
    do {
      let result = try await runner.run(account: account, chain: chain) { progress in
        self.setSyncProgress(progress, for: account.id)
      }
      guard result.didWindowedScan else { return .fallBackToSingleShot }
      // A mid-scan window failure records the error but keeps this run's
      // already-committed survivors in the union detection runs over.
      if let windowError = result.windowError {
        await persistWindowedError(windowError, for: account)
      }
      return .windowed(result.genuinelyNew)
    } catch is CancellationError {
      // Pre-scan cancellation — nothing persisted yet; never write an error row.
      return .windowed([])
    } catch {
      // Pre-scan failure — nothing persisted yet; record the error.
      await persistWindowedError(error, for: account)
      return .windowed([])
    }
  }

  /// Records `lastError` for a windowed account whose scan threw mid-run.
  ///
  /// Two watermarks are treated differently, on purpose:
  ///
  /// - `lastSyncedBlockNumber` takes the **freshest persisted** value (the
  ///   runner's per-window applies advanced it as each window completed), so
  ///   the error row keeps the resume point rather than rewinding to the
  ///   pre-sync watermark.
  /// - `lastSyncedAt` takes the **pre-cycle** value from the in-memory cache,
  ///   NOT the per-window `now` the completed windows wrote. This mirrors the
  ///   single-shot build phase's invariant (`persistError`'s doc comment:
  ///   "`lastSyncedAt` is intentionally not updated on failure"): the hourly
  ///   stale-check keys purely on `lastSyncedAt`, so carrying a fresh
  ///   timestamp onto a failed, not-yet-caught-up account would suppress its
  ///   retry for up to `staleThreshold`. Keeping it stale lets the next tick
  ///   resume from the checkpoint.
  private func persistWindowedError(_ error: any Error, for account: Account) async {
    let walletError =
      (error as? WalletSyncError)
      ?? .network(underlyingDescription: error.localizedDescription)
    let cached = statePerAccount[account.id]
    let persistedBlock: UInt64?
    do {
      persistedBlock = try await walletSyncState.load(
        accountId: account.id)?.lastSyncedBlockNumber
    } catch {
      persistedBlock = nil
    }
    // Synthesise the prior state `persistError` copies from: freshest block
    // (resume point) + pre-cycle `lastSyncedAt` (staleness).
    let priorState = WalletSyncState(
      id: account.id,
      lastSyncedBlockNumber: persistedBlock ?? cached?.lastSyncedBlockNumber ?? 0,
      lastSyncedAt: cached?.lastSyncedAt ?? .distantPast,
      lastError: nil)
    await Self.persistError(
      walletError,
      accountId: account.id,
      priorState: priorState,
      walletSyncState: walletSyncState)
  }
}
