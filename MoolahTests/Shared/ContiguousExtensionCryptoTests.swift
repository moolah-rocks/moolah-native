import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite
struct ContiguousExtensionCryptoTests {
  /// Parses a `YYYY-MM-DD` string to a midnight-UTC `Date`. Shared by all
  /// tests in this suite to keep date construction readable.
  private func utcDay(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = .utc
    guard let date = formatter.date(from: string) else {
      fatalError("Could not parse ISO date: \(string)")
    }
    return date
  }

  /// Serves a daily price for every day in the requested range that is
  /// within `horizonDays` of `today`; older days return empty (mimics
  /// CoinGecko free tier's 365-day refusal collapsing to empty).
  struct HorizonClient: CryptoPriceClient, Sendable {
    let today: Date
    let horizonDays: Int

    var syncProvider: SyncProvider { .binance }

    func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal { 1 }
    func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
      [:]
    }

    func dailyPrices(
      for mapping: CryptoProviderMapping,
      in range: ClosedRange<Date>
    ) async throws -> [String: Decimal] {
      let cal = Calendar.utc
      guard let cutoff = cal.date(byAdding: .day, value: -horizonDays, to: today) else {
        return [:]
      }
      let fmt = ISO8601DateFormatter()
      fmt.formatOptions = [.withFullDate]
      fmt.timeZone = .utc
      var out: [String: Decimal] = [:]
      var day = range.lowerBound
      while day <= range.upperBound {
        if day >= cutoff { out[fmt.string(from: day)] = 100 }
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
      }
      return out
    }
  }

  /// Serves any date without restriction — used to seed the cache with
  /// deep history before switching to a horizon-restricted client.
  struct AllServingClient: CryptoPriceClient, Sendable {
    var syncProvider: SyncProvider { .binance }

    func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal { 1 }
    func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
      [:]
    }

    func dailyPrices(
      for mapping: CryptoProviderMapping,
      in range: ClosedRange<Date>
    ) async throws -> [String: Decimal] {
      let cal = Calendar.utc
      let fmt = ISO8601DateFormatter()
      fmt.formatOptions = [.withFullDate]
      fmt.timeZone = .utc
      var out: [String: Decimal] = [:]
      var day = range.lowerBound
      while day <= range.upperBound {
        out[fmt.string(from: day)] = 100
        guard let next = cal.date(byAdding: .day, value: 1, to: day) else { break }
        day = next
      }
      return out
    }
  }

  private func makeTestInstrument(address: String, symbol: String) -> Instrument {
    Instrument.crypto(
      chainId: 1, contractAddress: address, symbol: symbol, name: "\(symbol) Token", decimals: 8)
  }

  private func makeMapping(for instrument: Instrument, binanceSymbol: String)
    -> CryptoProviderMapping
  {
    CryptoProviderMapping(
      instrumentId: instrument.id, coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: binanceSymbol
    )
  }

  private func makeService(
    clients: [any CryptoPriceClient],
    database: any DatabaseWriter,
    now: Date
  ) -> CryptoPriceService {
    CryptoPriceService(
      clients: clients,
      database: database,
      resolutionClient: nil,
      now: { now },
      timeZone: .utc
    )
  }

  // MARK: - Contiguity tests

  /// Reproduces the interior-gap bug: a CoinGecko-like client that refuses
  /// data older than 365 days causes the cache to jump its `latest` bound
  /// forward over the un-served span, creating a permanent multi-month void.
  ///
  /// Trigger sequence:
  ///   1. Seed the cache with a far-back date using an all-serving client
  ///      (gives cache earliest≈2024-06-12, latest≈2024-07-12).
  ///   2. Request today using a horizon client (only serves ≤365 days back).
  ///      Old logic: forward extension = unbounded [latest…today].
  ///      Provider serves 2025-06-17…today. mergeReturningDelta sets
  ///      latest=today while earliest stays at 2024-07-12. Gap = ~11 months.
  ///      New logic: extension bounded to 30-day windows; no jump.
  @Test
  func farBackRequestLeavesNoInteriorGap() async throws {
    let today = utcDay("2026-06-17")
    let database = try ProfileIndexDatabase.openInMemory()
    let instrument = makeTestInstrument(address: "0xtest", symbol: "TEST")
    let mapping = makeMapping(for: instrument, binanceSymbol: "TESTUSDT")

    // Step 1: Seed with an all-serving client so we get real far-back data.
    // This populates earliest≈2024-06-12, latest≈2024-07-12 in the DB.
    let seeder = makeService(clients: [AllServingClient()], database: database, now: today)
    _ = try? await seeder.price(for: instrument, mapping: mapping, on: utcDay("2024-07-12"))

    // Step 2: Fresh service with only the horizon-restricted client.
    // Now request today. Old logic issues unbounded forward extension from
    // 2024-07-12 to today; horizon client only serves 2025-06-17+; merge
    // jumps latest to today leaving a ~11-month interior void.
    let service = makeService(
      clients: [HorizonClient(today: today, horizonDays: 365)],
      database: database,
      now: today
    )
    _ = try? await service.price(for: instrument, mapping: mapping, on: today)

    // The cache bounds must not span an un-fetched interior region larger than
    // one bounded window. With the old unbounded logic, the forward extension
    // would jump `latest` from 2024-07-12 all the way to today, leaving
    // an ~11-month void. The bounded loop keeps each step ≤ 30 days.
    let maxGap = await service.debugMaxInteriorGapDays(tokenId: instrument.id)
    #expect(maxGap <= 31)  // bounded window; never a multi-month void
  }

  // MARK: - Range contiguity

  /// A `prices(in:)` range request using a horizon-restricted client must not
  /// create an interior hole. The fix chunks the backward `uncoveredSubRanges`
  /// entry into bounded 30-day windows so the bounds never span un-fetched days.
  @Test
  func rangeRequestLeavesNoInteriorGap() async throws {
    let today = utcDay("2026-06-17")
    let database = try ProfileIndexDatabase.openInMemory()
    let instrument = makeTestInstrument(address: "0xrange", symbol: "RNG")
    let mapping = makeMapping(for: instrument, binanceSymbol: "RNGUSDT")

    // Seed recent block so the cache has latest ≈ today.
    let seeder = makeService(clients: [AllServingClient()], database: database, now: today)
    _ = try? await seeder.price(for: instrument, mapping: mapping, on: today)

    // Now request a range spanning far back using the horizon-restricted client.
    // Old logic: prices(in:) issues one unbounded backward fetch [rangeStart...earliest-1];
    // HorizonClient returns only ≥ 2025-06-17, leaving a void before that.
    // New logic: backward extension is split into ≤30-day windows, so no interior gap forms.
    let service = makeService(
      clients: [HorizonClient(today: today, horizonDays: 365)],
      database: database,
      now: today
    )
    let rangeStart = utcDay("2024-01-01")
    _ = try? await service.prices(for: instrument, mapping: mapping, in: rangeStart...today)
    let maxGap = await service.debugMaxInteriorGapDays(tokenId: instrument.id)
    #expect(maxGap <= 31)  // bounded windows; never a multi-month void
  }
}
