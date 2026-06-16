import Foundation
import Testing

@testable import Moolah

/// Auth-query-item behaviour for `CryptoCompareClient`'s URL builders, split
/// from `CryptoCompareClientTests` to keep each suite under the type-body
/// length limit. CryptoCompare's `min-api` host now 401s keyless requests, so
/// the `api_key` query item is what restores access.
@Suite("CryptoCompareClient auth")
struct CryptoCompareClientAuthTests {
  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  @Test
  func dailyPricesURLIncludesApiKeyWhenConfigured() throws {
    let from = try date("2026-04-01")
    let to = try date("2026-04-10")
    let url = CryptoCompareClient.histodayURL(symbol: "USDT", from: from, to: to, apiKey: "k123")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    let queryItems = try Dictionary(
      uniqueKeysWithValues: items.map { try ($0.name, #require($0.value)) })
    #expect(queryItems["api_key"] == "k123")
  }

  @Test
  func dailyPricesURLOmitsApiKeyWhenEmpty() throws {
    let from = try date("2026-04-01")
    let to = try date("2026-04-10")
    let url = CryptoCompareClient.histodayURL(symbol: "USDT", from: from, to: to, apiKey: "")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    #expect(!items.contains { $0.name == "api_key" })
  }

  @Test
  func currentPricesURLIncludesApiKeyWhenConfigured() throws {
    let url = CryptoCompareClient.priceMultiURL(symbols: ["ETH", "BTC"], apiKey: "k123")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    let queryItems = try Dictionary(
      uniqueKeysWithValues: items.map { try ($0.name, #require($0.value)) })
    #expect(queryItems["api_key"] == "k123")
  }

  @Test
  func currentPricesURLOmitsApiKeyWhenEmpty() throws {
    let url = CryptoCompareClient.priceMultiURL(symbols: ["ETH", "BTC"], apiKey: "")
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    #expect(!items.contains { $0.name == "api_key" })
  }
}
