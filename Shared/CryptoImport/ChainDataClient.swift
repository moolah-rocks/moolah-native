// Shared/CryptoImport/ChainDataClient.swift
import Foundation

/// Provider-neutral seam for on-chain data (asset transfers and transaction
/// receipts). Conformers are `LiveAlchemyClient`, `DirectRPCChainClient`
/// (raw JSON-RPC), and `RoutingChainDataClient` (dispatches per chain to one
/// of the former). A protocol so `WalletSyncEngine` injects a `ChainDataClient`
/// rather than a concrete struct, and so test stubs can replace the live client.
protocol ChainDataClient: Sendable {
  /// The chain's current block head, or `nil` when the provider isn't
  /// block-range scannable (Alchemy's higher-level transfer API has no
  /// notion of a caller-supplied head — it always resolves `"latest"`
  /// itself). A direct JSON-RPC client returns the raw `eth_blockNumber`
  /// value. Callers that need a windowed scan (a caller-supplied
  /// `toBlock`) use this to compute the window's upper bound up front,
  /// rather than resolving it implicitly inside `getAssetTransfers`.
  func currentHead(chain: ChainConfig) async throws -> UInt64?

  /// Returns transfers in `[fromBlock, toBlock ?? latestBlock]` for
  /// `walletAddress`, in two passes: `fromAddress = walletAddress` and
  /// `toAddress = walletAddress`. Categories include `external` and
  /// `erc20` always; `internal` is included only when
  /// `chain.supportsInternalTransfers` is `true` (currently no supported
  /// chain — Blockscout owns internal ETH on all of them). NFT categories
  /// are always excluded at the request level.
  ///
  /// - Parameter toBlock: `nil` means "scan to the current head" (today's
  ///   behaviour, and Alchemy's only mode — it ignores this parameter and
  ///   always requests `toBlock: "latest"`). A non-`nil` value bounds a
  ///   direct-RPC scan to that block without an extra `eth_blockNumber`
  ///   round-trip to discover the head.
  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64,
    toBlock: UInt64?
  ) async throws -> [AlchemyTransfer]

  /// Fetches the on-chain receipt for `hash` so the wallet sync
  /// pipeline can compute the gas-leg quantity (`gasUsed *
  /// effectiveGasPrice`). Alchemy's `alchemy_getAssetTransfers` doesn't
  /// include gas-cost data per transfer, so callers fetch one receipt
  /// per unique outbound `txHash`.
  ///
  /// Throws `WalletSyncError.providerMalformedResponse(stage:
  /// "getTransactionReceipt")` when the JSON-RPC `result` is `null`
  /// (rare — only when the hash isn't on chain yet, or the node has
  /// pruned it) or when the response payload can't be decoded.
  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt
}
