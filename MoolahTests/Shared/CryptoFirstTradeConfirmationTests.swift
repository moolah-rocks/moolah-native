import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies that `CryptoPriceService` sets `firstTradedOn` on the in-memory
/// cache after a backward window walk terminates on no-progress with no
/// operational error, and that a transient (rate-limit) error during the walk
/// leaves `firstTradedOn` unchanged.
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
    now: @Sendable @escaping () -> Date
  ) throws -> CryptoPriceService {
    let utc = try #require(TimeZone(identifier: "UTC"))
    return CryptoPriceService(
      clients: clients,
      database: database,
      resolutionClient: nil,
      now: now,
      timeZone: utc)
  }

  /// Providers serve prices only for dates >= floor F. When a date before F
  /// is requested the backward extension walk finds no new data (empty return,
  /// no error) and terminates on no-progress. At that point `firstTradedOn`
  /// must be set to the earliest date that any provider actually served (the
  /// cache's `earliestDate`).
  @Test("backward walk that exhausts all providers sets firstTradedOn to the earliest served date")
  func confirmsFirstTrade() async throws {
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
    // The provider returns empty for all pre-floor windows → no-progress → sets firstTradedOn.
    _ = try? await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2019-12-01"))

    let firstTradedOn = await service.caches["1:native"]?.firstTradedOn
    let earliestDate = await service.caches["1:native"]?.earliestDate
    #expect(firstTradedOn != nil, "firstTradedOn should be set after exhausting backward walk")
    #expect(firstTradedOn == earliestDate, "firstTradedOn should equal the cache's earliestDate")
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
