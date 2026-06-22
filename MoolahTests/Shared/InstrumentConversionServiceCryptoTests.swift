import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InstrumentConversionService — Crypto")
struct InstrumentConversionServiceCryptoTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let btc = Instrument.crypto(
    chainId: 0, contractAddress: nil, symbol: "BTC", name: "Bitcoin", decimals: 8
  )
  private let aud = Instrument.AUD
  private let usd = Instrument.USD

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      fatalError("Could not parse ISO8601 full-date string: \(string)")
    }
    return result
  }

  private func makeService(
    cryptoPrices: [String: [String: Decimal]] = [:],
    exchangeRates: [String: [String: Decimal]] = [:],
    providerMappings: [CryptoProviderMapping] = []
  ) throws -> FullConversionService {
    let database = try ProfileIndexDatabase.openInMemory()
    let cryptoClient = FixedCryptoPriceClient(prices: cryptoPrices)
    let registrations = providerMappings.map { mapping in
      CryptoRegistration(
        instrument: Self.instrument(forMappingId: mapping.instrumentId),
        mapping: mapping)
    }
    let registrationsById = Dictionary(
      uniqueKeysWithValues: registrations.map { ($0.id, $0) })
    let cryptoService = CryptoPriceService(
      clients: [cryptoClient],
      database: database,
      metadataLookup: { registrationsById[$0] }
    )
    let exchangeClient = FixedRateClient(rates: exchangeRates)
    let exchangeService = ExchangeRateService(
      client: exchangeClient,
      database: database
    )
    let stockService = StockPriceService(client: FixedStockPriceClient(), database: database)
    return FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService
    )
  }

  /// Reconstruct an `Instrument` from a `CryptoProviderMapping.instrumentId`
  /// of the form `"chainId:contractOrNative"`. Test fixtures only need
  /// enough metadata for the registration's `id` to match what the
  /// service is looking up; any other fields are best-effort.
  private static func instrument(forMappingId id: String) -> Instrument {
    let parts = id.split(separator: ":", maxSplits: 1).map(String.init)
    let chainId = Int(parts.first ?? "") ?? 0
    let contract = parts.count > 1 ? parts[1] : "native"
    let isNative = contract == "native"
    return .crypto(
      chainId: chainId,
      contractAddress: isNative ? nil : contract,
      symbol: isNative ? "NATIVE" : contract,
      name: isNative ? "NATIVE" : contract,
      decimals: 18
    )
  }

  // MARK: - Crypto -> Fiat (USD)

  @Test
  func cryptoToUsdUsesDirectPrice() async throws {
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        )
      ]
    )
    let result = try await service.convert(
      dec("2.5"), from: eth, to: usd, on: date("2026-04-10")
    )
    // 2.5 * 1623.45 = 4058.625
    #expect(result == dec("4058.625"))
  }

  // MARK: - Crypto -> Fiat (non-USD, two-hop)

  @Test
  func cryptoToAudGoesViaUsd() async throws {
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      exchangeRates: ["2026-04-10": ["AUD": dec("1.58")]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        )
      ]
    )
    let result = try await service.convert(
      dec("2.5"), from: eth, to: aud, on: date("2026-04-10")
    )
    let expected =
      dec("2.5") * dec("1623.45") * dec("1.58")
    #expect(result == expected)
  }

  // MARK: - Crypto -> Crypto (both non-fiat)

  @Test
  func cryptoToCryptoChainsThroughUsd() async throws {
    let service = try makeService(
      cryptoPrices: [
        "1:native": ["2026-04-10": dec("1623.45")],
        "0:native": ["2026-04-10": dec("63000.00")],
      ],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        ),
        CryptoProviderMapping(
          instrumentId: "0:native", coingeckoId: "bitcoin",
          cryptocompareSymbol: "BTC", binanceSymbol: "BTCUSDT"
        ),
      ]
    )
    let result = try await service.convert(
      Decimal(10), from: eth, to: btc, on: date("2026-04-10")
    )
    let usdValue = Decimal(10) * dec("1623.45")
    let expected = usdValue / dec("63000.00")
    #expect(result == expected)
  }

  // MARK: - Missing provider mapping throws

  @Test
  func missingProviderMappingThrows() async throws {
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]]
    )
    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(1), from: eth, to: usd, on: date("2026-04-10"))
    }
  }

  // MARK: - Fiat -> Crypto (reverse direction)

  @Test
  func fiatToCryptoIsInverseOfCryptoToFiat() async throws {
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        )
      ]
    )
    let result = try await service.convert(
      Decimal(5000), from: usd, to: eth, on: date("2026-04-10")
    )
    let expected = Decimal(5000) / dec("1623.45")
    #expect(result == expected)
  }

  // MARK: - Precision across kinds

  @Test
  func cryptoToFiatPreservesHighPrecisionMultiplication() async throws {
    // Verify that high-decimal crypto quantities preserve precision through conversion.
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("1623.45")]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        )
      ]
    )
    let result = try await service.convert(
      dec("0.00012345"), from: eth, to: usd, on: date("2026-04-10")
    )
    let expected = dec("0.00012345") * dec("1623.45")
    #expect(result == expected)
  }

  @Test
  func zeroDecimalFiatToCryptoGoesThroughUsd() async throws {
    // JPY has 0 decimals; route JPY → USD → ETH should not throw for fiat bridging.
    let jpy = Instrument.fiat(code: "JPY")
    let service = try makeService(
      cryptoPrices: ["1:native": ["2026-04-10": dec("2000.00")]],
      exchangeRates: ["2026-04-10": ["JPY": dec("150.00")]],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        )
      ]
    )
    // 300000 JPY → USD → ETH. 1 USD = 150 JPY, so 300000 JPY = 2000 USD; 1 ETH = 2000 USD → 1 ETH.
    let result = try await service.convert(
      Decimal(300_000), from: jpy, to: eth, on: date("2026-04-10")
    )
    #expect(result == Decimal(1))
  }

  @Test
  func missingCryptoPriceThrows() async throws {
    let service = try makeService(
      cryptoPrices: [:],
      providerMappings: [
        CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        )
      ]
    )
    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(1), from: eth, to: usd, on: date("2026-04-10"))
    }
  }

  /// The conversion service must consult its provider-mappings source on every
  /// conversion so tokens registered after construction become resolvable
  /// without rebuilding the service. `ProfileSession` wires the closure to the
  /// `CryptoPriceService`, which persists registrations to the token
  /// repository; newly-added tokens must flow through without app restart.
  @Test
  func providerMappingsClosureIsQueriedPerConversion() async throws {
    let cryptoClient = FixedCryptoPriceClient(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]]
    )
    let database = try ProfileIndexDatabase.openInMemory()
    let source = MutableRegistrationsSource()
    // Read the actor live per lookup so a registration set after construction
    // is picked up on the next conversion (mirrors the old per-conversion
    // closure read). A failed lookup is not cached, so a later set resolves.
    let cryptoService = CryptoPriceService(
      clients: [cryptoClient],
      database: database,
      metadataLookup: { id in await source.current().first { $0.id == id } }
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

    await #expect(throws: (any Error).self) {
      _ = try await service.convert(Decimal(1), from: eth, to: usd, on: date("2026-04-10"))
    }

    await source.set([
      CryptoRegistration(
        instrument: eth,
        mapping: CryptoProviderMapping(
          instrumentId: "1:native", coingeckoId: "ethereum",
          cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
        )
      )
    ])

    let result = try await service.convert(
      Decimal(1), from: eth, to: usd, on: date("2026-04-10")
    )
    #expect(result == dec("1623.45"))
  }
}

private actor MutableRegistrationsSource {
  private var registrations: [CryptoRegistration] = []

  func current() -> [CryptoRegistration] { registrations }

  func set(_ new: [CryptoRegistration]) { registrations = new }
}
