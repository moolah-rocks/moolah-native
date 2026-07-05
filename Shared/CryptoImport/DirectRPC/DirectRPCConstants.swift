// Shared/CryptoImport/DirectRPC/DirectRPCConstants.swift
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
