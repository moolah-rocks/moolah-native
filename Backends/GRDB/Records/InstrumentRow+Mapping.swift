// Backends/GRDB/Records/InstrumentRow+Mapping.swift

import Foundation
import GRDB

extension InstrumentRow {
  /// Builds `[String: Instrument]` from the `instrument` table,
  /// supplemented with ambient fiat for ISO codes that don't appear as
  /// rows. The single shared helper ensures repository call sites
  /// (`GRDBAccountRepository`, `GRDBEarmarkRepository`,
  /// `GRDBTransactionRepository`) all use the same stored-then-ambient
  /// ordering, mirroring `CloudKitInstrumentRegistryRepository.all()`.
  static func fetchInstrumentMap(database: Database) throws -> [String: Instrument] {
    let rows = try InstrumentRow.fetchAll(database)
    // Start from the ambient ISO-fiat snapshot, then overlay stored rows
    // so a stored row always wins over its ambient synthesis — identical
    // outcome and ordering to the previous stored-then-fill loop, because
    // a stored id either replaces its ambient entry or adds a new one.
    var map = Self.ambientFiat
    for row in rows {
      map[row.id] = try row.toDomain()
    }
    return map
  }

  /// ISO-4217 fiat instruments synthesised once at first use.
  ///
  /// Computed into a `static let` rather than per `fetchInstrumentMap`
  /// call: ~150 `Instrument.fiat(code:)` constructions (each spinning
  /// up a `NumberFormatter` to derive the currency's decimal places)
  /// over `Locale.Currency.isoCurrencies` would otherwise dominate the
  /// cold-launch resolution burst. The inputs are process-stable:
  /// `Locale.Currency.isoCurrencies` is a fixed ISO table for the
  /// process lifetime, and `Instrument.fiat(code:)` derives decimals
  /// from the currency *code* (not the user's locale), so the synthesis
  /// is deterministic and safe to compute once.
  private static let ambientFiat: [String: Instrument] = {
    var map: [String: Instrument] = [:]
    for code in Locale.Currency.isoCurrencies.map(\.identifier) {
      map[code] = Instrument.fiat(code: code)
    }
    return map
  }()

  /// The CloudKit recordType on the wire for this record. Frozen contract;
  /// existing iCloud zones reference this exact string regardless of how
  /// the local Swift type is named.
  static let recordType = "InstrumentRecord"

  /// Builds the canonical CloudKit `recordName` for an instrument id.
  /// Instruments are string-keyed; the recordName is the bare id with no
  /// `recordType|` prefix.
  static func recordName(for id: String) -> String { id }

  /// Builds a row from a domain `Instrument`. The provider-mapping fields
  /// are left nil here — they are only populated via
  /// `GRDBInstrumentRegistryRepository.registerCrypto(_:mapping:)` /
  /// `registerStock(_:)`.
  init(domain: Instrument) {
    self.id = domain.id
    self.recordName = Self.recordName(for: domain.id)
    self.kind = domain.kind.rawValue
    self.name = domain.name
    self.decimals = domain.decimals
    self.ticker = domain.ticker
    self.exchange = domain.exchange
    self.chainId = domain.chainId
    self.contractAddress = domain.contractAddress
    self.coingeckoId = nil
    self.binanceSymbol = nil
    self.encodedSystemFields = nil
    self.pricingStatus = TokenPricingStatus.priced.rawValue
  }

  /// Domain projection. Provider-mapping fields are exposed via
  /// `cryptoMapping` for the registry's `allCryptoRegistrations()` path;
  /// the domain `Instrument` itself does not carry them.
  ///
  /// Throws `BackendError.dataCorrupted` when `kind` carries a raw value
  /// the compiled `Instrument.Kind` enum doesn't recognise.
  func toDomain() throws -> Instrument {
    Instrument(
      id: id,
      kind: try Instrument.Kind.decoded(rawValue: kind, label: "Instrument.Kind"),
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: exchange,
      chainId: chainId,
      contractAddress: contractAddress)
  }

  /// `CryptoProviderMapping` reconstructed from the row's provider columns.
  /// Returns `nil` when no mapping is recorded (matches the `hasMapping`
  /// guard in `GRDBInstrumentRegistryRepository.project(row:)`).
  func cryptoMapping() -> CryptoProviderMapping? {
    let hasMapping = coingeckoId != nil || binanceSymbol != nil
    guard hasMapping else { return nil }
    return CryptoProviderMapping(
      instrumentId: id,
      coingeckoId: coingeckoId,
      binanceSymbol: binanceSymbol)
  }

  /// All-nil `CryptoProviderMapping` for the row's id. Used by the
  /// inbox / spam paths in `allCryptoRegistrations()` so a `.unpriced`
  /// or `.spam` row without any resolved provider is still surfaceable
  /// in the Discovered Tokens UI. Matches the `emptyMapping(_:)` shape
  /// the discovery service writes on these rows.
  func emptyCryptoMapping() -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: id,
      coingeckoId: nil,
      binanceSymbol: nil)
  }
}
