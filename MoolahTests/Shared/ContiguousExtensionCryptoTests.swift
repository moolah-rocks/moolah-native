import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite
struct ContiguousExtensionCryptoTests {
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
      binanceSymbol: binanceSymbol
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

  // MARK: - Background warmer contiguity

  /// `warmRange` with a horizon-restricted client must not create an interior
  /// gap. Old logic precomputes ALL uncovered sub-ranges upfront; a later
  /// chunk that falls outside the provider's 365-day horizon returns empty,
  /// so `mergeReturningDelta` is never called for it and `earliest`/`latest`
  /// never advance past it — but a chunk that IS served advances `latest` to
  /// the served span, leaving a void between the cold cache tail and the
  /// newly served segment.
  ///
  /// Concretely: cold cache, `warmRange(in: farBack...today)`. Old logic
  /// chunks the whole range upfront. The last chunk (near today) is served by
  /// the horizon client; earlier chunks return empty and do not move bounds.
  /// `latest` jumps from nil to today; `earliest` stays at the served start.
  /// Subsequent calls see `subRanges.isEmpty` for a range inside the served
  /// segment, so the void is never filled.
  ///
  /// New logic (contiguous loop): each window anchors at the live cache
  /// bounds; the first empty result in either direction stops that direction.
  /// `earliest`/`latest` can only advance across days that were actually
  /// served — the void can never form.
  @Test
  func warmRangeLeavesNoInteriorGap() async throws {
    let today = utcDay("2026-06-17")
    let database = try ProfileIndexDatabase.openInMemory()
    let instrument = makeTestInstrument(address: "0xwarm", symbol: "WARM")
    let mapping = makeMapping(for: instrument, binanceSymbol: "WARMUSDT")

    // Cold cache. `warmRange` across 2+ years with a provider that only serves
    // the last 365 days. Old `uncoveredSubRanges` loop: chunks the entire span
    // upfront; a recent chunk fills latest=today; earlier chunks return empty
    // and never move earliest — interior gap = ~1 year. Bounded-window loop:
    // forward direction stops as soon as a window returns nothing, so the
    // cache only spans the actually-served segment.
    let service = makeService(
      clients: [HorizonClient(today: today, horizonDays: 365)],
      database: database,
      now: today
    )
    let farBack = utcDay("2024-01-01")
    let outcome = await service.warmRange(
      for: instrument, mapping: mapping, in: farBack...today)
    // The outcome must reflect that some data was fetched (the recent segment).
    #expect(outcome == .filled || outcome == .unavailable)

    let maxGap = await service.debugMaxInteriorGapDays(tokenId: instrument.id)
    // Bounded windows: no interior gap larger than one window (≤ 30 days).
    // The old uncoveredSubRanges path produces a gap > 300 days here.
    #expect(maxGap <= 31)
  }

  // MARK: - Range contiguity

  /// A `prices(in:)` range request using a horizon-restricted client must not
  /// create an interior hole. Old logic: `prices(in:)` issued unbounded
  /// forward/backward fetches; a horizon client returning only recent data
  /// would jump `latest` (or `earliest`) over un-served days, leaving a void.
  /// New logic: both forward and backward extensions go through
  /// `coverRangeContiguously`, which uses bounded 30-day windows.
  ///
  /// Trigger sequence (forward extension variant, mirrors `farBackRequestLeavesNoInteriorGap`):
  ///   1. Seed far-back data so cache has latest ≈ 2024-07-12.
  ///   2. Request `rangeStart...today` with a horizon client (only serves ≥ 2025-06-17).
  ///      Old logic: `prices(in:)` computes forward sub-range [latest...fetchUpperBound]
  ///      in one unbounded call. Provider returns 2025-06-17…today; merge jumps
  ///      `latest` to today leaving an ~11-month void.
  ///      New logic: `coverRangeContiguously` advances bounds one 30-day window
  ///      at a time, so bounds only advance across actually-returned data.
  @Test
  func rangeRequestLeavesNoInteriorGap() async throws {
    let today = utcDay("2026-06-17")
    let database = try ProfileIndexDatabase.openInMemory()
    let instrument = makeTestInstrument(address: "0xrange", symbol: "RNG")
    let mapping = makeMapping(for: instrument, binanceSymbol: "RNGUSDT")

    // Step 1: Seed a far-back date so the cache has latest ≈ 2024-07-12.
    let seeder = makeService(clients: [AllServingClient()], database: database, now: today)
    _ = try? await seeder.price(for: instrument, mapping: mapping, on: utcDay("2024-07-12"))

    // Step 2: Request rangeStart...today using a horizon-restricted client.
    // Old logic emits an unbounded forward fetch [2024-07-12…today]; the
    // horizon client returns data from 2025-06-17 onward; merge jumps
    // `latest` to today leaving an ~11-month void inside the range.
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
