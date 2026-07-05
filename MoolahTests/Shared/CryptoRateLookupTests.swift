import Foundation
import Testing

@testable import Moolah

/// Pins the ordered first-success behaviour `CryptoRateLookup` gives the
/// Binance USDT/USD conversion rate: try each client in turn, skip any that
/// throws, and fall back to the supplied default only when every client fails.
@Suite("CryptoRateLookup")
struct CryptoRateLookupTests {
  private let usdtMapping = CryptoProviderMapping(
    instrumentId: "1:0xdac17f958d2ee523a2206206994597c13d831ec7",
    coingeckoId: "tether", binanceSymbol: nil
  )

  private func day(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  @Test("Returns the first client's rate when it succeeds")
  func firstClientWins() async throws {
    let date = try day("2024-01-01")
    let first = FixedCryptoPriceClient(
      prices: ["1:0xdac17f958d2ee523a2206206994597c13d831ec7": ["2024-01-01": dec("0.97")]],
      syncProvider: .cryptoCompare)
    let second = FixedCryptoPriceClient(
      prices: ["1:0xdac17f958d2ee523a2206206994597c13d831ec7": ["2024-01-01": dec("1.50")]],
      syncProvider: .coinGecko)

    let rate = await CryptoRateLookup.firstAvailableRate(
      for: usdtMapping, on: date, using: [first, second], default: Decimal(1))

    #expect(rate == dec("0.97"))
  }

  @Test("Skips a failing client and uses the next that succeeds")
  func fallsThroughToNextClient() async throws {
    let date = try day("2024-01-01")
    let failing = FixedCryptoPriceClient(shouldFail: true, syncProvider: .cryptoCompare)
    let working = FixedCryptoPriceClient(
      prices: ["1:0xdac17f958d2ee523a2206206994597c13d831ec7": ["2024-01-01": dec("0.99")]],
      syncProvider: .coinGecko)

    let rate = await CryptoRateLookup.firstAvailableRate(
      for: usdtMapping, on: date, using: [failing, working], default: Decimal(1))

    #expect(rate == dec("0.99"))
  }

  @Test("Returns the default when every client fails")
  func allFailReturnsDefault() async throws {
    let date = try day("2024-01-01")
    let failingCC = FixedCryptoPriceClient(shouldFail: true, syncProvider: .cryptoCompare)
    let failingCG = FixedCryptoPriceClient(shouldFail: true, syncProvider: .coinGecko)

    let rate = await CryptoRateLookup.firstAvailableRate(
      for: usdtMapping, on: date, using: [failingCC, failingCG], default: Decimal(42))

    #expect(rate == Decimal(42))
  }

  @Test("The stablecoin peg supplies $1 for canonical USDT before the default")
  func pegSuppliesOneForCanonicalUsdt() async throws {
    let date = try day("2024-01-01")
    let failingCC = FixedCryptoPriceClient(shouldFail: true, syncProvider: .cryptoCompare)
    let failingCG = FixedCryptoPriceClient(shouldFail: true, syncProvider: .coinGecko)

    // A deliberately wrong default proves the value came from the peg, not it.
    let rate = await CryptoRateLookup.firstAvailableRate(
      for: usdtMapping, on: date,
      using: [failingCC, failingCG, StablecoinPriceClient()], default: Decimal(999))

    #expect(rate == Decimal(1))
  }
}
