// MoolahTests/Shared/PriceSourceTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("PriceSource — protocol conformers")
struct PriceSourceTests {
  private let aud = Instrument.fiat(code: "AUD")
  private let usd = Instrument.fiat(code: "USD")
  private let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")

  /// Builds the single `YYYY-MM-DD` parser/formatter for the suite. Pinned to
  /// UTC per `guides/DATE_TIME_GUIDE.md` so the timezoneless day labels parse
  /// and format zone-invariantly. (`ISO8601DateFormatter` always formats with
  /// the POSIX calendar; the explicit UTC zone is what removes the seam.)
  /// Constructed per call rather than held in a `static let` because
  /// `ISO8601DateFormatter` is not `Sendable`.
  private func isoDayFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }

  private func date(_ string: String) -> Date {
    guard let result = isoDayFormatter().date(from: string) else {
      fatalError("Could not parse ISO8601 full-date string: \(string)")
    }
    return result
  }

  private func dateString(_ date: Date) -> String {
    isoDayFormatter().string(from: date)
  }

  private func makeStockService(
    ticker: String,
    instrument: Instrument,
    prices: [String: Decimal]
  ) throws -> StockPriceService {
    let database = try ProfileIndexDatabase.openInMemory()
    let response = StockPriceResponse(instrument: instrument, prices: prices)
    let client = FixedStockPriceClient(responses: [ticker: response])
    let utc = try #require(TimeZone(identifier: "UTC"))
    return StockPriceService(client: client, database: database, timeZone: utc)
  }

  private func makeCryptoService(
    prices: [String: [String: Decimal]] = [:],
    lookup: @Sendable @escaping (String) async throws -> CryptoRegistration?
  ) throws -> CryptoPriceService {
    CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: prices)],
      database: try ProfileIndexDatabase.openInMemory(),
      metadataLookup: lookup)
  }

  // MARK: - FiatPriceSource

  @Test("FiatPriceSource returns (1, instrument) for quote")
  func fiatSourceQuoteReturnsOne() async throws {
    let source = FiatPriceSource(instrument: aud)
    let quote = try await source.quote(on: date("2026-04-10"))
    #expect(quote.perUnit == Decimal(1))
    #expect(quote.nativeQuote == aud)
  }

  @Test("FiatPriceSource pricingStatus is .priced")
  func fiatSourcePricingStatusIsPriced() async throws {
    let source = FiatPriceSource(instrument: usd)
    let status = try await source.pricingStatus()
    #expect(status == .priced)
  }

  // MARK: - StockPriceSource

  @Test("StockPriceSource returns stock price and listing currency")
  func stockSourceQuoteReturnsPriceAndListingCurrency() async throws {
    let testDate = date("2026-04-10")
    let dateKey = dateString(testDate)
    let yKey = dateString(testDate.addingTimeInterval(-86400))
    let stockService = try makeStockService(
      ticker: "BHP.AX",
      instrument: .AUD,
      prices: [dateKey: dec("42.30"), yKey: dec("42.30")])
    let source = StockPriceSource(instrument: bhp, stockPrices: stockService)
    let quote = try await source.quote(on: testDate)
    #expect(quote.perUnit == dec("42.30"))
    #expect(quote.nativeQuote == .AUD)
  }

  @Test("StockPriceSource pricingStatus is .priced")
  func stockSourcePricingStatusIsPriced() async throws {
    let stockService = try makeStockService(ticker: "BHP.AX", instrument: .AUD, prices: [:])
    let source = StockPriceSource(instrument: bhp, stockPrices: stockService)
    let status = try await source.pricingStatus()
    #expect(status == .priced)
  }

  @Test("StockPriceSource throws unsupportedConversion when instrument has no ticker")
  func stockSourceThrowsForNoTicker() async throws {
    let noTicker = Instrument(
      id: "ASX:NOTICKER", kind: .stock, name: "No Ticker", decimals: 0,
      ticker: nil, exchange: "ASX", chainId: nil, contractAddress: nil)
    let stockService = try makeStockService(ticker: "NOTICKER", instrument: .AUD, prices: [:])
    let source = StockPriceSource(instrument: noTicker, stockPrices: stockService)
    await #expect(
      throws: ConversionError.unsupportedConversion(from: "ASX:NOTICKER", to: "fiat")
    ) {
      _ = try await source.quote(on: date("2026-04-10"))
    }
  }

  // MARK: - CryptoPriceSource

  @Test("CryptoPriceSource quote returns USD as nativeQuote")
  func cryptoSourceQuoteNativeQuoteIsUSD() async throws {
    let testDate = date("2026-04-10")
    let dateKey = dateString(testDate.addingTimeInterval(-86400))
    let lookup: @Sendable (String) async throws -> CryptoRegistration? = { [ethMapping] _ in
      CryptoRegistration(
        instrument: .crypto(
          chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
        mapping: ethMapping)
    }
    let cryptoService = try makeCryptoService(
      prices: ["1:native": [dateKey: dec("1623.45")]],
      lookup: lookup)
    let source = CryptoPriceSource(instrument: eth, cryptoPrices: cryptoService)
    let quote = try await source.quote(on: testDate)
    #expect(quote.perUnit == dec("1623.45"))
    #expect(quote.nativeQuote == .USD)
  }

  @Test("CryptoPriceSource pricingStatus is .priced for registered token")
  func cryptoSourcePricingStatusIsPricedForRegistered() async throws {
    let lookup: @Sendable (String) async throws -> CryptoRegistration? = { [ethMapping] _ in
      CryptoRegistration(
        instrument: .crypto(
          chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
        mapping: ethMapping,
        pricingStatus: .priced)
    }
    let cryptoService = try makeCryptoService(lookup: lookup)
    let source = CryptoPriceSource(instrument: eth, cryptoPrices: cryptoService)
    let status = try await source.pricingStatus()
    #expect(status == .priced)
  }

  @Test("CryptoPriceSource pricingStatus reports .unpriced from registration")
  func cryptoSourcePricingStatusIsUnpriced() async throws {
    let lookup: @Sendable (String) async throws -> CryptoRegistration? = { [ethMapping] _ in
      CryptoRegistration(
        instrument: .crypto(
          chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
        mapping: ethMapping,
        pricingStatus: .unpriced)
    }
    let cryptoService = try makeCryptoService(lookup: lookup)
    let source = CryptoPriceSource(instrument: eth, cryptoPrices: cryptoService)
    let status = try await source.pricingStatus()
    #expect(status == .unpriced)
  }

  @Test("CryptoPriceSource pricingStatus reports .spam from registration")
  func cryptoSourcePricingStatusIsSpam() async throws {
    let lookup: @Sendable (String) async throws -> CryptoRegistration? = { [ethMapping] _ in
      CryptoRegistration(
        instrument: .crypto(
          chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
        mapping: ethMapping,
        pricingStatus: .spam)
    }
    let cryptoService = try makeCryptoService(lookup: lookup)
    let source = CryptoPriceSource(instrument: eth, cryptoPrices: cryptoService)
    let status = try await source.pricingStatus()
    #expect(status == .spam)
  }

  @Test("CryptoPriceSource pricingStatus returns .priced when registration missing (not throw)")
  func cryptoSourcePricingStatusReturnsPricedForMissingRegistration() async throws {
    let lookup: @Sendable (String) async throws -> CryptoRegistration? = { _ in nil }
    let cryptoService = try makeCryptoService(lookup: lookup)
    let source = CryptoPriceSource(instrument: eth, cryptoPrices: cryptoService)
    // Missing registration must NOT throw from pricingStatus — it must return .priced
    // so the error surfaces later at price-fetch time.
    let status = try await source.pricingStatus()
    #expect(status == .priced)
  }

  @Test("CryptoPriceSource with nil cryptoPrices throws noCryptoPriceService on quote")
  func cryptoSourceNilCryptoPricesThrows() async throws {
    let source = CryptoPriceSource(instrument: eth, cryptoPrices: nil)
    await #expect(throws: ConversionError.noCryptoPriceService) {
      _ = try await source.quote(on: date("2026-04-10"))
    }
  }

  @Test("CryptoPriceSource with nil cryptoPrices returns .priced for pricingStatus")
  func cryptoSourceNilCryptoPricesReturnsPriced() async throws {
    let source = CryptoPriceSource(instrument: eth, cryptoPrices: nil)
    let status = try await source.pricingStatus()
    #expect(status == .priced)
  }

  // MARK: - PriceSourceResolver

  @Test("PriceSourceResolver returns FiatPriceSource for fiat instrument")
  func resolverReturnsFiatSourceForFiat() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let utc = try #require(TimeZone(identifier: "UTC"))
    let stockService = StockPriceService(
      client: FixedStockPriceClient(),
      database: database,
      timeZone: utc)
    let resolver = PriceSourceResolver(stockPrices: stockService, cryptoPrices: nil)
    let source = resolver.source(for: aud)
    let quote = try await source.quote(on: date("2026-04-10"))
    #expect(quote.perUnit == Decimal(1))
    #expect(quote.nativeQuote == aud)
  }

  @Test("PriceSourceResolver returns StockPriceSource for stock instrument")
  func resolverReturnsStockSourceForStock() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let utc = try #require(TimeZone(identifier: "UTC"))
    let stockService = StockPriceService(
      client: FixedStockPriceClient(),
      database: database,
      timeZone: utc)
    let resolver = PriceSourceResolver(stockPrices: stockService, cryptoPrices: nil)
    let source = resolver.source(for: bhp)
    // pricingStatus on a stock source is always .priced
    let status = try await source.pricingStatus()
    #expect(status == .priced)
  }

  @Test("PriceSourceResolver returns CryptoPriceSource for crypto instrument")
  func resolverReturnsCryptoSourceForCrypto() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let utc = try #require(TimeZone(identifier: "UTC"))
    let stockService = StockPriceService(
      client: FixedStockPriceClient(),
      database: database,
      timeZone: utc)
    let resolver = PriceSourceResolver(stockPrices: stockService, cryptoPrices: nil)
    let source = resolver.source(for: eth)
    // nil cryptoPrices → pricingStatus returns .priced (doesn't throw)
    let status = try await source.pricingStatus()
    #expect(status == .priced)
  }
}
