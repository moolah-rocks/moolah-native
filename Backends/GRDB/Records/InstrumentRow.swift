// Backends/GRDB/Records/InstrumentRow.swift

import Foundation
import GRDB

/// One row in the `instrument` table.
///
/// **String primary key.** `Instrument` is the only synced row that
/// uses an arbitrary string ID (e.g. `"AUD"`, `"ASX:BHP"`,
/// `"1:0xa0b8…"`) instead of a UUID. The CloudKit recordName is the
/// bare `id` string with no `recordType|` prefix — see
/// `recordName(for:)`.
///
/// **Sync metadata.** `recordName` is the canonical CloudKit recordName
/// (the bare `id`). `encodedSystemFields` holds the cached CKRecord
/// change-tag blob; these bytes are bit-for-bit copies of what CloudKit
/// returned and are never decoded outside the sync boundary.
struct InstrumentRow {
  static let databaseTableName = "instrument"

  enum Columns: String, ColumnExpression, CaseIterable {
    case id
    case recordName = "record_name"
    case kind
    case name
    case decimals
    case ticker
    case exchange
    case chainId = "chain_id"
    case contractAddress = "contract_address"
    case coingeckoId = "coingecko_id"
    case binanceSymbol = "binance_symbol"
    case encodedSystemFields = "encoded_system_fields"
    case pricingStatus = "pricing_status"
  }

  enum CodingKeys: String, CodingKey {
    case id
    case recordName = "record_name"
    case kind
    case name
    case decimals
    case ticker
    case exchange
    case chainId = "chain_id"
    case contractAddress = "contract_address"
    case coingeckoId = "coingecko_id"
    case binanceSymbol = "binance_symbol"
    case encodedSystemFields = "encoded_system_fields"
    case pricingStatus = "pricing_status"
  }

  var id: String
  var recordName: String
  /// Raw value of `Instrument.Kind` (`"fiatCurrency"`, `"stock"`,
  /// `"cryptoToken"`). Pinned by a CHECK constraint; update both in
  /// lock-step if the enum's raw values change.
  var kind: String
  var name: String
  var decimals: Int
  var ticker: String?
  var exchange: String?
  var chainId: Int?
  var contractAddress: String?
  /// Provider-mapping fields — written by
  /// `InstrumentRegistryRepository.registerCrypto(_:mapping:)` /
  /// `registerStock(_:)`. Plain `Instrument` rows synthesised via
  /// `init(domain:)` carry `nil` here.
  var coingeckoId: String?
  var binanceSymbol: String?
  var encodedSystemFields: Data?
  /// Raw value of `TokenPricingStatus` (`"priced"`, `"unpriced"`,
  /// `"spam"`). Defaults to `"priced"` per the GRDB column default for
  /// non-crypto rows and legacy crypto rows. Pinned by a CHECK
  /// constraint. Defaulted on the Swift side to `"priced"` so existing
  /// memberwise-init call sites continue to compile.
  var pricingStatus: String = "priced"
}

extension InstrumentRow: Codable {}
extension InstrumentRow: Sendable {}
extension InstrumentRow: Identifiable {}
extension InstrumentRow: FetchableRecord {}
extension InstrumentRow: PersistableRecord {}
extension InstrumentRow: GRDBSystemFieldsStampable {}
