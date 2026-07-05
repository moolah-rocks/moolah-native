import Foundation
import Testing

@testable import Moolah

/// Pins `StablecoinPriceClient`: a last-resort price source that returns a flat
/// $1 for canonical USDC / USDT deployments (per `CanonicalTokenRegistry`) and
/// declines everything else by throwing `.noProviderMapping`.
@Suite("StablecoinPriceClient")
struct StablecoinPriceClientTests {
  private let client = StablecoinPriceClient()

  private let mainnetUSDC = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"
  private let mainnetUSDT = "1:0xdac17f958d2ee523a2206206994597c13d831ec7"
  private let optimismUSDC = "10:0x0b2c639c533813f4aa9d7837caf62653d097ff85"
  private let mainnetUNI = "1:0x1f9840a85d5af5bf1d1762f925bdaddc4201f984"

  private func mapping(_ instrumentId: String) -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: instrumentId, coingeckoId: nil, binanceSymbol: nil)
  }

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  @Test("Reports the pegged-stablecoin sync provider")
  func reportsSyncProvider() {
    #expect(client.syncProvider == .peggedStablecoin)
  }

  @Test("Mainnet USDC daily-price range yields $1 for every day")
  func mainnetUSDCRangeIsAllOne() async throws {
    let start = try date("2024-01-01")
    let end = try date("2024-01-03")
    let prices = try await client.dailyPrices(for: mapping(mainnetUSDC), in: start...end)

    #expect(prices.count == 3)
    #expect(prices.keys.sorted() == ["2024-01-01", "2024-01-02", "2024-01-03"])
    #expect(prices.values.allSatisfy { $0 == Decimal(1) })
  }

  @Test("Mainnet USDT single-day price is $1")
  func mainnetUSDTSingleDayIsOne() async throws {
    let price = try await client.dailyPrice(for: mapping(mainnetUSDT), on: try date("2024-06-01"))
    #expect(price == Decimal(1))
  }

  @Test("Optimism USDC is recognised as pegged")
  func optimismUSDCIsOne() async throws {
    let price = try await client.dailyPrice(for: mapping(optimismUSDC), on: try date("2024-06-01"))
    #expect(price == Decimal(1))
  }

  @Test("Non-stablecoin token has no provider mapping")
  func nonStablecoinThrows() async throws {
    await #expect(
      throws: CryptoPriceError.noProviderMapping(
        tokenId: mainnetUNI, provider: "Stablecoin peg")
    ) {
      _ = try await client.dailyPrice(for: mapping(mainnetUNI), on: try date("2024-06-01"))
    }
  }

  @Test("Native asset id has no provider mapping")
  func nativeThrows() async throws {
    let native = "1:native"
    await #expect(
      throws: CryptoPriceError.noProviderMapping(
        tokenId: native, provider: "Stablecoin peg")
    ) {
      _ = try await client.dailyPrice(for: mapping(native), on: try date("2024-06-01"))
    }
  }

  @Test("Impersonator at a non-canonical address has no provider mapping")
  func impersonatorThrows() async throws {
    let impersonator = "1:0x000000000000000000000000000000000000dead"
    await #expect(
      throws: CryptoPriceError.noProviderMapping(
        tokenId: impersonator, provider: "Stablecoin peg")
    ) {
      _ = try await client.dailyPrice(for: mapping(impersonator), on: try date("2024-06-01"))
    }
  }

  @Test("Current prices report $1 for stablecoins and omit others")
  func currentPricesPegStablecoinsOnly() async throws {
    let prices = try await client.currentPrices(for: [
      mapping(mainnetUSDC), mapping(mainnetUSDT), mapping(mainnetUNI),
    ])

    #expect(prices[mainnetUSDC] == Decimal(1))
    #expect(prices[mainnetUSDT] == Decimal(1))
    #expect(prices[mainnetUNI] == nil)
    #expect(prices.count == 2)
  }
}
