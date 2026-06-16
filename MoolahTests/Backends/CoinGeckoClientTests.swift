import Foundation
import Testing

@testable import Moolah

@Suite("CoinGeckoClient")
struct CoinGeckoClientTests {
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil
  )

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  // MARK: - URL construction

  @Test
  func marketChartRangeURLIncludesCoinIdAndDateRange() throws {
    let from = try date("2024-01-10")
    let to = try date("2024-01-20")
    let url = CoinGeckoClient.marketChartRangeURL(
      coinId: "ethereum", from: from, to: to, apiKey: "test-key"
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "pro-api.coingecko.com")
    #expect(components.path == "/api/v3/coins/ethereum/market_chart/range")
    let items = try #require(components.queryItems)
    let queryItems = try Dictionary(
      uniqueKeysWithValues: items.map { try ($0.name, #require($0.value)) })
    #expect(queryItems["vs_currency"] == "usd")
    #expect(queryItems["from"] == String(Int(from.timeIntervalSince1970)))
    #expect(queryItems["to"] == String(Int(to.timeIntervalSince1970) + 86_400))
    #expect(queryItems["x_cg_pro_api_key"] == "test-key")
  }

  @Test
  func marketChartRangeURLExtendsSingleDayRangeByOneDay() throws {
    let day = try date("2024-03-15")
    let url = CoinGeckoClient.marketChartRangeURL(
      coinId: "bitcoin", from: day, to: day, apiKey: "k"
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    let queryItems = try Dictionary(
      uniqueKeysWithValues: items.map { try ($0.name, #require($0.value)) })
    let fromTimestamp = Int(day.timeIntervalSince1970)
    // A single-day `from == to` window must not collapse to an empty
    // range: `to` is pushed to the next-day boundary so the day's prices
    // are returned.
    #expect(queryItems["from"] == String(fromTimestamp))
    #expect(queryItems["to"] == String(fromTimestamp + 86_400))
  }

  @Test
  func simplePriceURLIncludesMultipleIds() throws {
    let url = CoinGeckoClient.simplePriceURL(
      coinIds: ["ethereum", "bitcoin"], apiKey: "test-key"
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.path == "/api/v3/simple/price")
    let items = try #require(components.queryItems)
    let queryItems = try Dictionary(
      uniqueKeysWithValues: items.map { try ($0.name, #require($0.value)) })
    #expect(queryItems["ids"] == "ethereum,bitcoin")
    #expect(queryItems["vs_currencies"] == "usd")
  }

  // MARK: - Public free-tier fallback (no API key)

  @Test
  func marketChartRangeURLUsesPublicHostWhenApiKeyIsEmpty() throws {
    let from = try date("2024-01-10")
    let to = try date("2024-01-11")
    let url = CoinGeckoClient.marketChartRangeURL(
      coinId: "ethereum", from: from, to: to, apiKey: "")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "api.coingecko.com")
    #expect(components.path == "/api/v3/coins/ethereum/market_chart/range")
    let names = Set((components.queryItems ?? []).map(\.name))
    #expect(!names.contains("x_cg_pro_api_key"))
  }

  @Test
  func simplePriceURLUsesPublicHostWhenApiKeyIsEmpty() throws {
    let url = CoinGeckoClient.simplePriceURL(coinIds: ["ethereum"], apiKey: "")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "api.coingecko.com")
    let names = Set((components.queryItems ?? []).map(\.name))
    #expect(!names.contains("x_cg_pro_api_key"))
  }

  @Test
  func contractLookupURLUsesPublicHostWhenApiKeyIsEmpty() throws {
    let url = CoinGeckoClient.contractLookupURL(
      platformId: "ethereum",
      contractAddress: "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48",
      apiKey: ""
    )
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "api.coingecko.com")
    #expect(
      components.path
        == "/api/v3/coins/ethereum/contract/0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
    )
    #expect((components.queryItems ?? []).isEmpty)
  }

  @Test
  func assetPlatformsURLUsesPublicHostWhenApiKeyIsEmpty() throws {
    let url = CoinGeckoClient.assetPlatformsURL(apiKey: "")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "api.coingecko.com")
    #expect(components.path == "/api/v3/asset_platforms")
    #expect((components.queryItems ?? []).isEmpty)
  }

  @Test
  func coinsListURLUsesPublicHostAndIncludesPlatformWhenApiKeyIsEmpty() throws {
    let url = CoinGeckoClient.coinsListURL(apiKey: "")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "api.coingecko.com")
    #expect(components.path == "/api/v3/coins/list")
    let items = try #require(components.queryItems)
    let queryItems = try Dictionary(
      uniqueKeysWithValues: items.map { try ($0.name, #require($0.value)) })
    #expect(queryItems["include_platform"] == "true")
    #expect(queryItems["x_cg_pro_api_key"] == nil)
  }

  @Test
  func coinsListURLUsesProHostWithKeyWhenApiKeyIsSet() throws {
    let url = CoinGeckoClient.coinsListURL(apiKey: "prokey")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "pro-api.coingecko.com")
    #expect(components.path == "/api/v3/coins/list")
    let items = try #require(components.queryItems)
    let queryItems = try Dictionary(
      uniqueKeysWithValues: items.map { try ($0.name, #require($0.value)) })
    #expect(queryItems["include_platform"] == "true")
    #expect(queryItems["x_cg_pro_api_key"] == "prokey")
  }

  // MARK: - Response parsing

  @Test
  func parseMarketChartResponse() throws {
    let json = Data(
      """
      {
        "prices": [
          [1743465600000, 1623.45],
          [1743552000000, 1650.00]
        ]
      }
      """.utf8)

    let prices = try CoinGeckoClient.parseMarketChartResponse(json)
    #expect(prices.count == 2)
    #expect(prices.values.contains(dec("1623.45")))
    #expect(prices.values.contains(dec("1650")))
  }

  @Test
  func parseSimplePriceResponse() throws {
    let json = Data(
      """
      {
        "ethereum": {"usd": 1623.45},
        "bitcoin": {"usd": 67890.12}
      }
      """.utf8)

    let prices = try CoinGeckoClient.parseSimplePriceResponse(json)
    #expect(prices["ethereum"] == dec("1623.45"))
    #expect(prices["bitcoin"] == dec("67890.12"))
  }

  // MARK: - Asset platforms parsing

  @Test
  func parseAssetPlatformsResponse_mapsChainIdToSlug() throws {
    let json = Data(
      """
      [
          { "id": "ethereum", "chain_identifier": 1, "name": "Ethereum" },
          { "id": "optimistic-ethereum", "chain_identifier": 10, "name": "Optimism" },
          { "id": "polygon-pos", "chain_identifier": 137, "name": "Polygon" },
          { "id": "no-chain", "chain_identifier": null, "name": "No Chain" }
      ]
      """.utf8)

    let mapping = try CoinGeckoClient.parseAssetPlatformsResponse(json)
    #expect(mapping[1] == "ethereum")
    #expect(mapping[10] == "optimistic-ethereum")
    #expect(mapping[137] == "polygon-pos")
    #expect(mapping.count == 3)
  }

  // MARK: - Contract lookup parsing

  @Test
  func parseContractLookupResponse_extractsTokenDetails() throws {
    let json = Data(
      """
      {
          "id": "uniswap",
          "symbol": "uni",
          "name": "Uniswap",
          "detail_platforms": {
              "ethereum": { "decimal_place": 18, "contract_address": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984" }
          }
      }
      """.utf8)

    let result = try CoinGeckoClient.parseContractLookupResponse(json)
    #expect(result.id == "uniswap")
    #expect(result.symbol == "uni")
    #expect(result.name == "Uniswap")
    #expect(result.decimals == 18)
  }

  // MARK: - Mapping without CoinGecko ID

  @Test
  func mappingWithoutCoinGeckoIdThrows() async {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:0xabc", coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil
    )
    let services = NetworkingServices(
      session: URLSession(configuration: .ephemeral))
    let client = CoinGeckoClient(
      apiKeyProvider: { "key" }, networking: services)
    await #expect(throws: CryptoPriceError.self) {
      try await client.dailyPrice(for: mapping, on: Date())
    }
  }
}
