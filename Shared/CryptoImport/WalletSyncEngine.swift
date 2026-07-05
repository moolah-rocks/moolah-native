// Shared/CryptoImport/WalletSyncEngine.swift
import Foundation
import OSLog

/// Result of one per-account build pass. Stage 9's apply pass needs
/// both the candidate transactions and the head block number so it can
/// advance `WalletSyncState.lastSyncedBlockNumber`. Returned together
/// (rather than threading the head block through `BuiltTransaction`) so
/// the build phase has a single, type-safe handoff to the apply phase.
///
/// `headBlockNumber` is the largest block number observed across the
/// fetched transfers. When the fetch returns no transfers (e.g. account
/// has no recent activity), the value falls back to the prior
/// `lastSyncedBlockNumber` so the next cycle's reorg-window math still
/// holds, or `0` on a genesis-style fetch. The watermark is intentionally
/// advanced even when the builder dropped every transfer — holding it
/// would make inactive accounts re-query an ever-growing range. The
/// "raw transfers returned but zero candidates produced" pattern is
/// instead surfaced as a `warning` log so a wire-format regression is
/// visible without stranding inactive wallets.
struct WalletSyncBuildResult: Sendable, Hashable {
  let candidates: [BuiltTransaction]
  let headBlockNumber: UInt64
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
    try Task.checkCancellation()

    // 2. Determine fromBlock (reorg window — re-fetch covers the last
    //    32 blocks below the prior checkpoint).
    let priorBlock = try await resolvePriorBlock(for: account)
    let fromBlock = priorBlock == 0 ? 0 : Self.subtractingReorgWindow(priorBlock)

    // 3. Native + internal ETH from Blockscout (authoritative tx index;
    //    sees approve()/failed/zero-movement #919 and OP-stack internal
    //    transfers #918). A failure here is a sync error for this
    //    account — it propagates to CryptoSyncStore's persistError.
    try Task.checkCancellation()
    let adapted = try await fetchBlockscout(
      chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)

    // 3b. Wrap/unwrap synthesis: recovers the WETH leg a native-only view
    //     of an ETH↔WETH movement omits (invisible to both Alchemy's
    //     transfer API and the mint/burn guard). Runs off the Blockscout
    //     native set fetched above.
    try Task.checkCancellation()
    let wrapUnwrap = try await wrapUnwrapDetector.detect(
      nativeTransfers: adapted.transfers, chain: chain, walletAddress: walletAddress)

    // 3c. ERC-20 only from Alchemy — Blockscout owns native/internal.
    try Task.checkCancellation()
    let alchemyAll = try await alchemy.getAssetTransfers(
      chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)
    let transfers =
      adapted.transfers + wrapUnwrap.rows + alchemyAll.filter { $0.category == .erc20 }
    try Task.checkCancellation()

    // 4. Head block over the merged set (Blockscout blockNum included).
    let headBlock = Self.maxBlockNumber(in: transfers) ?? priorBlock

    // 5. Build candidates. Discovery actor handles its own coalescing;
    //    no repository writes happen here.
    let builder = TransferEventBuilder()
    let importOrigin = importOriginFactory(account.id)
    let built = try await builder.build(
      transfers: transfers,
      account: account,
      services: BuilderServices(
        chain: chain, discovery: discovery, alchemy: alchemy),
      importOrigin: importOrigin,
      signedGasTxs: adapted.signedGasTxs,
      prefetchedReceipts: wrapUnwrap.receipts)

    // 6. Observability for wire-format regressions: if Alchemy returned
    //    rows but every one dropped at the builder, that's the symptom
    //    of a decoder bug (malformed amount, unknown category…). Log
    //    loudly so the next regression doesn't recreate the silent
    //    "synced ok, zero transactions" failure mode that hid the
    //    `rawContract.value` JSON-key mismatch in production.
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
    return WalletSyncBuildResult(candidates: built, headBlockNumber: headBlock)
  }

  /// The higher of this device's local `WalletSyncState` and the
  /// cross-device synced checkpoint. A device whose local state trails (or
  /// is absent) starts its fetch from a peer's checkpoint instead of a
  /// genesis-style scan. The synced load is best-effort (`try?`): a
  /// transient checkpoint read failure falls back to the local watermark
  /// rather than failing the whole sync cycle.
  private func resolvePriorBlock(for account: Account) async throws -> UInt64 {
    let localState = try await walletSyncState.load(accountId: account.id)
    let syncedBlock =
      (try? await checkpoints.load(accountId: account.id))?.lastSyncedBlockNumber ?? 0
    return max(localState?.lastSyncedBlockNumber ?? 0, syncedBlock)
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
