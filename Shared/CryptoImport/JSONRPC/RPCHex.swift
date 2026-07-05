// Shared/CryptoImport/JSONRPC/RPCHex.swift
import Foundation

/// Hex-quantity and address-topic conversions shared across the direct-RPC
/// pipeline (`eth_getLogs` filters, `eth_call` inputs, log-topic decoding).
///
/// The JSON-RPC "quantity" wire format (used for block numbers, `chainId`,
/// and similar integers) is `0x`-prefixed, lowercased, and has no leading
/// zeros — `0` itself encodes as `"0x0"`, never `"0x"`. This is distinct
/// from the `Decimal`-producing `HexDecimal.parse`/`parseInt` helpers in
/// `AlchemyTransactionReceipt.swift`, which decode the larger (256-bit,
/// `Decimal`-precision) "DATA" values Alchemy's higher-level transfer API
/// already returns as strings — `RPCHex` only adds the `UInt64`-quantity
/// and address/topic string forms a raw JSON-RPC node requires that aren't
/// already covered there.
enum RPCHex {
  /// Encodes a `UInt64` as a JSON-RPC quantity: `0x`-prefixed, lowercased,
  /// no leading zeros (`0` encodes as `"0x0"`). Used for `eth_getLogs`
  /// `fromBlock`/`toBlock` filter bounds and similar integer parameters.
  static func hexQuantity(_ value: UInt64) -> String {
    "0x" + String(value, radix: 16)
  }

  /// Parses a JSON-RPC quantity (0x-prefixed or bare hex, either case)
  /// into a `UInt64`. Returns `nil` on malformed input — callers log/skip
  /// rather than failing the whole sync. Also used by
  /// `WalletSyncEngine.maxBlockNumber(in:)` for the same parse rule.
  static func parseUInt64(_ raw: String) -> UInt64? {
    UInt64(stripHexPrefix(raw), radix: 16)
  }

  /// Encodes a `UInt64` in the same quantity form as `hexQuantity`, for
  /// constructing a synthetic `AlchemyTransfer.RawContract.decimal` value
  /// (e.g. an on-chain `decimals()` call result of `18` → `"0x12"`) when
  /// the direct-RPC pipeline builds a wire-compatible transfer from raw
  /// log/call data instead of Alchemy's higher-level API.
  static func hexData(_ value: UInt64) -> String {
    hexQuantity(value)
  }

  /// Left-pads a 20-byte EVM address (`0x` + 40 hex chars) to the 32-byte
  /// topic width `eth_getLogs` indexed-address topics use, lowercasing the
  /// result. Assumes a well-formed address — the wallet addresses this
  /// feeds are already validated where they're synced/entered.
  static func addressTopic(_ address: String) -> String {
    let trimmed = stripHexPrefix(address)
    let padded = String(repeating: "0", count: max(0, 64 - trimmed.count)) + trimmed
    return "0x" + padded.lowercased()
  }

  /// Recovers a `0x`-prefixed lowercased 20-byte address from a 32-byte
  /// `eth_getLogs` topic — the last 40 hex characters (the address is
  /// right-aligned within the zero-padded topic).
  static func addressFromTopic(_ topic: String) -> String {
    let trimmed = stripHexPrefix(topic)
    return "0x" + trimmed.suffix(40).lowercased()
  }
}

extension RPCHex {
  private static func stripHexPrefix(_ raw: String) -> Substring {
    raw.hasPrefix("0x") || raw.hasPrefix("0X") ? raw.dropFirst(2) : Substring(raw)
  }
}
