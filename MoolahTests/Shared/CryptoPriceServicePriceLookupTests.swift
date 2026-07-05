import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("CryptoPriceService.priceLookup")
struct CryptoPriceServicePriceLookupTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    binanceSymbol: "ETHUSDT"
  )

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  private func makeService(
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false
  ) throws -> CryptoPriceService {
    let database = try ProfileIndexDatabase.openInMemory()
    return CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)],
      database: database
    )
  }

  @Test
  func pricedRegistrationProducesPriced() async throws {
    let service = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]]
    )
    let registration = CryptoRegistration(
      instrument: ethInstrument, mapping: ethMapping, pricingStatus: .priced)

    let lookup = try await service.priceLookup(for: registration, on: try date("2026-04-10"))

    #expect(lookup == .priced(dec("1623.45")))
  }

  /// `.unpriced` must short-circuit to `.knownZero` *before* the provider
  /// is consulted — wiring `shouldFail = true` would throw if the call
  /// reached the underlying client. The lookup path must never depend on
  /// network availability for an `.unpriced` token.
  @Test
  func unpricedRegistrationReturnsKnownZeroWithoutInvokingProvider() async throws {
    let service = try makeService(prices: [:], shouldFail: true)
    let registration = CryptoRegistration(
      instrument: ethInstrument, mapping: ethMapping, pricingStatus: .unpriced)

    let lookup = try await service.priceLookup(for: registration, on: try date("2026-04-10"))

    #expect(lookup == .knownZero)
  }

  /// `.spam` behaves identically to `.unpriced` at the lookup layer —
  /// the provider must not be consulted, no error must surface.
  @Test
  func spamRegistrationReturnsKnownZeroWithoutInvokingProvider() async throws {
    let service = try makeService(prices: [:], shouldFail: true)
    let registration = CryptoRegistration(
      instrument: ethInstrument, mapping: ethMapping, pricingStatus: .spam)

    let lookup = try await service.priceLookup(for: registration, on: try date("2026-04-10"))

    #expect(lookup == .knownZero)
  }

  /// Provider failure on a `.priced` registration must propagate as a
  /// thrown error — never collapse to `.knownZero`. This is the
  /// load-bearing distinction Stage 2 introduces.
  @Test
  func pricedRegistrationProviderFailureThrows() async throws {
    let service = try makeService(prices: [:], shouldFail: true)
    let registration = CryptoRegistration(
      instrument: ethInstrument, mapping: ethMapping, pricingStatus: .priced)

    await #expect(throws: (any Error).self) {
      _ = try await service.priceLookup(for: registration, on: try date("2026-04-10"))
    }
  }
}
