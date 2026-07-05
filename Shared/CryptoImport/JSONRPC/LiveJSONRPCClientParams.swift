// Shared/CryptoImport/JSONRPC/LiveJSONRPCClientParams.swift
import Foundation

/// Per-method JSON-RPC `params` (request) and result-slice (response) types
/// for `LiveJSONRPCClient`. Split out of `LiveJSONRPCClient.swift` to keep
/// that file under the project's `file_length` budget — these are
/// self-contained wire-encoding shapes with no dependency on the client's
/// transport, so the split follows the transport-vs-wire-shape seam already
/// used for the batch/log types in `RPCWireTypes.swift`. Module-internal
/// (not `private`) purely because they now live in a different file from
/// their sole call sites in `LiveJSONRPCClient`; no other type is meant to
/// depend on them.
///
/// Namespace marker only — matches the file name so SwiftLint's `file_name`
/// rule is satisfied. The actual wire types below are top-level (not nested
/// under this enum), mirroring `RPCWireTypes`'s and `BlockscoutWireFormat`'s
/// same pattern of a same-named empty enum alongside file-scope types.
enum LiveJSONRPCClientParams {}

/// `eth_getBlockByNumber` params: positional `[blockHex, includeTransactions]`;
/// second element is always `false` since only the header `timestamp` is read.
struct BlockByNumberParams {
  let blockHex: String
}

extension BlockByNumberParams: Sendable {}

extension BlockByNumberParams: Encodable {
  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    try container.encode(blockHex)
    try container.encode(false)
  }
}

/// Decode-only slice of an `eth_getBlockByNumber` result — only the field
/// `blockTimestamps` needs.
struct BlockTimestampResult: Decodable, Sendable {
  let timestamp: String
}

/// `eth_call` params: positional `[{to, data}, "latest"]` — `call(to:data:)` only reads current chain state.
struct EthCallParams {
  private struct CallObject: Encodable, Sendable {
    let to: String
    let data: String
  }

  private let object: CallObject

  init(to: String, data: String) {
    self.object = CallObject(to: to, data: data)
  }
}

extension EthCallParams: Sendable {}

extension EthCallParams: Encodable {
  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    try container.encode(object)
    try container.encode("latest")
  }
}

/// `eth_getTransactionReceipt` params: a single positional `[hash]` element.
struct TransactionReceiptParams {
  let hash: String
}

extension TransactionReceiptParams: Sendable {}

extension TransactionReceiptParams: Encodable {
  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    try container.encode(hash)
  }
}
