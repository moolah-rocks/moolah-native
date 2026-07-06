// Shared/CryptoImport/WalletSyncEngine.swift
import Foundation
import OSLog

/// Result of one per-account build pass. Stage 9's apply pass needs
/// both the candidate transactions and the head block number so it can
/// advance `WalletSyncState.lastSyncedBlockNumber`. Returned together
/// (rather than threading the head block through `BuiltTransaction`) so
/// the build phase has a single, type-safe handoff to the apply phase.
///
/// `headBlockNumber`'s derivation depends on which primitive produced
/// it:
/// - `build()` uses the largest block number observed across the
///   fetched transfers, falling back to the prior `lastSyncedBlockNumber`
///   so the next cycle's reorg-window math still holds, or `0` on a
///   genesis-style fetch.
/// - `buildWindow()` echoes the caller-supplied window end verbatim,
///   regardless of what was observed, so a window with no activity still
///   advances the checkpoint deterministically to the block the window
///   actually scanned through.
///
/// Either way, the watermark is intentionally advanced even when the
/// builder dropped every transfer — holding it would make inactive
/// accounts re-query an ever-growing range. The "raw transfers returned
/// but zero candidates produced" pattern is instead surfaced as a
/// `warning` log so a wire-format regression is visible without
/// stranding inactive wallets.
struct WalletSyncBuildResult: Sendable, Hashable {
  let candidates: [BuiltTransaction]
  let headBlockNumber: UInt64
}

/// The Blockscout native + internal + wrap/unwrap set for an account,
/// fetched once from `fetchNativeContext(fromBlock:)`. A windowed sync
/// runner partitions BOTH `nativeRows` and `signedGasTxs` by block per
/// window (a signed tx shares its transfer event's block) and passes the
/// matching slices to `buildWindow`. `prefetchedReceipts` stays whole —
/// it's a hash→receipt lookup cache consumed only for a window's own
/// transfers/signed txs, so an out-of-window entry simply goes unused.
struct WalletSyncNativeContext: Sendable {
  let nativeRows: [AlchemyTransfer]
  let signedGasTxs: [SignedGasTx]
  let prefetchedReceipts: [String: AlchemyTransactionReceipt]
}

/// Per-account orchestrator of the build phase. **No repository writes.**
/// Stage 7's apply pass consumes `WalletSyncBuildResult` and persists.
///
/// The engine is a `Sendable` struct — every dependency is itself `Sendable`
/// (actor or stateless) and there is no mutable state on `Self`. This makes
/// it safe to call concurrently from `Stage 9`'s `withTaskGroup` parallel
/// build phase.
struct WalletSyncEngine: Sendable {
  private let alchemy: any ChainDataClient
  private let blockExplorer: any BlockExplorerClient
  private let discovery: CryptoTokenDiscoveryService
  private let walletSyncState: any WalletSyncStateRepository
  private let checkpoints: any WalletSyncCheckpointRepository
  private let importOriginFactory: @Sendable (UUID) -> ImportOrigin
  /// Recovers the WETH leg a native-only wrap/unwrap movement omits.
  /// Derived from `alchemy` — the same `ChainDataClient` already used for
  /// ERC-20 fetch and receipts — so no separate dependency needs wiring
  /// at construction sites.
  private let wrapUnwrapDetector: WrapUnwrapDetector
  /// Shared static `Logger` — `Logger` is `Sendable`, so a static let is
  /// safe across actor boundaries without per-instance allocation.
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "WalletSyncEngine")

  // MARK: - Init

  /// - Parameters:
  ///   - alchemy: Stage 4's `ChainDataClient`. The engine itself doesn't
  ///     hold the rate limiter — `LiveAlchemyClient` does, so callers
  ///     don't need to plumb it through here.
  ///   - blockExplorer: Authoritative index for native and internal ETH
  ///     transfers. `LiveBlockscoutClient` holds the rate limiter; the
  ///     engine only calls the protocol.
  ///   - discovery: Stage 5's actor-coalesced token registry resolver.
  ///   - walletSyncState: Per-device sync checkpoint store. The engine
  ///     reads `lastSyncedBlockNumber` to compute `fromBlock`; **it does
  ///     not write back** — Stage 7's apply pass is the single writer.
  ///   - checkpoints: Cross-device synced checkpoint store. Read (never
  ///     written here) so `fromBlock` can start from a peer's higher
  ///     checkpoint when this device's local state trails or is absent.
  ///   - importOriginFactory: Builds an `ImportOrigin` keyed to the
  ///     account being synced. Stage 9 supplies a closure that captures
  ///     the per-cycle session id; tests pass a deterministic factory.
  init(
    alchemy: any ChainDataClient,
    blockExplorer: any BlockExplorerClient,
    discovery: CryptoTokenDiscoveryService,
    walletSyncState: any WalletSyncStateRepository,
    checkpoints: any WalletSyncCheckpointRepository,
    importOriginFactory: @Sendable @escaping (UUID) -> ImportOrigin
  ) {
    self.alchemy = alchemy
    self.blockExplorer = blockExplorer
    self.discovery = discovery
    self.walletSyncState = walletSyncState
    self.checkpoints = checkpoints
    self.importOriginFactory = importOriginFactory
    self.wrapUnwrapDetector = WrapUnwrapDetector(chainClient: alchemy)
  }

  // MARK: - Build phase

  /// Runs the build phase for a single crypto account. Returns the
  /// candidate `BuiltTransaction`s and the head block number the apply
  /// pass should record on `WalletSyncState`. Throws on transient
  /// failures (network, rate-limit, malformed account); the orchestrator
  /// (Stage 9) handles per-account error containment so other accounts
  /// still apply.
  ///
  /// Cancellation: respects `Task.checkCancellation()` between stages.
  /// A cancelled task throws `CancellationError` and writes nothing
  /// anywhere — the apply pass is the single writer regardless.
  func build(
    account: Account, chain: ChainConfig
  ) async throws -> WalletSyncBuildResult {
    // 1. Validate account is a crypto account with required fields.
    let walletAddress = try validatedWalletAddress(for: account)
    try Task.checkCancellation()

    // 2. Determine fromBlock (reorg window — re-fetch covers the last
    //    32 blocks below the prior checkpoint), clamped up to the chain's
    //    earliest scannable block. This clamp is applied uniformly to every
    //    downstream source (Blockscout native/internal + Alchemy/direct-RPC
    //    ERC-20): pre-Bedrock OP Mainnet history is intentionally discarded
    //    across the board, not just where a pruned node forces it. `priorBlock`
    //    is read once here and reused as the step-5 watermark fallback; the
    //    windowed runner reaches the same start via `resolveFromBlock(for:chain:)`.
    let priorBlock = try await resolvePriorBlock(for: account)
    let fromBlock = Self.startBlock(priorBlock: priorBlock, chain: chain)

    // 3. Native + internal ETH from Blockscout, plus wrap/unwrap
    //    synthesis — see `fetchNativeContext`.
    try Task.checkCancellation()
    let context = try await fetchNativeContext(
      account: account, chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)

    // 4. ERC-20 from Alchemy, merged with the native context, and built
    //    into candidates — see `fetchAndBuildCandidates`. `toBlock: nil`
    //    scans to the current head, unlike `buildWindow`, which bounds
    //    the fetch to a caller-chosen window end for resumable scanning.
    try Task.checkCancellation()
    let (transfers, built) = try await fetchAndBuildCandidates(
      account: account,
      chain: chain,
      walletAddress: walletAddress,
      fromBlock: fromBlock,
      toBlock: nil,
      nativeRows: context.nativeRows,
      signedGasTxs: context.signedGasTxs,
      prefetchedReceipts: context.prefetchedReceipts)

    // 5. Head block over the merged set (Blockscout blockNum included).
    //    Unlike `buildWindow`'s deterministic window-end checkpoint, the
    //    single-shot `build` has no caller-supplied window end, so it
    //    falls back to the highest observed block, or the prior
    //    checkpoint when nothing was found.
    let headBlock = Self.maxBlockNumber(in: transfers) ?? priorBlock
    return WalletSyncBuildResult(candidates: built, headBlockNumber: headBlock)
  }

  /// Validates `account` is a crypto account carrying a non-empty wallet
  /// address, returning the address. Throws
  /// `providerMalformedResponse(stage: "account-validation")` otherwise.
  /// Shared by `build` and the windowed sync runner so a malformed account
  /// is rejected identically on both paths (a runner that skipped this
  /// would force-unwrap a `nil` `walletAddress` into `fetchNativeContext`).
  func validatedWalletAddress(for account: Account) throws -> String {
    guard
      account.type == .crypto,
      let walletAddress = account.walletAddress,
      !walletAddress.isEmpty
    else {
      Self.logger.error(
        "WalletSyncEngine: invalid account \(account.id, privacy: .public)"
      )
      throw WalletSyncError.providerMalformedResponse(stage: "account-validation")
    }
    return walletAddress
  }

  // MARK: - Windowed build primitives

  /// Fetches the Blockscout native + internal transfer set for
  /// `[fromBlock, head]` and runs wrap/unwrap synthesis over it, without
  /// touching Alchemy's ERC-20 endpoint or the candidate builder. A
  /// windowed sync runner fetches this once per account and reuses it
  /// across every block window (`nativeRows` and `signedGasTxs` are each
  /// partitioned per window by the caller; `prefetchedReceipts` is a
  /// hash-keyed cache used whole).
  func fetchNativeContext(
    account: Account, chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> WalletSyncNativeContext {
    // Native + internal ETH from Blockscout (authoritative tx index;
    // sees approve()/failed/zero-movement #919 and OP-stack internal
    // transfers #918). A failure here is a sync error for this
    // account — it propagates to CryptoSyncStore's persistError.
    let adapted = try await fetchBlockscout(
      chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)

    // Wrap/unwrap synthesis: recovers the WETH leg a native-only view of
    // an ETH↔WETH movement omits (invisible to both Alchemy's transfer
    // API and the mint/burn guard). Runs off the Blockscout native set
    // fetched above.
    try Task.checkCancellation()
    let wrapUnwrap = try await wrapUnwrapDetector.detect(
      nativeTransfers: adapted.transfers, chain: chain, walletAddress: walletAddress)

    return WalletSyncNativeContext(
      nativeRows: adapted.transfers + wrapUnwrap.rows,
      signedGasTxs: adapted.signedGasTxs,
      prefetchedReceipts: wrapUnwrap.receipts)
  }

  /// Builds candidates for ONE window: ERC-20 logs for `window` merged
  /// with the caller-supplied native rows whose block falls in that same
  /// window, then run through `TransferEventBuilder` exactly as `build`
  /// does today.
  ///
  /// `headForRecord` is the block the apply pass will checkpoint to —
  /// the window's end, chosen by the runner up front. Unlike `build`'s
  /// single-shot watermark, it is returned verbatim rather than derived
  /// from the observed transfers, so a window with no activity still
  /// advances the checkpoint deterministically to the block the window
  /// actually scanned through.
  ///
  /// `from`/`to` are collapsed into a single `window` parameter (rather
  /// than two `UInt64`s) so this stays at 5 non-defaulted parameters —
  /// `function_parameter_count`'s ceiling — without inventing a grouping
  /// type for `account`/`chain`/`walletAddress`, which every primitive
  /// on this engine takes individually.
  func buildWindow(
    account: Account,
    chain: ChainConfig,
    walletAddress: String,
    window: ClosedRange<UInt64>,
    headForRecord: UInt64,
    nativeRowsInWindow: [AlchemyTransfer] = [],
    signedGasTxs: [SignedGasTx] = [],
    prefetchedReceipts: [String: AlchemyTransactionReceipt] = [:]
  ) async throws -> WalletSyncBuildResult {
    let (_, built) = try await fetchAndBuildCandidates(
      account: account,
      chain: chain,
      walletAddress: walletAddress,
      fromBlock: window.lowerBound,
      toBlock: window.upperBound,
      nativeRows: nativeRowsInWindow,
      signedGasTxs: signedGasTxs,
      prefetchedReceipts: prefetchedReceipts)
    return WalletSyncBuildResult(candidates: built, headBlockNumber: headForRecord)
  }

  // MARK: - Private helpers

  /// Shared core of both `build` and `buildWindow`: fetches ERC-20
  /// transfers in `[fromBlock, toBlock ?? currentHead]` from Alchemy,
  /// merges them with the caller-supplied native rows, and runs
  /// `TransferEventBuilder`. Returns the merged raw transfers alongside
  /// the built candidates so `build` can derive its own watermark from
  /// them without a second Alchemy fetch — `buildWindow` doesn't need
  /// the raw transfers, since its checkpoint is the caller-supplied
  /// window end regardless of what was found.
  private func fetchAndBuildCandidates(
    account: Account,
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64,
    toBlock: UInt64? = nil,
    nativeRows: [AlchemyTransfer] = [],
    signedGasTxs: [SignedGasTx] = [],
    prefetchedReceipts: [String: AlchemyTransactionReceipt] = [:]
  ) async throws -> (transfers: [AlchemyTransfer], candidates: [BuiltTransaction]) {
    // ERC-20 only from Alchemy — Blockscout owns native/internal.
    let alchemyAll = try await alchemy.getAssetTransfers(
      chain: chain, walletAddress: walletAddress, fromBlock: fromBlock, toBlock: toBlock)
    let transfers = nativeRows + alchemyAll.filter { $0.category == .erc20 }
    try Task.checkCancellation()

    // Build candidates. Discovery actor handles its own coalescing; no
    // repository writes happen here.
    let builder = TransferEventBuilder()
    let importOrigin = importOriginFactory(account.id)
    let built = try await builder.build(
      transfers: transfers,
      account: account,
      services: BuilderServices(
        chain: chain, discovery: discovery, alchemy: alchemy),
      importOrigin: importOrigin,
      signedGasTxs: signedGasTxs,
      prefetchedReceipts: prefetchedReceipts)

    // Observability for wire-format regressions: if Alchemy returned
    // rows but every one dropped at the builder, that's the symptom of
    // a decoder bug (malformed amount, unknown category…). Log loudly
    // so the next regression doesn't recreate the silent "synced ok,
    // zero transactions" failure mode that hid the `rawContract.value`
    // JSON-key mismatch in production.
    if !transfers.isEmpty, built.isEmpty {
      Self.logger.warning(
        """
        WalletSyncEngine: builder dropped all \
        \(transfers.count, privacy: .public) transfers for account \
        \(account.id, privacy: .public) on chain \
        \(chain.chainId, privacy: .public) — possible wire-format \
        regression. Watermark still advances; check earlier \
        TransferEventBuilder notices for the per-row reason.
        """
      )
    }
    return (transfers, built)
  }

  /// The higher of this device's local `WalletSyncState` and the
  /// cross-device synced checkpoint. A device whose local state trails (or
  /// is absent) starts its fetch from a peer's checkpoint instead of a
  /// genesis-style scan. The synced load is best-effort (`try?`): a
  /// transient checkpoint read failure falls back to the local watermark
  /// rather than failing the whole sync cycle.
  /// Internal (not `private`) so the windowed sync runner can read the
  /// raw prior checkpoint — it needs the un-reorg-adjusted value to stamp
  /// `lastSyncedAt` on the already-caught-up path without lowering
  /// `lastSyncedBlockNumber` (the reorg-subtracted `from` would drop it).
  func resolvePriorBlock(for account: Account) async throws -> UInt64 {
    let localState = try await walletSyncState.load(accountId: account.id)
    let syncedBlock =
      (try? await checkpoints.load(accountId: account.id))?.lastSyncedBlockNumber ?? 0
    return max(localState?.lastSyncedBlockNumber ?? 0, syncedBlock)
  }

  /// The block a scan should start from for `account`: the reorg-window-
  /// adjusted prior checkpoint (`max(localState, syncedCheckpoint) - 32`,
  /// clamped at 0). `build` derives this inline from a `priorBlock` it
  /// already read for its watermark fallback; the windowed sync runner
  /// (which has no such fallback) calls this so both primitives compute an
  /// identical resumable start from the same two repositories, keeping the
  /// reorg-window rule single-sourced.
  func resolveFromBlock(for account: Account) async throws -> UInt64 {
    Self.reorgAdjustedFromBlock(priorBlock: try await resolvePriorBlock(for: account))
  }

  /// Pure reorg-window adjustment shared by `build` and `resolveFromBlock`:
  /// a prior checkpoint of 0 (genesis / never synced) starts at 0; any
  /// higher checkpoint drops the last 32 blocks so a reorg below the
  /// watermark is re-scanned. Factored out so the two entry points can't
  /// drift.
  static func reorgAdjustedFromBlock(priorBlock: UInt64) -> UInt64 {
    priorBlock == 0 ? 0 : subtractingReorgWindow(priorBlock)
  }

  /// Fetches native and internal transfers from Blockscout and returns the
  /// adapted result ready for merging with the Alchemy ERC-20 set.
  private func fetchBlockscout(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> BlockscoutAdaptResult {
    async let native = blockExplorer.nativeTransactions(
      chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)
    async let internalTxs = blockExplorer.internalTransactions(
      chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)
    return BlockscoutTransferAdapter.adapt(
      nativeTxs: try await native,
      internalTxs: try await internalTxs,
      walletAddress: walletAddress.lowercased())
  }

  /// Per design: re-fetch covers `[lastSyncedBlockNumber - 32, head]`.
  /// Returns 0 when the prior checkpoint sits inside the reorg window
  /// (genesis-fetch on a new device).
  static func subtractingReorgWindow(_ block: UInt64) -> UInt64 {
    block > 32 ? block - 32 : 0
  }

  /// The block a scan starts from: the reorg-re-fetch window below the
  /// prior checkpoint (or genesis on a never-synced wallet), clamped up to
  /// the chain's earliest scannable block. The immediate driver is that a
  /// never-synced OP Mainnet wallet would otherwise scan from genesis and a
  /// pruned OP node rejects the pre-Bedrock range with `4444 pruned history
  /// unavailable`, failing the whole sync — but the clamp is applied
  /// uniformly to all sources because pre-Bedrock OP history is discarded by
  /// design, not merely where a pruned node forces it. See
  /// `ChainConfig.earliestScannableBlock`.
  static func startBlock(priorBlock: UInt64, chain: ChainConfig) -> UInt64 {
    // `subtractingReorgWindow(0) == 0`, so no `priorBlock == 0` special case
    // is needed — genesis falls through to the chain-floor clamp below.
    max(chain.earliestScannableBlock, subtractingReorgWindow(priorBlock))
  }

  /// Maximum `blockNum` parsed from a list of `AlchemyTransfer`s as
  /// `UInt64`. Returns `nil` when the list is empty or every entry has
  /// an unparseable `blockNum` field — the caller falls back to the
  /// prior checkpoint so the watermark only advances on a confirmed
  /// fetch result. Internal so Stage 9 can reuse the same parse rule
  /// from tests.
  static func maxBlockNumber(in transfers: [AlchemyTransfer]) -> UInt64? {
    var maximum: UInt64?
    for transfer in transfers {
      guard let value = RPCHex.parseUInt64(transfer.blockNum) else { continue }
      if let current = maximum {
        maximum = Swift.max(current, value)
      } else {
        maximum = value
      }
    }
    return maximum
  }
}
