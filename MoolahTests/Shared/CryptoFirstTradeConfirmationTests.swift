import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies that `CryptoPriceService` records first-trade floors only from
/// explicit provider metadata. Empty historical windows are not proof that a
/// token did not trade yet.
@Suite("CryptoPriceService — first-trade confirmation")
struct CryptoFirstTradeConfirmationTests {
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
    clients: [any CryptoPriceClient],
    database: DatabaseQueue,
    firstTradeFloorLookup: @Sendable @escaping (String) async -> String? = { _ in nil },
    now: @Sendable @escaping () -> Date
  ) throws -> CryptoPriceService {
    let utc = try #require(TimeZone(identifier: "UTC"))
    return CryptoPriceService(
      clients: clients,
      database: database,
      resolutionClient: nil,
      firstTradeFloorLookup: firstTradeFloorLookup,
      now: now,
      timeZone: utc)
  }

  @Test("backward no-progress does not infer firstTradedOn")
  func emptyBackwardWalkLeavesFirstTradeUnconfirmed() async throws {
    // Floor date: providers have prices from 2020-01-10 onward.
    let floorDate = "2020-01-10"
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try date("2026-01-01")

    // Provider has prices only from floor onward — requests for dates before
    // floor return empty (FixedCryptoPriceClient range-filters to its stored
    // price dict, returning an empty dict for windows that predate floor).
    let client = FixedCryptoPriceClient(prices: [
      "1:native": [
        "2020-01-10": dec("200.00"),
        "2020-01-11": dec("201.00"),
        "2020-01-12": dec("202.00"),
      ]
    ])
    let service = try makeService(clients: [client], database: database, now: { frozen })

    // Seed the cache at the floor date, then request a date well before it.
    // The first call populates earliestDate = 2020-01-10 (or nearby).
    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date(floorDate))

    // Requesting a date before the floor triggers the backward extension loop.
    // The provider returns empty for all pre-floor windows. That can mean a
    // provider horizon, not pre-listing, so it must not set firstTradedOn.
    _ = try? await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2019-12-01"))

    let firstTradedOn = await service.caches["1:native"]?.firstTradedOn
    #expect(firstTradedOn == nil)
  }

  @Test("explicit provider floor drives beforeFirstTrade and persists with price rows")
  func explicitProviderFloorPersistsWithPrices() async throws {
    let floorDate = "2020-01-10"
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try date("2026-01-01")
    let client = FixedCryptoPriceClient(prices: [
      "1:native": [
        "2020-01-10": dec("200.00"),
        "2020-01-11": dec("201.00"),
      ]
    ])
    let service = try makeService(
      clients: [client],
      database: database,
      firstTradeFloorLookup: { tokenId in tokenId == "1:native" ? floorDate : nil },
      now: { frozen })

    await #expect(
      throws: CryptoPriceError.beforeFirstTrade(tokenId: "1:native", date: "2019-12-01")
    ) {
      _ = try await service.price(
        for: ethInstrument, mapping: ethMapping, on: try date("2019-12-01"))
    }

    _ = try await service.price(for: ethInstrument, mapping: ethMapping, on: try date(floorDate))

    let firstTradedOn = await service.caches["1:native"]?.firstTradedOn
    #expect(firstTradedOn == floorDate)
    let stored = try await database.read { database in
      try CryptoTokenMetaRecord
        .filter(CryptoTokenMetaRecord.Columns.tokenId == "1:native")
        .fetchOne(database)
    }
    #expect(stored?.firstTradedOn == floorDate)
  }

  @Test("purge invalidates an explicit provider floor")
  func purgeInvalidatesExplicitProviderFloor() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try date("2026-01-01")
    let service = try makeService(
      clients: [FixedCryptoPriceClient()],
      database: database,
      firstTradeFloorLookup: { _ in "2020-01-10" },
      now: { frozen })

    await service.applyExplicitFirstTradeFloorIfAvailable(tokenId: ethInstrument.id)
    #expect(await service.explicitFirstTradeFloors[ethInstrument.id] == "2020-01-10")

    await service.purgeCache(instrumentId: ethInstrument.id)

    #expect(await service.explicitFirstTradeFloors[ethInstrument.id] == nil)
  }

  @Test("purge invalidates a suspended provider-floor lookup")
  func purgeInvalidatesSuspendedProviderFloorLookup() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try date("2026-01-01")
    let lookup = SuspendedFirstTradeFloorLookup()
    let service = try makeService(
      clients: [FixedCryptoPriceClient()],
      database: database,
      firstTradeFloorLookup: { _ in await lookup.value() },
      now: { frozen })

    let applyTask = Task {
      await service.applyExplicitFirstTradeFloorIfAvailable(tokenId: ethInstrument.id)
    }
    await lookup.waitUntilStarted()
    await service.purgeCache(instrumentId: ethInstrument.id)
    await lookup.resume(returning: "2020-01-10")
    await applyTask.value

    #expect(await service.explicitFirstTradeFloors[ethInstrument.id] == nil)
  }

  /// When a provider throws a transient (rate-limit) error during the backward
  /// walk, the loop terminates on an operational failure, not on no-progress.
  /// `firstTradedOn` must remain nil in that case.
  @Test("a transient failure during the backward walk does NOT set firstTradedOn")
  func transientLeavesUnconfirmed() async throws {
    // Floor date: the primary provider has prices from here onward.
    let floorDate = "2020-01-10"
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try date("2026-01-01")

    // Primary client: has data from floor onward.
    let dataClient = FixedCryptoPriceClient(prices: [
      "1:native": [
        "2020-01-10": dec("200.00"),
        "2020-01-11": dec("201.00"),
      ]
    ])
    // Failing client: throws a rate-limit error on every request.
    let rateLimitError = WalletSyncError(provider: .coinGecko, kind: .rateLimited(retryAfter: nil))
    let failingClient = FixedCryptoPriceClient(
      shouldFail: true,
      failureError: rateLimitError,
      syncProvider: .binance)

    // Put the failing client first: it throws on every request regardless of
    // date, so the backward-walk window is guaranteed to hit an operational
    // error before the data client is ever consulted. This is unambiguous —
    // the test does not rely on a specific client ordering to surface the error.
    let service = try makeService(
      clients: [failingClient, dataClient],
      database: database,
      now: { frozen })

    // Seed the cache at the floor date.
    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date(floorDate))

    // Request a pre-floor date. The data client returns empty for pre-floor
    // windows; the failing client throws rateLimited. fetchRange sees an
    // operational error → throws → loop captures lastFetchError → firstTradedOn
    // must NOT be set.
    _ = try? await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2019-12-01"))

    let firstTradedOn = await service.caches["1:native"]?.firstTradedOn
    #expect(
      firstTradedOn == nil,
      "firstTradedOn must remain nil when walk terminates on operational error")
  }
}

private actor SuspendedFirstTradeFloorLookup {
  private var valueContinuation: CheckedContinuation<String?, Never>?
  private var startContinuations: [CheckedContinuation<Void, Never>] = []

  func value() async -> String? {
    await withCheckedContinuation { continuation in
      valueContinuation = continuation
      for startContinuation in startContinuations {
        startContinuation.resume()
      }
      startContinuations.removeAll()
    }
  }

  func waitUntilStarted() async {
    guard valueContinuation == nil else { return }
    await withCheckedContinuation { continuation in
      startContinuations.append(continuation)
    }
  }

  func resume(returning value: String?) {
    valueContinuation?.resume(returning: value)
    valueContinuation = nil
  }
}
