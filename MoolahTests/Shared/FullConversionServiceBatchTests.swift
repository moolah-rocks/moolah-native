import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the optimised `convertResultBatch(_:)` override on
/// `FullConversionService`: distinct `(from, to, day)` keys resolve once
/// (populating the shared `rateCache`), every request maps to its outcome
/// in order, mixed `.value` / `.knownZero` / `.failure` are preserved, and
/// cancellation rethrows.
///
/// The exact conversion math is pinned by
/// `FullConversionServiceConvertResultTests` / `…CachingTests`; this suite
/// pins the batch-specific behaviour (dedup, ordering, per-element
/// degradation, cancellation).
@Suite("FullConversionService.convertResultBatch")
struct FullConversionServiceBatchTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let usd = Instrument.USD
  private let aud = Instrument.AUD
  private let eur = Instrument.fiat(code: "EUR")

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  private func request(
    _ quantity: Decimal, from: Instrument, to: Instrument, on date: Date
  ) -> BatchConversionRequest {
    BatchConversionRequest(
      amount: InstrumentAmount(quantity: quantity, instrument: from),
      target: to,
      date: date)
  }

  private struct Bundle {
    let service: FullConversionService
  }

  private func makeService(
    cryptoPrices: [String: [String: Decimal]] = [:],
    exchangeRates: [String: [String: Decimal]] = [:],
    registrations: [CryptoRegistration] = [],
    exchangeClient: ExchangeRateClient? = nil
  ) throws -> Bundle {
    let database = try ProfileIndexDatabase.openInMemory()
    let utc = try #require(TimeZone(identifier: "UTC"))
    let cryptoService = CryptoPriceService(
      clients: [FixedCryptoPriceClient(prices: cryptoPrices)],
      database: database,
      timeZone: utc
    )
    let exchangeService = ExchangeRateService(
      client: exchangeClient ?? FixedRateClient(rates: exchangeRates),
      database: database,
      timeZone: utc
    )
    let stockService = StockPriceService(
      client: FixedStockPriceClient(), database: database, timeZone: utc)
    let service = FullConversionService(
      exchangeRates: exchangeService,
      stockPrices: stockService,
      cryptoPrices: cryptoService,
      cryptoRegistrations: { registrations }
    )
    return Bundle(service: service)
  }

  private func pricedEthRegistration() -> CryptoRegistration {
    CryptoRegistration(
      instrument: eth,
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
      ),
      pricingStatus: .priced
    )
  }

  // MARK: - Ordering & values

  /// Outcomes come back in request order with the correct converted
  /// amounts.
  @Test
  func mapsRequestsToValuesInOrder() async throws {
    let day = try date("2025-06-15")
    let bundle = try makeService(
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5"), "EUR": dec("0.9")]]
    )
    let requests = [
      request(dec("100"), from: usd, to: aud, on: day),
      request(dec("100"), from: usd, to: eur, on: day),
      request(dec("50"), from: usd, to: aud, on: day),
    ]

    let outcomes = try await bundle.service.convertResultBatch(requests)

    #expect(outcomes.count == 3)
    #expect(try value(outcomes[0]).quantity == dec("150"))
    #expect(try value(outcomes[1]).quantity == dec("90"))
    #expect(try value(outcomes[2]).quantity == dec("75"))
  }

  /// A same-instrument request returns the input amount and does not
  /// populate the cache.
  @Test
  func sameInstrumentRequestIsValueWithNoCacheEntry() async throws {
    let day = try date("2025-06-15")
    let bundle = try makeService()
    let outcomes = try await bundle.service.convertResultBatch([
      request(dec("42"), from: usd, to: usd, on: day)
    ])

    #expect(try value(outcomes[0]) == InstrumentAmount(quantity: dec("42"), instrument: usd))
    #expect(await bundle.service.cachedRateCountForTesting == 0)
  }

  // MARK: - Distinct-key dedup

  /// Many requests sharing the same `(from, to, day)` key resolve to a
  /// single cache entry — the win the batch override exists to deliver.
  @Test
  func distinctKeysDedupToOneCacheEntry() async throws {
    let day = try date("2025-06-15")
    let bundle = try makeService(
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5")]]
    )
    let requests = (0..<20).map { i in
      request(Decimal(i + 1), from: usd, to: aud, on: day)
    }

    let outcomes = try await bundle.service.convertResultBatch(requests)

    #expect(outcomes.count == 20)
    #expect(try value(outcomes[0]).quantity == dec("1.5"))
    #expect(try value(outcomes[19]).quantity == dec("30"))
    // One distinct (USD, AUD, 2025-06-15) key despite 20 requests.
    #expect(await bundle.service.cachedRateCountForTesting == 1)
  }

  /// Distinct `(from, to, day)` keys each populate exactly one entry; the
  /// same key repeated does not multiply entries.
  @Test
  func mixedKeysPopulateOneEntryPerDistinctKey() async throws {
    let day1 = try date("2025-06-15")
    let day2 = try date("2025-06-16")
    let bundle = try makeService(
      exchangeRates: [
        "2025-06-15": ["AUD": dec("1.5"), "EUR": dec("0.9")],
        "2025-06-16": ["AUD": dec("1.6")],
      ]
    )
    let requests = [
      request(dec("1"), from: usd, to: aud, on: day1),  // key A
      request(dec("1"), from: usd, to: eur, on: day1),  // key B
      request(dec("1"), from: usd, to: aud, on: day2),  // key C
      request(dec("1"), from: usd, to: aud, on: day1),  // key A again
    ]

    _ = try await bundle.service.convertResultBatch(requests)

    #expect(await bundle.service.cachedRateCountForTesting == 3)
  }

  // MARK: - Mixed outcomes

  /// `.knownZero` (unpriced crypto) and `.value` (fiat) coexist in one
  /// batch, each in the right slot.
  @Test
  func mixesKnownZeroAndValue() async throws {
    let day = try date("2025-06-15")
    let unpriced = CryptoRegistration(
      instrument: eth,
      mapping: CryptoProviderMapping(
        instrumentId: "1:native", coingeckoId: "ethereum",
        cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
      ),
      pricingStatus: .unpriced
    )
    let bundle = try makeService(
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5")]],
      registrations: [unpriced]
    )
    let requests = [
      request(dec("100"), from: usd, to: aud, on: day),
      request(dec("3"), from: eth, to: aud, on: day),
    ]

    let outcomes = try await bundle.service.convertResultBatch(requests)

    #expect(try value(outcomes[0]).quantity == dec("150"))
    guard case .knownZero(let target) = outcomes[1] else {
      Issue.record("expected .knownZero, got \(outcomes[1])")
      return
    }
    #expect(target == aud)
  }

  /// A request whose key cannot be resolved (no rate available) surfaces
  /// as `.failure` for that element only — the rest of the batch resolves.
  @Test
  func unresolvableKeyIsPerElementFailure() async throws {
    let day = try date("2025-06-15")
    // AUD has a rate; EUR does not — the EUR request fails, AUD succeeds.
    let bundle = try makeService(
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5")]]
    )
    let requests = [
      request(dec("100"), from: usd, to: aud, on: day),
      request(dec("100"), from: usd, to: eur, on: day),
    ]

    let outcomes = try await bundle.service.convertResultBatch(requests)

    #expect(try value(outcomes[0]).quantity == dec("150"))
    guard case .failure = outcomes[1] else {
      Issue.record("expected .failure, got \(outcomes[1])")
      return
    }
  }

  /// One unresolvable key shared by several requests fails every request
  /// that uses it, while a sibling resolvable key still succeeds.
  @Test
  func failingKeyFailsAllItsRequests() async throws {
    let day = try date("2025-06-15")
    let bundle = try makeService(
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5")]]
    )
    let requests = [
      request(dec("1"), from: usd, to: eur, on: day),  // fails
      request(dec("1"), from: usd, to: aud, on: day),  // ok
      request(dec("2"), from: usd, to: eur, on: day),  // fails (same key)
    ]

    let outcomes = try await bundle.service.convertResultBatch(requests)

    guard case .failure = outcomes[0] else {
      Issue.record("expected .failure, got \(outcomes[0])")
      return
    }
    #expect(try value(outcomes[1]).quantity == dec("1.5"))
    guard case .failure = outcomes[2] else {
      Issue.record("expected .failure, got \(outcomes[2])")
      return
    }
  }

  // MARK: - Cancellation

  /// A cancelled batch rethrows `CancellationError` rather than returning
  /// outcomes.
  @Test
  func rethrowsCancellation() async throws {
    let day = try date("2025-06-15")
    let bundle = try makeService(
      exchangeRates: ["2025-06-15": ["AUD": dec("1.5")]]
    )
    let requests = (0..<32).map { i in
      request(Decimal(i + 1), from: usd, to: aud, on: day)
    }

    let task = Task {
      try await bundle.service.convertResultBatch(requests)
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
  }

  // MARK: - Bounded concurrency / large request set

  /// Correctness over a large set of distinct keys. The bounded (≤16
  /// in-flight) task group must still resolve every distinct key exactly
  /// once and map every request correctly.
  ///
  /// Note: a *direct* max-in-flight assertion is impractical here — every
  /// distinct key resolves through `computeUnitFactor`, which awaits the
  /// downstream `ExchangeRateService` / `CryptoPriceService`, both of
  /// which are actors that serialise their own client calls. There is no
  /// observable point downstream of the bounded group where 16 fetches
  /// could be seen overlapping. This test therefore pins correctness over
  /// a >16-key set (the group's correctness invariant) rather than the
  /// in-flight bound itself, which is enforced structurally by the
  /// `withThrowingTaskGroup` window in the implementation.
  @Test
  func resolvesLargeDistinctKeySetCorrectly() async throws {
    // 40 distinct days, each with its own USD→AUD rate. Walk forward from
    // a base date so every key is a valid calendar day (avoids spilling
    // past a month's length).
    var utcCalendar = Calendar(identifier: .gregorian)
    utcCalendar.timeZone = try #require(TimeZone(identifier: "UTC"))
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let base = try date("2025-01-01")
    var rates: [String: [String: Decimal]] = [:]
    var requests: [BatchConversionRequest] = []
    var expected: [Decimal] = []
    for day in 1...40 {
      let onDate = try #require(utcCalendar.date(byAdding: .day, value: day, to: base))
      let key = formatter.string(from: onDate)
      let rate = Decimal(day) / Decimal(10)  // 0.1 … 4.0
      rates[key] = ["AUD": rate]
      requests.append(request(dec("10"), from: usd, to: aud, on: onDate))
      expected.append(dec("10") * rate)
    }
    let bundle = try makeService(exchangeRates: rates)

    let outcomes = try await bundle.service.convertResultBatch(requests)

    #expect(outcomes.count == 40)
    for (index, outcome) in outcomes.enumerated() {
      #expect(try value(outcome).quantity == expected[index])
    }
    #expect(await bundle.service.cachedRateCountForTesting == 40)
  }

  // MARK: - Helpers

  private func value(_ outcome: BatchConversionOutcome) throws -> InstrumentAmount {
    guard case .value(let amount) = outcome else {
      throw BatchTestError.notValue
    }
    return amount
  }

  private enum BatchTestError: Error { case notValue }
}
