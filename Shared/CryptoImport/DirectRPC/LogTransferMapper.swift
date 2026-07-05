// Shared/CryptoImport/DirectRPC/LogTransferMapper.swift
import Foundation

/// Maps one ERC-20 `Transfer` event log (`RPCLog`, from `eth_getLogs`) into
/// the canonical `AlchemyTransfer` shape the rest of the sync pipeline
/// already consumes (`TransferEventBuilder` and downstream). This lets the
/// direct-RPC discovery path (Tasks 3+) feed the same pipeline Alchemy's
/// higher-level `alchemy_getAssetTransfers` API feeds, without duplicating
/// the transfer-to-transaction transformation.
///
/// `decimals`/`symbol` (per-contract metadata) and `timestamp` (per-block
/// data) are resolved by the caller — batched lookups are Task 9/10's job —
/// and passed in here purely as data.
enum LogTransferMapper {
  /// Number of topics a standard ERC-20 `Transfer(address indexed from,
  /// address indexed to, uint256 value)` log carries: the event signature
  /// plus the two indexed address topics.
  private static let standardTransferTopicCount = 3

  /// Maps one ERC-20 `Transfer` log to an `AlchemyTransfer`. Returns `nil`
  /// for a non-standard `Transfer` log — fewer than 3 topics means the
  /// indexed `from`/`to` addresses aren't present, so there is nothing
  /// meaningful to map.
  static func erc20Transfer(
    from log: RPCLog, decimals: Int, symbol: String?, timestamp: Date
  ) -> AlchemyTransfer? {
    guard log.topics.count >= standardTransferTopicCount else { return nil }

    let logIndex = RPCHex.parseUInt64(log.logIndex) ?? 0
    return AlchemyTransfer(
      hash: log.transactionHash,
      uniqueId: "\(log.transactionHash):erc20:\(logIndex)",
      from: RPCHex.addressFromTopic(log.topics[1]),
      to: RPCHex.addressFromTopic(log.topics[2]),
      category: .erc20,
      asset: symbol,
      rawContract: .init(
        address: log.address.lowercased(),
        decimal: RPCHex.hexData(UInt64(decimals)),
        rawValue: log.data
      ),
      metadata: .init(blockTimestamp: blockTimestampString(from: timestamp)),
      blockNum: log.blockNumber
    )
  }

  /// Formats `timestamp` in the ISO-8601-with-fractional-seconds shape
  /// Alchemy's own `metadata.blockTimestamp` uses (e.g.
  /// `"2024-09-12T12:34:56.000Z"`), so downstream parsing
  /// (`TransferEventBuilder.parseTimestamp`) round-trips it unchanged.
  ///
  /// `ISO8601DateFormatter` is allocated per call rather than cached in
  /// static state, matching `TransferEventBuilder.parseTimestamp` — it
  /// keeps this enum free of `nonisolated(unsafe)` mutable state, and a
  /// per-log allocation is a non-event next to the RPC round-trips this
  /// pipeline already makes.
  private static func blockTimestampString(from timestamp: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter.string(from: timestamp)
  }
}
