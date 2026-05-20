// MoolahTests/Backends/CryptoCompareClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoCompareClient")
struct CryptoCompareClientTests {
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: nil, cryptocompareSymbol: "ETH", binanceSymbol: nil
  )

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  // MARK: - URL construction

  @Test
  func dailyPricesURLIncludesSymbolAndDateRange() throws {
    let from = try date("2026-04-01")
    let to = try date("2026-04-10")
    let url = CryptoCompareClient.histodayURL(symbol: "ETH", from: from, to: to)
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    #expect(components.host == "min-api.cryptocompare.com")
    #expect(components.path == "/data/v2/histoday")
    let items = try #require(components.queryItems)
    let queryItems = try Dictionary(
      uniqueKeysWithValues: items.map { try ($0.name, #require($0.value)) })
    #expect(queryItems["fsym"] == "ETH")
    #expect(queryItems["tsym"] == "USD")
    #expect(queryItems["limit"] != nil)
    #expect(queryItems["toTs"] != nil)
  }

  @Test
  func currentPricesURLIncludesMultipleSymbols() throws {
    let url = CryptoCompareClient.priceMultiURL(symbols: ["ETH", "BTC"])
    let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
    let items = try #require(components.queryItems)
    let queryItems = try Dictionary(
      uniqueKeysWithValues: items.map { try ($0.name, #require($0.value)) })
    #expect(queryItems["fsyms"] == "ETH,BTC")
    #expect(queryItems["tsyms"] == "USD")
  }

  // MARK: - Response parsing

  @Test
  func parseHistodayResponse() throws {
    let json = Data(
      """
      {
        "Response": "Success",
        "Data": {
          "Data": [
            {"time": 1743465600, "close": 1623.45},
            {"time": 1743552000, "close": 1650.00}
          ]
        }
      }
      """.utf8)

    let prices = try CryptoCompareClient.parseHistodayResponse(json)
    #expect(prices.count == 2)
    #expect(prices.values.contains(dec("1623.45")))
    #expect(prices.values.contains(dec("1650")))
  }

  @Test
  func parsePriceMultiResponse() throws {
    let json = Data(
      """
      {
        "ETH": {"USD": 1623.45},
        "BTC": {"USD": 67890.12}
      }
      """.utf8)

    let prices = try CryptoCompareClient.parsePriceMultiResponse(json)
    #expect(prices["ETH"] == dec("1623.45"))
    #expect(prices["BTC"] == dec("67890.12"))
  }

  // MARK: - Coin list parsing

  @Test
  func parseCoinListResponse_extractsSymbolByContractAddress() throws {
    let json = Data(
      """
      {
          "Data": {
              "ETH": {
                  "Symbol": "ETH",
                  "CoinName": "Ethereum",
                  "SmartContractAddress": "N/A"
              },
              "UNI": {
                  "Symbol": "UNI",
                  "CoinName": "Uniswap",
                  "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
              },
              "SCAM": {
                  "Symbol": "SCAM",
                  "CoinName": "Scam Token",
                  "SmartContractAddress": "0xdeadbeef"
              }
          }
      }
      """.utf8)

    let index = try CryptoCompareClient.parseCoinListResponse(json)
    #expect(index["0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"] == "UNI")
    #expect(index["0xdeadbeef"] == "SCAM")
    #expect(index["N/A"] == nil)
  }

  @Test
  func parseCoinListResponse_nativeTokenHasNoContractEntry() throws {
    let json = Data(
      """
      {
          "Data": {
              "BTC": {
                  "Symbol": "BTC",
                  "CoinName": "Bitcoin",
                  "SmartContractAddress": "N/A"
              }
          }
      }
      """.utf8)

    let index = try CryptoCompareClient.parseCoinListResponse(json)
    #expect(index.isEmpty)
  }

  @Test
  func findNativeSymbol_matchesBySymbol() throws {
    let json = Data(
      """
      {
          "Data": {
              "BTC": { "Symbol": "BTC", "CoinName": "Bitcoin", "SmartContractAddress": "N/A" },
              "ETH": { "Symbol": "ETH", "CoinName": "Ethereum", "SmartContractAddress": "N/A" }
          }
      }
      """.utf8)

    let nativeSymbols = try CryptoCompareClient.parseNativeSymbols(json)
    #expect(nativeSymbols.contains("BTC"))
    #expect(nativeSymbols.contains("ETH"))
  }

  // CryptoCompare occasionally ships entries with missing fields (e.g. an MLS
  // row missing `CoinName`). A single malformed row must not kill the entire
  // list — token resolution would otherwise fail for every crypto.
  // See https://github.com/ajsutton/moolah-native/issues/746.
  @Test
  func parseCoinListResponse_skipsMalformedEntries() throws {
    let json = Data(
      """
      {
          "Data": {
              "MLS": {
                  "Symbol": "MLS",
                  "SmartContractAddress": "N/A"
              },
              "UNI": {
                  "Symbol": "UNI",
                  "CoinName": "Uniswap",
                  "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
              },
              "BROKEN": null
          }
      }
      """.utf8)

    let index = try CryptoCompareClient.parseCoinListResponse(json)
    #expect(index["0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"] == "UNI")
  }

  @Test
  func parseNativeSymbols_skipsMalformedEntries() throws {
    let json = Data(
      """
      {
          "Data": {
              "MLS": { "Symbol": "MLS", "SmartContractAddress": "N/A" },
              "BTC": { "Symbol": "BTC", "CoinName": "Bitcoin", "SmartContractAddress": "N/A" },
              "BROKEN": null
          }
      }
      """.utf8)

    let nativeSymbols = try CryptoCompareClient.parseNativeSymbols(json)
    #expect(nativeSymbols.contains("BTC"))
    #expect(nativeSymbols.contains("MLS"))
  }

  /// USDT (and other stablecoins primary-listed by CryptoCompare) ship
  /// without a `SmartContractAddress` field at all. The parser must keep
  /// the entry around so the by-symbol post-confirm path in the resolver
  /// can find it once CoinGecko has verified the contract identity.
  @Test
  func parseCoinListResponse_preservesEntriesMissingSmartContractAddress() throws {
    let json = Data(
      """
      {
          "Data": {
              "USDT": {
                  "Symbol": "USDT",
                  "CoinName": "Tether"
              },
              "UNI": {
                  "Symbol": "UNI",
                  "CoinName": "Uniswap",
                  "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
              }
          }
      }
      """.utf8)

    let index = try CryptoCompareClient.parseCoinListResponse(json)
    // USDT lacks SmartContractAddress so it has no contract entry — the
    // contract-address index is unchanged. UNI must still resolve.
    #expect(index["0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"] == "UNI")
  }

  @Test
  func parseCoinSymbols_returnsEverySymbolIncludingThoseWithoutContract() throws {
    let json = Data(
      """
      {
          "Data": {
              "USDT": { "Symbol": "USDT", "CoinName": "Tether" },
              "BTC": { "Symbol": "BTC", "CoinName": "Bitcoin", "SmartContractAddress": "N/A" },
              "UNI": {
                  "Symbol": "UNI",
                  "CoinName": "Uniswap",
                  "SmartContractAddress": "0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"
              },
              "BROKEN": null
          }
      }
      """.utf8)

    let symbols = try CryptoCompareClient.parseCoinSymbols(json)
    #expect(symbols.contains("USDT"))
    #expect(symbols.contains("BTC"))
    #expect(symbols.contains("UNI"))
    #expect(!symbols.contains("BROKEN"))
  }

  // MARK: - Mapping without CryptoCompare symbol

  @Test
  func mappingWithoutCryptoCompareSymbolThrows() async {
    let mapping = CryptoProviderMapping(
      instrumentId: "1:0xabc", coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil
    )
    let client = CryptoCompareClient(session: URLSession.shared)
    await #expect(throws: CryptoPriceError.self) {
      try await client.dailyPrice(for: mapping, on: Date())
    }
  }
}
