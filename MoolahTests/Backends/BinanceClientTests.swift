import Foundation
import Testing

@testable import Moolah

@Suite("BinanceClient")
struct BinanceClientTests {
  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  // MARK: - URL construction

  @Test
  func klinesURLIncludesSymbolAndDateRange() throws {
    let from = try date("2026-04-01")
    let to = try date("2026-04-10")
    let url = BinanceClient.klinesURL(symbol: "ETHUSDT", from: from, to: to)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "api.binance.com")
    #expect(components.path == "/api/v3/klines")
    let items = try #require(components.queryItems)
    let queryItems = try Dictionary(
      uniqueKeysWithValues: items.map { try ($0.name, #require($0.value)) })
    #expect(queryItems["symbol"] == "ETHUSDT")
    #expect(queryItems["interval"] == "1d")
    #expect(queryItems["startTime"] != nil)
    #expect(queryItems["endTime"] != nil)
  }

  // MARK: - Response parsing

  @Test
  func parseKlinesResponse() throws {
    // Binance klines are arrays: [openTime, open, high, low, close, volume, closeTime, ...]
    let json = Data(
      """
      [
        [1743465600000, "1600.00", "1650.00", "1590.00", "1623.45", "1000", 1743551999999, "0", 0, "0", "0", "0"],
        [1743552000000, "1623.45", "1670.00", "1620.00", "1650.00", "1100", 1743638399999, "0", 0, "0", "0", "0"]
      ]
      """.utf8)

    let prices = try BinanceClient.parseKlinesResponse(json)
    #expect(prices.count == 2)
    #expect(prices.values.contains(dec("1623.45")))
    #expect(prices.values.contains(dec("1650.00")))
  }

  // MARK: - USDT to USD conversion

  @Test
  func pricesAreMultipliedByUsdtRate() throws {
    let usdtPrices: [String: Decimal] = ["2026-04-10": dec("1000.00")]
    let converted = BinanceClient.applyUsdtRate(usdtPrices, rate: dec("0.999"))
    #expect(converted["2026-04-10"] == dec("999.000"))
  }

  @Test
  func defaultUsdtRateIsOne() throws {
    let usdtPrices: [String: Decimal] = ["2026-04-10": dec("1000.00")]
    let converted = BinanceClient.applyUsdtRate(usdtPrices, rate: Decimal(1))
    #expect(converted["2026-04-10"] == dec("1000.00"))
  }

  // MARK: - Closure-based init

  @Test
  func initAcceptsDateAwareUsdtRateClosure() {
    let services = NetworkingServices(
      session: URLSession(configuration: .ephemeral))
    let client = BinanceClient(
      http: services.client(forHost: "api.binance.com")
    ) { _ in
      dec("0.998")
    }
    // Validates the closure init compiles
    _ = client
  }

  // MARK: - Exchange info parsing

  @Test
  func parseExchangeInfoResponse_findsUsdtPairs() throws {
    let json = Data(
      """
      {
          "symbols": [
              { "symbol": "ETHUSDT", "baseAsset": "ETH", "quoteAsset": "USDT", "status": "TRADING" },
              { "symbol": "BTCUSDT", "baseAsset": "BTC", "quoteAsset": "USDT", "status": "TRADING" },
              { "symbol": "ETHBTC", "baseAsset": "ETH", "quoteAsset": "BTC", "status": "TRADING" },
              { "symbol": "OLDUSDT", "baseAsset": "OLD", "quoteAsset": "USDT", "status": "BREAK" }
          ]
      }
      """.utf8)

    let pairs = try BinanceClient.parseExchangeInfoResponse(json)
    #expect(pairs.contains("ETHUSDT"))
    #expect(pairs.contains("BTCUSDT"))
    #expect(!pairs.contains("ETHBTC"))
    #expect(!pairs.contains("OLDUSDT"))
  }

  // MARK: - Mapping without Binance symbol

  @Test
  func mappingWithoutBinanceSymbolThrows() async {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:0xabc", coingeckoId: nil, binanceSymbol: nil
    )
    let services = NetworkingServices(
      session: URLSession(configuration: .ephemeral))
    let client = BinanceClient(http: services.client(forHost: "api.binance.com"))
    await #expect(throws: CryptoPriceError.self) {
      try await client.dailyPrice(for: mapping, on: Date())
    }
  }
}
