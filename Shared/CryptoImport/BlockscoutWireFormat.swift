// Shared/CryptoImport/BlockscoutWireFormat.swift
import Foundation

/// Namespace anchor matching the filename so SwiftLint's `file_name`
/// rule stays satisfied alongside the loose top-level wire-format types
/// below.
enum BlockscoutWireFormat {}

/// One page of Blockscout `/api/v2/addresses/{address}/transactions`.
/// `next_page_params` is an opaque cursor object echoed back as query
/// items on the next request; `nil` when the last page has been served.
struct BlockscoutTransactionsPage: Decodable, Sendable {
  let items: [BlockscoutTransaction]
  let nextPageParams: BlockscoutPageParams?
}

extension BlockscoutTransactionsPage {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: BlockscoutPageCodingKeys.self)
    self.items =
      try container.decodeIfPresent([BlockscoutTransaction].self, forKey: .items) ?? []
    self.nextPageParams = try container.decodeIfPresent(
      BlockscoutPageParams.self, forKey: .nextPageParams)
  }
}

/// One page of `/api/v2/addresses/{address}/internal-transactions`.
struct BlockscoutInternalTxPage: Decodable, Sendable {
  let items: [BlockscoutInternalTx]
  let nextPageParams: BlockscoutPageParams?
}

extension BlockscoutInternalTxPage {
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: BlockscoutPageCodingKeys.self)
    self.items =
      try container.decodeIfPresent([BlockscoutInternalTx].self, forKey: .items) ?? []
    self.nextPageParams = try container.decodeIfPresent(
      BlockscoutPageParams.self, forKey: .nextPageParams)
  }
}

private enum BlockscoutPageCodingKeys: String, CodingKey {
  case items
  case nextPageParams = "next_page_params"
}

/// Opaque pagination cursor. Blockscout echoes these as query
/// parameters on the next request. Only the fields the client threads
/// back are decoded; unknown keys are ignored. `blockNumber` is also
/// used to early-stop pagination once a page predates `fromBlock`.
struct BlockscoutPageParams: Decodable, Sendable, Hashable {
  let blockNumber: Int?
  let index: Int?
  let itemsCount: Int?
  let transactionIndex: Int?

  private enum CodingKeys: String, CodingKey {
    case blockNumber = "block_number"
    case index
    case itemsCount = "items_count"
    case transactionIndex = "transaction_index"
  }

  /// Query items to thread back for the next page. Encodes only the
  /// non-nil cursor fields, matching what Blockscout returned.
  var queryItems: [URLQueryItem] {
    var result: [URLQueryItem] = []
    if let blockNumber {
      result.append(.init(name: CodingKeys.blockNumber.rawValue, value: String(blockNumber)))
    }
    if let index {
      result.append(.init(name: CodingKeys.index.rawValue, value: String(index)))
    }
    if let itemsCount {
      result.append(.init(name: CodingKeys.itemsCount.rawValue, value: String(itemsCount)))
    }
    if let transactionIndex {
      result.append(
        .init(name: CodingKeys.transactionIndex.rawValue, value: String(transactionIndex)))
    }
    return result
  }
}

/// Address wrapper — Blockscout returns `{ "hash": "0x…" , … }` for
/// `from`/`to`. Only `hash` is needed.
struct BlockscoutAddress: Decodable, Sendable, Hashable {
  let hash: String
}

/// One item from the address `transactions` endpoint. `value` is wei as
/// a decimal string. Success is derived from `status`/`result` so a
/// reverted tx is still enumerated (it paid gas —
/// https://github.com/moolah-rocks/moolah-native/issues/919).
struct BlockscoutTransaction: Decodable, Sendable, Hashable {
  let hash: String
  let blockNumber: Int
  let timestamp: String?
  let from: BlockscoutAddress
  let to: BlockscoutAddress?
  let value: String
  let status: String?
  let result: String?

  private enum CodingKeys: String, CodingKey {
    case hash
    case blockNumber = "block_number"
    case timestamp
    case from
    case to
    case value
    case status
    case result
  }

  /// `true` unless the receipt status / execution result indicates a
  /// revert. Blockscout uses `status:"ok"|"error"` and a textual
  /// `result` (`"success"` vs an error string). A failed tx is still a
  /// real signed tx that paid gas, so this only affects the *value*
  /// leg, never whether the tx contributes a gas leg.
  var isSuccess: Bool {
    if let status { return status.lowercased() == "ok" }
    if let result { return result.lowercased() == "success" }
    return true
  }
}

/// One item from the `internal-transactions` endpoint. `index` is
/// Blockscout's stable per-call ordinal — used to build a deterministic
/// `externalId` so re-syncs dedup idempotently.
struct BlockscoutInternalTx: Decodable, Sendable, Hashable {
  let transactionHash: String
  let blockNumber: Int
  let timestamp: String?
  let from: BlockscoutAddress
  let to: BlockscoutAddress?
  let value: String
  let index: Int
  let success: Bool

  private enum CodingKeys: String, CodingKey {
    case transactionHash = "transaction_hash"
    case blockNumber = "block_number"
    case timestamp
    case from
    case to
    case value
    case index
    case success
  }
}
