// Shared/CryptoImport/ChainConfig.swift
import Foundation

/// Per-chain config for the crypto wallet importer.
///
/// Covers Ethereum, OP Mainnet, and Base. Extending to other EVM chains
/// (Arbitrum, Avalanche, …) is purely additive — add a new entry to `all`.
/// Polygon is not supported because it has no first-party public Blockscout
/// instance; existing Polygon accounts degrade gracefully via the
/// `ChainConfig.config(for:) == nil → skipped` path.
struct ChainConfig: Sendable, Hashable {
  /// EVM chain identifier (e.g. 1 for Ethereum mainnet).
  let chainId: Int

  /// Alchemy network slug, e.g. `eth-mainnet`, `opt-mainnet`,
  /// `base-mainnet`. Used as the path component for the JSON-RPC endpoint
  /// hostname (`https://<slug>.g.alchemy.com/v2/<key>`).
  let alchemyNetworkSlug: String

  /// The instrument used as the chain's native token (gas) — ETH for
  /// Ethereum, OP Mainnet, and Base.
  let nativeInstrument: Instrument

  /// `true` if Alchemy's `internal` transfer category is requested for
  /// this chain. Currently `false` for all supported chains because
  /// Blockscout is the authoritative source for internal ETH transfers
  /// on every supported chain, and requesting `internal` from Alchemy
  /// would produce rows that `WalletSyncEngine` discards.
  let supportsInternalTransfers: Bool

  /// `true` on OP-stack rollups (Optimism, Base), where the transaction
  /// fee is the L2 execution fee *plus* an L1 data fee for posting the
  /// transaction's calldata to Ethereum. The L1 component is usually the
  /// dominant cost. `false` on chains where `gasUsed * effectiveGasPrice`
  /// is the whole fee (Ethereum L1, Polygon). Gates whether `makeGasLeg`
  /// adds `AlchemyTransactionReceipt.l1FeeWei` to the gas-leg quantity —
  /// see #920.
  let chargesL1DataFee: Bool

  /// Block-explorer base URL (no trailing slash). Used by
  /// `BlockExplorerLink` to render outbound transaction links.
  let blockExplorerBaseURL: URL

  /// Blockscout public-instance API base URL (no trailing slash), e.g.
  /// `https://eth.blockscout.com`. Used by `LiveBlockscoutClient` for the
  /// `/api/v2/addresses/{address}/transactions` and
  /// `/internal-transactions` endpoints. Every supported chain has a
  /// first-party public Blockscout instance; Polygon does not, which is
  /// why it is not a supported chain.
  let blockscoutAPIBaseURL: URL

  /// Default public JSON-RPC endpoint (dRPC's keyless `<chain>.drpc.org`
  /// public nodes), used for direct on-chain calls that don't go through
  /// Alchemy. dRPC is used in preference to publicnode because publicnode's
  /// gateway rejects `eth_getLogs` without a contract `address`
  /// (`-32701 "Please specify an address"`) and gates archive ranges behind
  /// a paid token — both of which break the topics-only, cross-contract,
  /// full-history Transfer scan in `DirectRPCChainClient`. dRPC's keyless
  /// public nodes serve that exact query (topics-only + archive) for free.
  let defaultRPCURL: URL

  /// The earliest block a never-synced wallet's log scan should start from.
  /// Genesis (block 0) never carries logs, so most chains start at block 1.
  /// OP Mainnet is the exception: its Bedrock fork (block 105_235_063)
  /// migrated the chain to the current state/log format, and pre-Bedrock
  /// (OVM) history has no scannable ERC-20 `Transfer` logs — a pruned OP
  /// node answers a pre-Bedrock `eth_getLogs` with `4444 pruned history
  /// unavailable`, which would otherwise fail the whole sync. Clamping the
  /// start block up to this value keeps the scan inside the range every
  /// node can serve. The clamp is applied uniformly to every source
  /// (Blockscout native/internal transactions and Alchemy/direct-RPC ERC-20
  /// logs) — pre-Bedrock OP Mainnet history is intentionally discarded
  /// everywhere, not only where a pruned node forces it. See
  /// `WalletSyncEngine.build`.
  let earliestScannableBlock: UInt64

  /// Human-readable name for the chain picker / settings UI.
  let displayName: String

  /// All supported chains, indexed by `chainId` order. The chain
  /// picker renders this in declaration order; stable across launches.
  static let all: [ChainConfig] = [
    .ethereum, .optimism, .base,
  ]

  /// Lookup by EVM chain ID. Returns `nil` for unsupported chains.
  static func config(for chainId: Int) -> ChainConfig? {
    all.first { $0.chainId == chainId }
  }
}

extension ChainConfig {
  /// Ethereum mainnet — chain 1. Native token: ETH (18 decimals).
  /// Blockscout is the authoritative internal-ETH source; Alchemy
  /// `internal` is not requested. As an L1 it charges no L1 data fee.
  static let ethereum = ChainConfig(
    chainId: 1,
    alchemyNetworkSlug: "eth-mainnet",
    nativeInstrument: Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    supportsInternalTransfers: false,
    chargesL1DataFee: false,
    blockExplorerBaseURL: requireURL("https://etherscan.io"),
    blockscoutAPIBaseURL: requireURL("https://eth.blockscout.com"),
    defaultRPCURL: requireURL("https://eth.drpc.org"),
    earliestScannableBlock: 1,
    displayName: "Ethereum"
  )

  /// OP Mainnet (Optimism) — chain 10. Native token: ETH (18 decimals).
  /// Blockscout is the authoritative internal-ETH source; Alchemy
  /// `internal` is not requested. OP-stack rollup: charges an L1 data
  /// fee on top of L2 execution.
  ///
  /// `nativeInstrument` is the canonical mainnet ETH instrument (`1:native`);
  /// chain-of-holding comes from the account, not the instrument.
  static let optimism = ChainConfig(
    chainId: 10,
    alchemyNetworkSlug: "opt-mainnet",
    nativeInstrument: Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    supportsInternalTransfers: false,
    chargesL1DataFee: true,
    blockExplorerBaseURL: requireURL("https://optimistic.etherscan.io"),
    // Optimism's Blockscout instance was rehosted: optimism.blockscout.com
    // now 301-redirects every path to explorer.optimism.io. Point directly
    // at the canonical host (Ethereum/Base still use *.blockscout.com).
    blockscoutAPIBaseURL: requireURL("https://explorer.optimism.io"),
    defaultRPCURL: requireURL("https://optimism.drpc.org"),
    // Bedrock fork activation (2023-06-06). Pre-Bedrock OVM history has no
    // scannable ERC-20 Transfer logs and is unavailable on pruned nodes.
    earliestScannableBlock: 105_235_063,
    displayName: "OP Mainnet"
  )

  /// Base — chain 8453. Native token: ETH (18 decimals).
  /// Blockscout is the authoritative internal-ETH source; Alchemy
  /// `internal` is not requested. OP-stack rollup: charges an L1 data
  /// fee on top of L2 execution.
  ///
  /// `nativeInstrument` is the canonical mainnet ETH instrument (`1:native`);
  /// chain-of-holding comes from the account, not the instrument.
  static let base = ChainConfig(
    chainId: 8453,
    alchemyNetworkSlug: "base-mainnet",
    nativeInstrument: Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
    supportsInternalTransfers: false,
    chargesL1DataFee: true,
    blockExplorerBaseURL: requireURL("https://basescan.org"),
    blockscoutAPIBaseURL: requireURL("https://base.blockscout.com"),
    defaultRPCURL: requireURL("https://base.drpc.org"),
    // Base launched post-Bedrock, so its full history is scannable; genesis
    // (block 0) carries no logs, so the scan starts at block 1.
    earliestScannableBlock: 1,
    displayName: "Base"
  )

  /// Compile-time URL constructor. The hardcoded literals above are valid
  /// URLs by inspection; a `nil` here is a programmer error rather than a
  /// runtime failure mode, so `preconditionFailure` is the honest spelling
  /// (we don't want to paper over a typo with a bogus fallback URL).
  private static func requireURL(_ string: String) -> URL {
    guard let url = URL(string: string) else {
      preconditionFailure("ChainConfig: malformed URL literal \(string)")
    }
    return url
  }
}
