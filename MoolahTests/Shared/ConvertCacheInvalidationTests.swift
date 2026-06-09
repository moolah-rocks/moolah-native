import Foundation
import GRDB
import Testing
import os

@testable import Moolah

@Suite("FullConversionService.invalidateCache")
struct ConvertCacheInvalidationTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let usd = Instrument.USD

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  private func ethRegistration() -> CryptoRegistration {
    CryptoRegistration(
      instrument: eth,
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
      )
    )
  }

  /// Invalidating a crypto instrument must purge the underlying
  /// `CryptoPriceService` cache for that instrument so the next
  /// conversion goes back to the network. Verified by toggling a
  /// `Toggleable` price client between "available" and "fail": once the
  /// cache is cleared, the next conversion observes the fail and throws.
  @Test
  func invalidateCacheForCryptoInstrumentForcesRefetch() async throws {
    let toggle = ToggleableCryptoPriceClient()
    await toggle.setPrices(["1:native": ["2026-04-10": dec("1623.45")]])

    let database = try ProfileIndexDatabase.openInMemory()
    let cryptoService = CryptoPriceService(
      clients: [toggle], database: database)
    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: [:]), database: database)
    let stockService = StockPriceService(client: FixedStockPriceClient(), database: database)
    let registration = ethRegistration()
    let service = FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService,
      cryptoRegistrations: { [registration] }
    )

    // First conversion populates the cache.
    let first = try await service.convert(
      Decimal(1), from: eth, to: usd, on: try date("2026-04-10"))
    #expect(first == dec("1623.45"))

    // Force the underlying client to throw on subsequent calls. With
    // the cache still warm, the next conversion still succeeds.
    await toggle.setShouldFail(true)
    let second = try await service.convert(
      Decimal(1), from: eth, to: usd, on: try date("2026-04-10"))
    #expect(second == dec("1623.45"))

    // Invalidate the cache for this instrument — the next conversion
    // must round-trip through the (now-failing) client and surface the
    // error.
    await service.invalidateCache(for: eth)
    await #expect(throws: (any Error).self) {
      _ = try await service.convert(
        Decimal(1), from: eth, to: usd, on: try date("2026-04-10"))
    }
  }

  /// Fiat invalidation is a documented no-op — the rate cache for fiat
  /// pairs lives in `ExchangeRateService` and is keyed differently. The
  /// call must complete without trapping or throwing and must not
  /// affect any subsequent crypto conversion.
  @Test
  func invalidateCacheForFiatInstrumentIsNoOp() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let cryptoService = CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: ["1:native": ["2026-04-10": dec("1623.45")]])],
      database: database)
    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: [:]), database: database)
    let stockService = StockPriceService(client: FixedStockPriceClient(), database: database)
    let service = FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService,
      cryptoRegistrations: { [self.ethRegistration()] }
    )

    // Warm the crypto cache.
    let first = try await service.convert(
      Decimal(1), from: eth, to: usd, on: try date("2026-04-10"))
    #expect(first == dec("1623.45"))

    // Invalidate USD (fiat) — must be a no-op so the next crypto
    // conversion still hits the warm crypto cache.
    await service.invalidateCache(for: usd)

    let second = try await service.convert(
      Decimal(1), from: eth, to: usd, on: try date("2026-04-10"))
    #expect(second == dec("1623.45"))
  }
}
