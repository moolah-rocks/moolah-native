// Shared/CryptoImport/WindowedWalletSyncRunner.swift
import Foundation

/// Per-account runner for the resumable, determinate direct-RPC wallet
/// sync. Where `WalletSyncEngine.build` does one unbounded scan-to-head and
/// hands a single watermark to the apply pass, this runner slices
/// `[from, head]` into fixed block windows and, for each window, scans →
/// builds → applies → checkpoints as a unit, publishing determinate
/// progress as it goes.
///
/// Why per-window apply matters: the checkpoint is advanced ONLY by the
/// apply pass (`AccountInput.headBlockNumber = window.to`), so a scan
/// interrupted after window `k` (network drop, cancellation, app quit)
/// leaves the durable checkpoint at window `k`'s end. The next run resumes
/// from `checkpoint - 32` (`WalletSyncEngine.resolveFromBlock`) rather than
/// re-scanning the whole range, and empty windows still advance the
/// checkpoint because `headBlockNumber` is the window end regardless of
/// what was found. The runner itself writes NOTHING — `WalletApplyEngine`
/// stays the sole writer of transactions and checkpoints.
///
/// `@MainActor` because it drives `WalletApplyEngine` (itself `@MainActor`)
/// in a sequential per-window loop and publishes progress through a
/// `@MainActor` closure; there is no concurrency to manage here beyond
/// awaiting the engine/apply hops and honouring cancellation between
/// windows.
@MainActor
final class WindowedWalletSyncRunner {
  /// Outcome of one `run`. `genuinelyNew` is every transaction the apply
  /// pass persisted across all windows (transfer detection consumes it,
  /// exactly as the single-shot path's return) — including the windows that
  /// completed *before* a mid-scan failure. `didWindowedScan` is `false`
  /// only when the provider can't report a head block — the caller then
  /// falls back to the single-shot `build`/apply path.
  ///
  /// A mid-loop STOP — either a per-window build/apply failure or a
  /// cooperative cancellation — is surfaced through this `RunResult`, NOT by
  /// throwing (only the pre-loop steps throw; see `run`). The run stops at
  /// that window, the durable checkpoint sits at the last completed window
  /// (per the per-window apply→checkpoint order), and every transaction
  /// persisted before the stop is still carried in `genuinelyNew` so the
  /// caller can feed those already-committed rows to transfer detection —
  /// which `SyncedAccountStore.syncAccounts` runs regardless of
  /// `Task.isCancelled`, so dropping them would permanently lose the pairing.
  ///
  /// `windowError` distinguishes the two stop kinds:
  /// - non-nil (a genuine error) → the caller records it on the account's
  ///   `WalletSyncState.lastError`;
  /// - `nil` on a cancellation → NOT an error, so the caller writes no
  ///   `lastError` row.
  ///
  /// Do not "restore" a throw on the per-window path: it would discard the
  /// survivors above and reintroduce the lost-pairing gap.
  ///
  /// Not `Sendable`: `windowError` holds an arbitrary `any Error` (a
  /// repository error from the apply pass need not be `Sendable`). `run`
  /// and its sole caller (`SyncedAccountStore`) are both `@MainActor`, so
  /// the value never crosses an isolation boundary.
  struct RunResult {
    let genuinelyNew: [Transaction]
    let didWindowedScan: Bool
    let windowError: (any Error)?

    init(
      genuinelyNew: [Transaction],
      didWindowedScan: Bool,
      windowError: (any Error)? = nil
    ) {
      self.genuinelyNew = genuinelyNew
      self.didWindowedScan = didWindowedScan
      self.windowError = windowError
    }
  }

  private let engine: WalletSyncEngine
  private let chainClient: any ChainDataClient
  private let applyEngine: WalletApplyEngine
  /// Number of blocks each scan-apply-checkpoint window covers. Coarser
  /// than the direct-RPC client's internal `eth_getLogs` sub-batching
  /// (`AdaptiveLogRangeBatcher`): this is the checkpoint granularity — how
  /// much progress a single interruption can cost — not the per-request
  /// range cap. A smaller value checkpoints more often (cheaper resume,
  /// more apply passes); the default trades a modest number of apply
  /// passes for a bounded re-scan on resume.
  private let segmentBlockWindow: UInt64

  /// Default checkpoint-window width. 250k blocks is ~5 weeks of L1 blocks
  /// and a few days of L2 — coarse enough that a fully-synced wallet walks
  /// only a handful of windows per catch-up, fine enough that an
  /// interruption costs at most one window's re-scan on resume.
  ///
  /// `nonisolated` so it can be the `init` default argument without forcing
  /// a nonisolated caller to hop to the main actor just to read a constant.
  nonisolated static let defaultSegmentBlockWindow: UInt64 = 250_000

  init(
    engine: WalletSyncEngine,
    chainClient: any ChainDataClient,
    applyEngine: WalletApplyEngine,
    segmentBlockWindow: UInt64 = WindowedWalletSyncRunner.defaultSegmentBlockWindow
  ) {
    self.engine = engine
    self.chainClient = chainClient
    self.applyEngine = applyEngine
    self.segmentBlockWindow = segmentBlockWindow
  }

  /// Scans `account` on `chain` window by window, applying and
  /// checkpointing each, and publishes `.scanning(fraction:)` progress.
  ///
  /// Returns `didWindowedScan == false` (without touching any repository)
  /// when the provider can't report a current head — the caller falls back
  /// to the single-shot path. Otherwise walks every window to `head`,
  /// returning the transactions persisted across them.
  ///
  /// Stop / cancellation contract: `Task.checkCancellation()` runs at the top
  /// of every window, and the scan/build/apply of each window is wrapped in a
  /// do/catch. A mid-loop STOP does NOT throw out of `run` — it RETURNS a
  /// `RunResult` carrying the survivors of the windows already applied: a
  /// per-window error returns with `windowError` set; a `CancellationError`
  /// returns with `windowError == nil` (cancellation is not an error). Because
  /// each earlier window already applied-then-checkpointed, the durable
  /// checkpoint sits at window `k-1`'s end at the stop — exactly the resume
  /// point — and the survivors still reach the caller's transfer-detection
  /// pass. Only the PRE-loop steps throw: `currentHead`,
  /// `validatedWalletAddress`, `resolveFromBlock`, their cancellation checks,
  /// and — on the already-caught-up branch (`from > head`) —
  /// `resolvePriorBlock` plus the empty-`candidates` `apply` that refreshes
  /// `lastSyncedAt`. All of these throw before any window is scanned, and the
  /// caught-up `apply` writes only the watermark (its persist/dedup/rules
  /// stages are no-ops on an empty candidate set), so a throw there leaves
  /// nothing half-persisted. See `RunResult` for the caller contract.
  func run(
    account: Account,
    chain: ChainConfig,
    progress: @MainActor (WalletSyncProgress) -> Void
  ) async throws -> RunResult {
    // A provider with no block-range head (Alchemy's higher-level transfer
    // API) can't be windowed — bail so the caller runs the single-shot
    // path. Nothing has been read or written yet, so this is a clean no-op.
    guard let head = try await chainClient.currentHead(chain: chain) else {
      return RunResult(genuinelyNew: [], didWindowedScan: false)
    }
    // Bail before any further I/O if the task was cancelled during the head
    // fetch — nothing is written yet, so this is a clean early-out.
    try Task.checkCancellation()

    // Validate up front (mirrors `build`) so a malformed account throws
    // before any window work rather than force-unwrapping a nil address.
    let walletAddress = try engine.validatedWalletAddress(for: account)
    let from = try await engine.resolveFromBlock(for: account)
    try Task.checkCancellation()

    // Already caught up (or a reorg-window that sits above head): the scan
    // range `[from, head]` is empty, so skip straight to done — but still
    // refresh `lastSyncedAt` so the account doesn't stay perpetually stale
    // and re-trigger every cycle. `from` can exceed a freshly-observed
    // `head` when a peer's synced checkpoint is ahead of this provider's
    // reported head. Mirror the single-shot path, which stamps
    // `lastSyncedAt = now` while keeping `lastSyncedBlockNumber` at the prior
    // checkpoint: apply an EMPTY input whose `headBlockNumber` is the RAW
    // prior checkpoint (`resolvePriorBlock`, NOT the reorg-subtracted `from`,
    // which is below head here). `WalletApplyEngine.updateSyncState` writes
    // `lastSyncedBlockNumber = headBlockNumber` directly, so passing the prior
    // checkpoint keeps the block from being lowered while still stamping a
    // fresh `lastSyncedAt`; `priorBlock >= the stored watermark` (it is a
    // `max`), so it can only hold or raise, never regress. `candidates: []`
    // means `apply`'s persist/dedup/rules stages are all no-ops — the only
    // durable effect is the watermark refresh — so a throw here (or the
    // cancellation check just before it) leaves nothing half-written.
    guard from <= head else {
      try Task.checkCancellation()
      let priorBlock = try await engine.resolvePriorBlock(for: account)
      let input = WalletApplyEngine.AccountInput(
        account: account, headBlockNumber: priorBlock, candidates: [])
      _ = try await applyEngine.apply(perAccount: [input])
      progress(.scanning(fraction: 1.0))
      return RunResult(genuinelyNew: [], didWindowedScan: true)
    }

    // Fetch the native context once for the whole range; each window takes
    // the slice of `nativeRows` whose block falls inside it.
    let context = try await engine.fetchNativeContext(
      account: account, chain: chain, walletAddress: walletAddress, fromBlock: from)

    // Seed progress at 0 so the UI starts a determinate bar immediately
    // rather than jumping to the first window's fraction.
    progress(.scanning(fraction: WalletSyncWindowMath.fraction(pos: from, from: from, head: head)))

    var genuinelyNew: [Transaction] = []
    let windows = WalletSyncWindowMath.windows(
      from: from, head: head, size: segmentBlockWindow)
    for window in windows {
      do {
        // Honour cancellation at the window boundary: everything applied so
        // far is already checkpointed, and the `catch is CancellationError`
        // below returns those survivors, so a stop here resumes cleanly.
        try Task.checkCancellation()

        let persisted = try await buildAndApplyWindow(
          account: account,
          chain: chain,
          walletAddress: walletAddress,
          window: window,
          context: context)
        genuinelyNew.append(contentsOf: persisted)

        progress(
          .scanning(
            fraction: WalletSyncWindowMath.fraction(
              pos: window.to, from: from, head: head)))
      } catch is CancellationError {
        // Cooperative cancellation mid-scan: NOT an error (no `windowError`,
        // so the caller writes no `lastError`), but the windows already
        // applied-and-checkpointed before the cancellation still flow to
        // detection this cycle. `SyncedAccountStore.syncAccounts` runs
        // detection regardless of `Task.isCancelled` (there is no gate between
        // routing and detection), so dropping these survivors would
        // permanently lose the pairing opportunity — they are not
        // `genuinelyNew` next cycle — rather than merely skip a pass. The
        // durable checkpoint sits at the last completed window; the next run
        // resumes from there.
        return RunResult(genuinelyNew: genuinelyNew, didWindowedScan: true, windowError: nil)
      } catch {
        // A genuine per-window build/apply failure. Stop the scan but return
        // every transaction the earlier windows already persisted-and-
        // checkpointed, so the caller records the error AND still feeds those
        // committed rows to transfer detection. The durable checkpoint is the
        // last completed window's end; the next run resumes from there.
        return RunResult(
          genuinelyNew: genuinelyNew, didWindowedScan: true, windowError: error)
      }
    }

    return RunResult(genuinelyNew: genuinelyNew, didWindowedScan: true)
  }

  /// Builds and applies ONE window, returning the transactions the apply
  /// pass persisted for it.
  ///
  /// Partitions BOTH the native rows AND the signed-gas set by block: a
  /// signed tx belongs to the window whose real transfer it pays gas for
  /// (they are the same on-chain transaction, so they share a block).
  /// Passing the whole signed set to every window instead would synthesise
  /// a phantom gas-only transaction in an earlier window — whose
  /// `"<hash>:gas"` leg then deduped the real transfer's gas leg out of its
  /// own later window — and re-fetch that hash's receipt once per window.
  /// `prefetchedReceipts` stays whole: it's a hash→receipt lookup cache
  /// consumed only for this window's own transfers/signed txs, so an
  /// out-of-window entry simply goes unused rather than producing a leg.
  ///
  /// The apply pass advances both the local `WalletSyncState` and the synced
  /// checkpoint to `window.to` even for an empty window, because
  /// `headBlockNumber` is the window end regardless of `candidates`.
  private func buildAndApplyWindow(
    account: Account,
    chain: ChainConfig,
    walletAddress: String,
    window: WalletSyncWindow,
    context: WalletSyncNativeContext
  ) async throws -> [Transaction] {
    let build = try await engine.buildWindow(
      account: account,
      chain: chain,
      walletAddress: walletAddress,
      window: window.from...window.to,
      headForRecord: window.to,
      nativeRowsInWindow: WalletSyncWindowMath.partition(context.nativeRows, into: window),
      signedGasTxs: WalletSyncWindowMath.partition(context.signedGasTxs, into: window),
      prefetchedReceipts: context.prefetchedReceipts)
    let input = WalletApplyEngine.AccountInput(
      account: account, headBlockNumber: window.to, candidates: build.candidates)
    return try await applyEngine.apply(perAccount: [input])
  }
}
