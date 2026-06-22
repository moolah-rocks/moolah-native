import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("FullConversionService — providerMappings throws")
struct FullConversionErrorPropagationTests {
  struct FakeRegistryError: Error {}

  /// When the crypto metadata lookup throws (e.g. registry read failure), the
  /// error must propagate through `convert(_:from:to:on:)` for a crypto
  /// conversion rather than being silently collapsed to a missing-mapping —
  /// which would masquerade as a spurious `noProviderMapping` error and
  /// violate Rule 11 of `guides/INSTRUMENT_CONVERSION_GUIDE.md`. The throw is
  /// rethrown by `CryptoPriceService.registration(for:)` at price time,
  /// surfacing exactly as the old registry-closure throw did.
  @Test
  func cryptoConversionPropagatesRegistryError() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let cryptoService = CryptoPriceService(
      clients: [FixedCryptoPriceClient()],
      database: database,
      metadataLookup: { _ in throw FakeRegistryError() }
    )
    let exchangeService = ExchangeRateService(
      client: FixedRateClient(rates: [:]),
      database: database
    )
    let stockService = StockPriceService(client: FixedStockPriceClient(), database: database)

    let service = FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService
    )

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH",
      name: "Ethereum", decimals: 18
    )

    await #expect(throws: FakeRegistryError.self) {
      _ = try await service.convert(
        Decimal(1), from: eth, to: Instrument.USD, on: Date()
      )
    }
  }
}
