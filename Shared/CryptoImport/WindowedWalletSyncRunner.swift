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
  /// exactly as the single-shot path's return). `didWindowedScan` is
  /// `false` only when the provider can't report a head block — the caller
  /// then falls back to the single-shot `build`/apply path.
  struct RunResult: Sendable {
    let genuinelyNew: [Transaction]
    let didWindowedScan: Bool
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
  /// Throwing / cancellation contract: `Task.checkCancellation()` runs at
  /// the top of every window, and any error from the scan/build/apply of
  /// window `k` propagates out unswallowed. Because each earlier window
  /// already applied-then-checkpointed, the durable checkpoint sits at
  /// window `k-1`'s end when this throws — exactly the resume point. The
  /// caller records `lastError`; the next run picks up from the checkpoint.
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

    // Already caught up (or a reorg-window that sits above head): report
    // complete and return without a fetch. `resolveFromBlock` can exceed a
    // freshly-observed `head` when a peer's synced checkpoint is ahead of
    // this provider's reported head; scanning `[from, head]` would be empty
    // anyway, so skip straight to done.
    guard from <= head else {
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
      // Honour cancellation at the window boundary: everything applied so
      // far is already checkpointed, so a throw here resumes cleanly.
      try Task.checkCancellation()

      let nativeInWindow = WalletSyncWindowMath.partition(
        context.nativeRows, into: window)
      let build = try await engine.buildWindow(
        account: account,
        chain: chain,
        walletAddress: walletAddress,
        window: window.from...window.to,
        headForRecord: window.to,
        nativeRowsInWindow: nativeInWindow,
        signedGasTxs: context.signedGasTxs,
        prefetchedReceipts: context.prefetchedReceipts)

      // The apply pass persists this window's transactions AND advances
      // both the local `WalletSyncState` and the synced checkpoint to
      // `window.to` — even for an empty window, because `headBlockNumber`
      // is the window end regardless of `candidates`.
      let input = WalletApplyEngine.AccountInput(
        account: account, headBlockNumber: window.to, candidates: build.candidates)
      let persisted = try await applyEngine.apply(perAccount: [input])
      genuinelyNew.append(contentsOf: persisted)

      progress(
        .scanning(
          fraction: WalletSyncWindowMath.fraction(
            pos: window.to, from: from, head: head)))
    }

    return RunResult(genuinelyNew: genuinelyNew, didWindowedScan: true)
  }
}
