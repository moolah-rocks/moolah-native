// Shared/CryptoImport/DirectRPC/DirectRPCChainClient.swift
import Foundation

/// ABI/address constants for direct-RPC ERC-20 `Transfer` log discovery.
enum DirectRPCConstants {
  /// `keccak256("Transfer(address,address,uint256)")` — topic0 of every
  /// standard ERC-20 `Transfer` event. Used as the first `eth_getLogs`
  /// topic filter so only `Transfer` logs come back.
  static let transferTopic =
    "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  /// The EVM zero address. A `Transfer` whose `from` or `to` is the zero
  /// address is a mint/burn leg; for a wrapped-native contract that leg is
  /// the wrap/unwrap counterpart a receipt-based detector accounts for
  /// separately, so it is dropped here to avoid double counting.
  static let zeroAddress = "0x0000000000000000000000000000000000000000"
}

/// `ChainDataClient` backed by a raw JSON-RPC node rather than Alchemy's
/// higher-level `alchemy_getAssetTransfers` API. Discovers ERC-20 transfers
/// by scanning `Transfer` event logs (`eth_getLogs`) in two indexed-topic
/// passes — one for the wallet as `from`, one for the wallet as `to` — then
/// resolves each surviving log's block timestamp and token metadata and maps
/// it into the same `AlchemyTransfer` shape the rest of the sync pipeline
/// already consumes.
///
/// `Sendable` struct with no mutable state; the `TokenMetadataResolver`
/// collaborator is an `actor` that owns its own per-contract cache.
struct DirectRPCChainClient {
  private let rpc: LiveJSONRPCClient
  private let batcher: AdaptiveLogRangeBatcher
  private let metadata: TokenMetadataResolver

  /// - Parameters:
  ///   - rpc: The JSON-RPC transport used for `eth_blockNumber`,
  ///     `eth_getLogs`, `eth_getBlockByNumber` (timestamps), and the
  ///     `eth_call`s the metadata resolver issues.
  ///   - batcher: Walks the block range in adaptive chunks, shrinking on a
  ///     provider range-limit failure. Defaults to the standard batcher.
  ///   - metadata: Resolves per-contract `decimals()`/`symbol()`, coalescing
  ///     concurrent lookups for the same contract.
  init(
    rpc: LiveJSONRPCClient,
    batcher: AdaptiveLogRangeBatcher = .init(),
    metadata: TokenMetadataResolver
  ) {
    self.rpc = rpc
    self.batcher = batcher
    self.metadata = metadata
  }
}

// MARK: - ChainDataClient

extension DirectRPCChainClient: ChainDataClient {
  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    let head = try await rpc.blockNumber()
    guard fromBlock <= head else { return [] }

    let walletTopic = RPCHex.addressTopic(walletAddress)
    async let outbound = fetchLogs(
      from: fromBlock,
      to: head,
      topics: [DirectRPCConstants.transferTopic, walletTopic, nil])
    async let inbound = fetchLogs(
      from: fromBlock,
      to: head,
      topics: [DirectRPCConstants.transferTopic, nil, walletTopic])
    let combined = try await outbound + inbound

    let logs = deduplicated(combined).filter { isRelevant($0, chain: chain) }
    guard !logs.isEmpty else { return [] }

    let uniqueBlocks = Set(logs.compactMap { RPCHex.parseUInt64($0.blockNumber) })
    let timestamps = try await rpc.blockTimestamps(Array(uniqueBlocks))
    let metadataByContract = await resolveMetadata(for: logs)

    return logs.compactMap { log -> AlchemyTransfer? in
      guard let block = RPCHex.parseUInt64(log.blockNumber),
        let timestamp = timestamps[block],
        let tokenMetadata = metadataByContract[log.address.lowercased()]
      else { return nil }
      return LogTransferMapper.erc20Transfer(
        from: log,
        decimals: tokenMetadata.decimals,
        symbol: tokenMetadata.symbol,
        timestamp: timestamp)
    }
  }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    let receipt = try await rpc.transactionReceipt(hash: hash)
    guard let gasUsed = HexDecimal.parse(receipt.gasUsed),
      let effectiveGasPrice = HexDecimal.parse(receipt.effectiveGasPrice)
    else {
      throw WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")
    }
    let l1FeeWei: Decimal? = try receipt.l1Fee.map { hex in
      guard let parsed = HexDecimal.parse(hex) else {
        throw WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")
      }
      return parsed
    }
    return AlchemyTransactionReceipt(
      hash: receipt.transactionHash,
      gasUsed: gasUsed,
      effectiveGasPrice: effectiveGasPrice,
      from: receipt.from.lowercased(),
      l1FeeWei: l1FeeWei,
      logs: mapLogs(receipt.logs))
  }

  /// Maps raw `eth_getTransactionReceipt` log entries into the domain
  /// `ReceiptLog` the wrap/unwrap detector reads. `logIndex` is parsed from
  /// hex; an entry whose `logIndex` won't parse is dropped rather than
  /// failing the whole receipt (mirrors the Alchemy path's log leniency).
  /// `address` is lowercased so contract comparisons are case-insensitive.
  private func mapLogs(_ logs: [RPCReceiptLog]) -> [ReceiptLog] {
    logs.compactMap { log in
      guard let index = HexDecimal.parseInt(log.logIndex) else { return nil }
      return ReceiptLog(
        address: log.address.lowercased(),
        topics: log.topics,
        data: log.data,
        logIndex: index)
    }
  }
}

// MARK: - Internals

extension DirectRPCChainClient {
  /// One indexed-topic pass over `[from, to]`, walked in adaptive chunks.
  /// `address: nil` means "every contract" — the topic0 filter alone
  /// restricts the result to ERC-20 `Transfer` logs.
  private func fetchLogs(
    from: UInt64,
    to: UInt64,
    topics: [String?]
  ) async throws -> [RPCLog] {
    let rpc = self.rpc
    return try await batcher.run(from: from, to: to) { chunkFrom, chunkTo in
      let filter = RPCLogFilter(
        fromBlock: RPCHex.hexQuantity(chunkFrom),
        toBlock: RPCHex.hexQuantity(chunkTo),
        address: nil,
        topics: topics)
      return try await rpc.getLogs(filter)
    }
  }

  /// De-duplicates logs by `(transactionHash, logIndex)`, preserving first
  /// appearance. A self-send (wallet as both `from` and `to`) matches both
  /// the outbound and inbound passes and would otherwise appear twice.
  private func deduplicated(_ logs: [RPCLog]) -> [RPCLog] {
    var seen: Set<LogIdentity> = []
    var result: [RPCLog] = []
    result.reserveCapacity(logs.count)
    for log in logs {
      let identity = LogIdentity(
        transactionHash: log.transactionHash, logIndex: log.logIndex)
      if seen.insert(identity).inserted {
        result.append(log)
      }
    }
    return result
  }

  /// Identity of a log for de-duplication: a transaction hash plus the log's
  /// position within its block is unique on chain.
  private struct LogIdentity: Hashable {
    let transactionHash: String
    let logIndex: String
  }

  /// Whether a log survives the pre-mapping filters: it must carry the two
  /// indexed address topics, and it must not be a wrapped-native mint/burn
  /// leg (a `Transfer` to/from the zero address on the chain's canonical
  /// wrapped-native contract), which a receipt-based wrap/unwrap detector
  /// accounts for separately.
  private func isRelevant(_ log: RPCLog, chain: ChainConfig) -> Bool {
    guard log.topics.count >= 3 else { return false }
    let from = RPCHex.addressFromTopic(log.topics[1])
    let to = RPCHex.addressFromTopic(log.topics[2])
    let touchesZeroAddress =
      from == DirectRPCConstants.zeroAddress || to == DirectRPCConstants.zeroAddress
    if touchesZeroAddress,
      WrappedNativeContracts.nativePricingInstrumentId(
        chainId: chain.chainId, contractAddress: log.address) != nil
    {
      return false
    }
    return true
  }

  /// Resolves `decimals()`/`symbol()` for every unique contract among
  /// `logs`, concurrently — the resolver actor coalesces duplicate in-flight
  /// lookups for the same contract. Contracts whose metadata is `nil`
  /// (unreadable `decimals()`) are absent from the result, so their logs are
  /// dropped by the caller.
  private func resolveMetadata(
    for logs: [RPCLog]
  ) async -> [String: TokenMetadataResolver.Metadata] {
    let contracts = Set(logs.map { $0.address.lowercased() })
    let resolver = metadata
    return await withTaskGroup(
      of: (String, TokenMetadataResolver.Metadata?).self
    ) { group in
      for contract in contracts {
        group.addTask { (contract, await resolver.metadata(for: contract)) }
      }
      var resolved: [String: TokenMetadataResolver.Metadata] = [:]
      for await (contract, tokenMetadata) in group {
        if let tokenMetadata { resolved[contract] = tokenMetadata }
      }
      return resolved
    }
  }
}
