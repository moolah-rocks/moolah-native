import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InstrumentConversionService — Crypto provenance")
struct CryptoProvenanceTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  private let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8)

  @Test("crypto to USD reports the effective crypto price day")
  func cryptoToUsdReportsPriceDay() async throws {
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-08": dec("1623.45")]],
      providerInstruments: [eth])
    let amount = InstrumentAmount(quantity: Decimal(1), instrument: eth)

    let effectiveDate = try await service.oldestPriceDate(
      for: amount, to: .USD, on: date("2026-04-10"))

    #expect(effectiveDate == date("2026-04-08"))
  }

  @Test("crypto to non-USD reports the oldest price or FX day")
  func cryptoToAudReportsOldestDay() async throws {
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-09": dec("1623.45")]],
      exchangeRates: ["2026-04-08": ["AUD": dec("1.58")]],
      providerInstruments: [eth])
    let amount = InstrumentAmount(quantity: Decimal(1), instrument: eth)

    let effectiveDate = try await service.oldestPriceDate(
      for: amount, to: .AUD, on: date("2026-04-10"))

    #expect(effectiveDate == date("2026-04-08"))
  }

  @Test("crypto to crypto reports the oldest source price day")
  func cryptoToCryptoReportsOldestDay() async throws {
    let service = try makeService(
      cryptoPrices: [
        "1:native": ["2026-04-09": dec("1623.45")],
        "0:native": ["2026-04-07": dec("63000.00")],
      ],
      providerInstruments: [eth, btc])
    let amount = InstrumentAmount(quantity: Decimal(1), instrument: eth)

    let effectiveDate = try await service.oldestPriceDate(
      for: amount, to: btc, on: date("2026-04-10"))

    #expect(effectiveDate == date("2026-04-07"))
  }

  @Test("crypto provenance throws when no crypto service is configured")
  func cryptoProvenanceRequiresCryptoService() async throws {
    let service = try makeService(includesCryptoService: false)
    let amount = InstrumentAmount(quantity: Decimal(1), instrument: eth)

    await #expect(throws: ConversionError.self) {
      _ = try await service.oldestPriceDate(
        for: amount, to: .USD, on: date("2026-04-10"))
    }
  }

  @Test("same-instrument provenance has no contributing price date")
  func sameInstrumentProvenanceIsNil() async throws {
    let service = try makeService(includesCryptoService: false)
    let amount = InstrumentAmount(quantity: Decimal(1), instrument: eth)

    let effectiveDate = try await service.oldestPriceDate(
      for: amount, to: eth, on: date("2026-04-10"))

    #expect(effectiveDate == nil)
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = .utc
    guard let result = formatter.date(from: string) else {
      fatalError("Could not parse ISO8601 full-date string: \(string)")
    }
    return result
  }

  private func makeService(
    cryptoPrices: [String: [String: Decimal]] = [:],
    exchangeRates: [String: [String: Decimal]] = [:],
    providerInstruments: [Instrument] = [],
    includesCryptoService: Bool = true
  ) throws -> FullConversionService {
    let database = try ProfileIndexDatabase.openInMemory()
    let registrations = Dictionary(
      uniqueKeysWithValues: providerInstruments.map { instrument in
        (
          instrument.id,
          CryptoRegistration(
            instrument: instrument,
            mapping: CryptoProviderMapping(
              instrumentId: instrument.id,
              coingeckoId: instrument.id,
              binanceSymbol: instrument.id))
        )
      })
    let cryptoService = CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: cryptoPrices)],
      database: database,
      metadataLookup: { registrations[$0] })
    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: exchangeRates),
      database: database)
    let stockService = StockPriceService(
      client: FixedStockPriceClient(),
      database: database)
    return FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: includesCryptoService ? cryptoService : nil)
  }
}
