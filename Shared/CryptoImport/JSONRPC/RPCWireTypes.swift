// Shared/CryptoImport/JSONRPC/RPCWireTypes.swift
import Foundation

/// Namespace marker only — matches the file name so `swiftlint`'s
/// `file_name` rule is satisfied. The actual wire types below are top-level
/// (not nested under this enum) so every direct-RPC call site can reference
/// them without a qualifier, mirroring `BlockscoutWireFormat`'s pattern of a
/// same-named empty enum alongside file-scope types.
enum RPCWireTypes {}

/// A single `eth_getLogs` result entry — one indexed EVM event. Every field
/// is the raw JSON-RPC hex/string form; callers that need the address as a
/// 20-byte value or `logIndex` as an integer decode via `RPCHex`.
struct RPCLog: Decodable, Sendable, Hashable {
  let address: String
  let topics: [String]
  let data: String
  let blockNumber: String
  let transactionHash: String
  let logIndex: String
}

/// `eth_getLogs` filter parameters. `address` is `nil` to query all
/// contracts (no filter); `topics` is positional per the JSON-RPC spec —
/// each element filters that topic slot, and `nil` at a position is a
/// wildcard for that slot.
struct RPCLogFilter: Encodable, Sendable {
  let fromBlock: String
  let toBlock: String
  // `nil` and `[]` are not interchangeable here, unlike most collection
  // properties: `nil` means "no address filter — match every contract",
  // while `[]` would ask the node to match zero addresses (i.e. return no
  // logs at all). Collapsing to an empty array would silently change the
  // query's meaning, so the optional is load-bearing.
  // swiftlint:disable:next discouraged_optional_collection
  let address: [String]?
  let topics: [String?]
}

/// One log entry as it appears embedded in an `eth_getTransactionReceipt`
/// result — the same shape as `RPCLog` minus the block/transaction
/// cross-references, which the receipt itself already carries.
struct RPCReceiptLog: Decodable, Sendable, Hashable {
  let address: String
  let topics: [String]
  let data: String
  let logIndex: String
}

/// `eth_getTransactionReceipt` result. `l1Fee` is optional because it is an
/// OP-stack (Optimism/Base/etc.) extension field that mainnet and most L2
/// nodes omit entirely.
struct RPCReceipt: Decodable, Sendable, Hashable {
  let transactionHash: String
  let from: String
  let gasUsed: String
  let effectiveGasPrice: String
  let l1Fee: String?
  let logs: [RPCReceiptLog]
}
