// Shared/CryptoImport/AlchemyJSONRPCWireFormat.swift
import Foundation
import OSLog

/// Namespace anchor matching the filename so SwiftLint's `file_name`
/// rule stays satisfied alongside the loose top-level wire-format
/// types declared below.
enum AlchemyJSONRPCWireFormat {}

/// JSON-RPC envelope and wire-format payloads used by `LiveAlchemyClient`.
///
/// Visibility: every type here is module-internal but unused outside
/// `ChainDataClient.swift` and the test files. Keeping them at the file
/// scope (rather than nested inside `LiveAlchemyClient`) lets the
/// generic `JSONRPCRequest` / `JSONRPCResponse` envelopes stay shared
/// across the three JSON-RPC methods without re-declaring the wrapper.

/// Outer JSON-RPC 2.0 request envelope. `id` is fixed at 1 — Alchemy
/// echoes it back, but our requests are single-shot so we don't
/// correlate.
struct AlchemyJSONRPCRequest<Params: Encodable>: Encodable {
  let jsonrpc: String
  let id: Int
  let method: String
  let params: Params

  init(method: String, params: Params) {
    self.jsonrpc = "2.0"
    self.id = 1
    self.method = method
    self.params = params
  }
}

/// JSON-RPC 2.0 envelope variant that allows `result: null`. Used by
/// `eth_getTransactionReceipt` because the spec returns `null` for
/// hashes the node hasn't seen yet (instead of an error envelope).
struct AlchemyJSONRPCNullableResponse<Result: Decodable>: Decodable {
  let result: Result?
}

// These envelopes are created and decoded across the `await` in
// `LiveAlchemyClient.send`, so they cross actor boundaries; their
// instances are safe to send whenever the generic body is.
extension AlchemyJSONRPCRequest: Sendable where Params: Sendable {}
extension AlchemyJSONRPCNullableResponse: Sendable where Result: Sendable {}

/// Discriminated `params` payload — covers the JSON-RPC methods this
/// client makes today. Each case encodes as the JSON-RPC convention of
/// a one-element array around the parameter object (or address /
/// hash string).
enum AlchemyJSONRPCParams: Encodable, Sendable {
  case assetTransfers(AlchemyAssetTransfersParams)
  case transactionReceipt(hash: String)

  func encode(to encoder: Encoder) throws {
    var container = encoder.unkeyedContainer()
    switch self {
    case .assetTransfers(let params):
      try container.encode(params)
    case .transactionReceipt(let hash):
      try container.encode(hash)
    }
  }
}

/// Body for the `params[0]` object of `alchemy_getAssetTransfers`.
struct AlchemyAssetTransfersParams: Encodable, Sendable {
  let fromBlock: String
  let toBlock: String
  let fromAddress: String?
  let toAddress: String?
  let category: [String]
  let withMetadata: Bool
  let excludeZeroValue: Bool
  /// Cursor for the next page. `nil` (and therefore omitted by the
  /// synthesised encoder, like the other optional fields) on the first
  /// request; set to the prior response's `pageKey` to fetch the next
  /// page. Without this, Alchemy returns only the oldest `maxCount`
  /// (1000) transfers per direction and the rest are silently lost.
  let pageKey: String?
}

/// Decodes the `result` object of `alchemy_getAssetTransfers`. Wraps the
/// `AlchemyTransferResult` body in the JSON-RPC `result` key.
struct AlchemyTransferEnvelope: Decodable {
  let result: AlchemyTransferResult
}

struct AlchemyTransferResult: Decodable, Sendable {
  let transfers: [AlchemyTransfer]
  /// Absent when all remaining transfers fit in this page. See
  /// `AlchemyAssetTransfersParams.pageKey`. The synthesised decoder
  /// maps a missing key to `nil`.
  let pageKey: String?
}

/// HTTP response validator for `LiveAlchemyClient`. Maps status codes
/// to `WalletSyncError` cases and parses `Retry-After` for the 429
/// path.
enum AlchemyResponseValidator {
  /// Validates the HTTP response, throwing the appropriate
  /// `WalletSyncError` on non-2xx status. `logger` is the per-instance
  /// `Logger` from the calling client; passed in so log messages remain
  /// attributed to the same subsystem/category as the rest of the
  /// client's output.
  static func validate(
    response: URLResponse,
    stage: String,
    logger: Logger
  ) throws {
    guard let http = response as? HTTPURLResponse else {
      logger.error(
        "Alchemy \(stage, privacy: .public): non-HTTP response"
      )
      throw WalletSyncError.network(underlyingDescription: "No HTTP response")
    }
    switch http.statusCode {
    case 200...299:
      return
    case 401, 403:
      logger.error(
        "Alchemy \(stage, privacy: .public): API key rejected (HTTP \(http.statusCode, privacy: .public))"
      )
      throw WalletSyncError.invalidApiKey
    case 429:
      let retryAfter = parseRetryAfter(http: http)
      logger.notice(
        "Alchemy \(stage, privacy: .public): rate limited (HTTP 429)"
      )
      throw WalletSyncError.rateLimited(retryAfter: retryAfter)
    default:
      logger.error(
        "Alchemy \(stage, privacy: .public): HTTP \(http.statusCode, privacy: .public)"
      )
      throw WalletSyncError.network(
        underlyingDescription: "HTTP \(http.statusCode)"
      )
    }
  }

  /// Parses `Retry-After` per RFC 7231: either a non-negative integer
  /// seconds value or an HTTP-date. Returns `nil` when the header is
  /// absent or unparseable.
  private static func parseRetryAfter(http: HTTPURLResponse) -> Date? {
    guard let header = http.value(forHTTPHeaderField: "Retry-After") else {
      return nil
    }
    let trimmed = header.trimmingCharacters(in: .whitespaces)
    if let seconds = TimeInterval(trimmed) {
      return Date().addingTimeInterval(seconds)
    }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(identifier: "GMT")
    formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return formatter.date(from: trimmed)
  }
}

/// Wire-format payload for `eth_getTransactionReceipt`. We decode the
/// three fields the gas-leg builder always needs (`gasUsed`,
/// `effectiveGasPrice`, `from`) plus the OP-stack `l1Fee`; everything
/// else on the receipt is ignored.
///
/// Hex parsing happens in `toReceipt(hash:)` rather than in a custom
/// `init(from:)` so the throw-site stays close to the call. The first
/// three fields are required — the JSON-RPC spec mandates them on a
/// non-null receipt, so a missing one is a malformed response we reject
/// rather than silently zero out (a zero gas leg would look like a free
/// transaction; a missing `from` would always fail the wallet-match
/// check and drop legitimate gas legs).
///
/// `l1Fee` is OP-stack-specific and absent on L1 chains, so a missing
/// value decodes to `nil` (normal). A *present but unparseable* `l1Fee`
/// is rejected like the required fields — silently dropping it would
/// re-introduce the OP-stack gas under-count (#920).
///
/// `logs` is decoded as absent-or-empty ⇒ `[]` (SwiftLint's
/// `discouraged_optional_collection` rules out an `Optional` array
/// stored property, so the missing-key case is collapsed to `[]` in a
/// custom `init(from:)` rather than surfacing as `nil`). Unlike the gas
/// fields above, a malformed individual log entry is dropped rather
/// than failing the whole receipt: nothing in the gas-leg path reads
/// `logs` today, so a bad `logIndex` on one entry shouldn't turn a
/// legitimate gas leg into a sync failure. The wrap/unwrap detector
/// that consumes `logs` treats a dropped event the same as an absent
/// one.
struct AlchemyTransactionReceiptPayload: Decodable, Sendable {
  let gasUsed: String
  let effectiveGasPrice: String
  /// EOA that signed the transaction. Decoded raw; lowercased at
  /// construction so downstream comparisons stay canonical.
  let from: String
  /// OP-stack L1 data fee as a 0x-hex string. Absent on Ethereum /
  /// Polygon receipts (the chain has no L1 data fee).
  let l1Fee: String?
  /// Event logs emitted by the transaction. Absent on some minimal
  /// wire shapes (e.g. hand-built test payloads) — the custom
  /// `init(from:)` below maps a missing key to `[]`.
  let logs: [ReceiptLogPayload]

  private enum CodingKeys: String, CodingKey {
    case gasUsed, effectiveGasPrice, from, l1Fee, logs
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    gasUsed = try container.decode(String.self, forKey: .gasUsed)
    effectiveGasPrice = try container.decode(String.self, forKey: .effectiveGasPrice)
    from = try container.decode(String.self, forKey: .from)
    l1Fee = try container.decodeIfPresent(String.self, forKey: .l1Fee)
    logs = try container.decodeIfPresent([ReceiptLogPayload].self, forKey: .logs) ?? []
  }

  func toReceipt(hash: String) throws -> AlchemyTransactionReceipt {
    guard
      let gasUsedValue = HexDecimal.parse(gasUsed),
      let effectiveGasPriceValue = HexDecimal.parse(effectiveGasPrice)
    else {
      throw WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")
    }
    let l1FeeValue: Decimal? = try l1Fee.map { hex in
      guard let parsed = HexDecimal.parse(hex) else {
        throw WalletSyncError.providerMalformedResponse(stage: "getTransactionReceipt")
      }
      return parsed
    }
    let logValues = logs.compactMap { $0.toReceiptLog() }
    return AlchemyTransactionReceipt(
      hash: hash,
      gasUsed: gasUsedValue,
      effectiveGasPrice: effectiveGasPriceValue,
      from: from.lowercased(),
      l1FeeWei: l1FeeValue,
      logs: logValues
    )
  }
}

/// Wire-format payload for a single entry in a receipt's `logs` array.
/// `logIndex` is decoded as a 0x-hex string per the JSON-RPC spec.
struct ReceiptLogPayload: Decodable, Sendable {
  let address: String
  let topics: [String]
  let data: String
  let logIndex: String

  /// Maps to the domain `ReceiptLog`, parsing `logIndex` from hex.
  /// Returns `nil` on a malformed `logIndex` so the caller can drop
  /// just this entry — see the leniency rationale on
  /// `AlchemyTransactionReceiptPayload.logs`.
  func toReceiptLog() -> ReceiptLog? {
    guard let index = HexDecimal.parseInt(logIndex) else { return nil }
    return ReceiptLog(
      address: address.lowercased(),
      topics: topics,
      data: data,
      logIndex: index
    )
  }
}
