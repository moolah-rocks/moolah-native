import Foundation
import Testing

@testable import Moolah

/// Minimal cache satisfying `PriceSeriesCache` for the fake actor.
private struct FakeCache: PriceSeriesCache {
  var earliestDate: String
  var latestDate: String
  var prices: SortedDateSeries<Decimal>
  var firstTradedOn: String?
}

/// A minimal actor that conforms to `PriceSeriesOrchestrating` to drive the
/// shared default methods in isolation. The fetcher plug mutates
/// `self.caches[key]` per key (never a snapshot), optionally suspending on an
/// injected gate so the concurrent-two-instrument race can be probed.
private actor FakeService: PriceSeriesOrchestrating {
  typealias Cache = FakeCache

  var caches: [String: FakeCache] = [:]
  var hydrated: Set<String> = []
  let now: @Sendable () -> Date
  let timeZone: TimeZone
  let dateFormatter: ISO8601DateFormatter
  let plannerConfig = ContiguousFetchPlanner.Config(windowDays: 30, forwardBuffer: 2)

  /// Per-key wire data the fetcher serves; `fetchAndMerge` merges the slice of
  /// these dates that fall inside the requested window into `caches[key]`.
  private var wire: [String: [String: Decimal]]
  private var floors: [String: String]
  private(set) var fetchCount = 0
  private(set) var hydrateCount: [String: Int] = [:]
  /// When `gated`, each `fetchAndMerge` parks on its OWN per-key continuation
  /// (no shared single-consumer stream) so two different-key calls can be
  /// suspended concurrently and released together without competing iterators.
  private let gated: Bool
  private var parkedGates: [String: CheckedContinuation<Void, Never>] = [:]

  init(
    wire: [String: [String: Decimal]] = [:],
    floors: [String: String] = [:],
    now: @Sendable @escaping () -> Date,
    gated: Bool = false
  ) {
    self.wire = wire
    self.floors = floors
    self.now = now
    self.timeZone = TimeZone(identifier: "UTC") ?? .gmt
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    self.dateFormatter = formatter
    self.gated = gated
  }

  /// Number of `fetchAndMerge` calls currently parked on their gate.
  var parkedGateCount: Int { parkedGates.count }

  /// Resume every parked gate, releasing all suspended fetches together.
  func releaseGates() {
    let continuations = parkedGates.values
    parkedGates.removeAll()
    for continuation in continuations { continuation.resume() }
  }

  // Plug 1
  func fetchAndMerge(instrumentKey: String, window: ClosedRange<Date>) async throws {
    fetchCount += 1
    if gated {
      await withCheckedContinuation { continuation in
        parkedGates[instrumentKey] = continuation  // park on this key's own gate
      }
    }
    guard let rows = wire[instrumentKey] else { return }
    let lower = dateFormatter.string(from: window.lowerBound)
    let upper = dateFormatter.string(from: window.upperBound)
    let slice = rows.filter { $0.key >= lower && $0.key <= upper }
    guard !slice.isEmpty else { return }
    var cache =
      caches[instrumentKey]
      ?? FakeCache(
        earliestDate: upper, latestDate: lower, prices: SortedDateSeries(), firstTradedOn: nil)
    for (day, price) in slice {
      guard let key = DateKey.from(isoString: day) else { continue }
      cache.prices.upsert(price, forKey: key)
    }
    let keys = slice.keys.sorted()
    if let first = keys.first, let last = keys.last, cache.prices.isEmpty == false {
      cache.earliestDate = min(cache.earliestDate.isEmpty ? first : cache.earliestDate, first)
      cache.latestDate = max(cache.latestDate.isEmpty ? last : cache.latestDate, last)
    }
    caches[instrumentKey] = cache  // per-key write, no snapshot
  }

  // Plug 2
  func firstTradeFloor(for instrumentKey: String) -> String? {
    caches[instrumentKey]?.firstTradedOn ?? floors[instrumentKey]
  }
  func confirmFirstTradeOnBackwardExhaustion(instrumentKey: String, lastFetchError: (any Error)?)
    async throws
  {
    guard lastFetchError == nil, var cache = caches[instrumentKey],
      cache.firstTradedOn == nil, !cache.earliestDate.isEmpty
    else { return }
    cache.firstTradedOn = cache.earliestDate
    caches[instrumentKey] = cache
  }

  // Hydration plug
  func hydrate(instrumentKey: String) async throws {
    hydrateCount[instrumentKey, default: 0] += 1
    hydrated.insert(instrumentKey)
  }

  // Error factories
  func belowFloorError(instrumentKey: String, date: String) -> any Error {
    CryptoPriceError.beforeFirstTrade(tokenId: instrumentKey, date: date)
  }
  func noPriceError(instrumentKey: String, date: String) -> any Error {
    CryptoPriceError.noPriceAvailable(tokenId: instrumentKey, date: date)
  }
}

/// Builds a noon-UTC `Date` for an ISO `YYYY-MM-DD` literal without an
/// optional unwrap (the test literals are always well-formed). Shared by the
/// suite helpers and the `fixedNow` clock.
private func utcDay(_ iso: String) -> Date {
  let parts = iso.split(separator: "-").compactMap { Int($0) }
  var components = DateComponents()
  if parts.count == 3 {
    components.year = parts[0]
    components.month = parts[1]
    components.day = parts[2]
  }
  components.hour = 12
  return Calendar.utc.date(from: components) ?? Date(timeIntervalSince1970: 0)
}

@Suite("PriceSeriesOrchestrating")
struct PriceSeriesOrchestratingTests {
  private func day(_ iso: String) -> Date { utcDay(iso) }
  /// Fixed "now" so the cap lands on a stable yesterday (2026-04-30).
  private let fixedNow: @Sendable () -> Date = { utcDay("2026-05-01") }

  @Test
  func fetchesAndReturnsExactPrice() async throws {
    let service = FakeService(
      wire: ["AAA": ["2026-04-20": Decimal(10), "2026-04-21": Decimal(11)]], now: fixedNow)
    let price = try await service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    #expect(price == Decimal(11))
  }

  @Test
  func capsRequestAtYesterday() async throws {
    // now = 2026-05-01 → yesterday = 2026-04-30; wire only has 04-30.
    let service = FakeService(wire: ["AAA": ["2026-04-30": Decimal(7)]], now: fixedNow)
    // Requesting "today" (2026-05-01) must resolve to yesterday's close.
    let price = try await service.price(instrumentKey: "AAA", on: day("2026-05-01"))
    #expect(price == Decimal(7))
  }

  @Test
  func hydratesExactlyOnce() async throws {
    let service = FakeService(wire: ["AAA": ["2026-04-21": Decimal(11)]], now: fixedNow)
    _ = try await service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    _ = try await service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    let counts = await service.hydrateCount
    #expect(counts["AAA"] == 1)
  }

  @Test
  func priorTradingDayFloorFallback() async throws {
    let service = FakeService(wire: ["AAA": ["2026-04-20": Decimal(10)]], now: fixedNow)
    // 04-21 has no row; floor lands on 04-20.
    let price = try await service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    #expect(price == Decimal(10))
  }

  @Test
  func noProgressBreakThrowsNoPrice() async throws {
    // Empty wire → fetch never advances bounds → loop breaks → noPriceError.
    let service = FakeService(wire: ["AAA": [:]], now: fixedNow)
    await #expect(throws: CryptoPriceError.self) {
      _ = try await service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    }
    let count = await service.fetchCount
    #expect(count < 250)  // bounded, not the guard limit
  }

  @Test
  func belowFloorShortCircuits() async throws {
    let service = FakeService(
      wire: ["AAA": ["2026-04-20": Decimal(10)]], floors: ["AAA": "2026-04-15"], now: fixedNow)
    await #expect(throws: CryptoPriceError.beforeFirstTrade(tokenId: "AAA", date: "2026-04-10")) {
      _ = try await service.price(instrumentKey: "AAA", on: day("2026-04-10"))
    }
  }

  @Test
  func backwardExhaustionConfirmsFloor() async throws {
    // wire starts at 04-20; a request for 04-10 walks backward, exhausts with
    // no error, and the confirm hook sets firstTradedOn = earliestDate (04-20).
    let service = FakeService(wire: ["AAA": ["2026-04-20": Decimal(10)]], now: fixedNow)
    _ = try? await service.price(instrumentKey: "AAA", on: day("2026-04-21"))  // seed 04-20
    _ = try? await service.price(instrumentKey: "AAA", on: day("2026-04-10"))  // backward walk
    let floor = await service.firstTradeFloor(for: "AAA")
    #expect(floor == "2026-04-20")
  }

  @Test
  func carryForwardSeriesUTC() async throws {
    // 04-20 present, 04-21/04-22 absent → carried forward over a UTC day walk.
    let service = FakeService(wire: ["AAA": ["2026-04-20": Decimal(10)]], now: fixedNow)
    let series = try await service.prices(
      instrumentKey: "AAA", in: day("2026-04-20")...day("2026-04-22"))
    #expect(series.map(\.price) == [Decimal(10), Decimal(10), Decimal(10)])
    #expect(series.map { self.dayString($0.date) } == ["2026-04-20", "2026-04-21", "2026-04-22"])
  }

  @Test
  func emitsNothingBeforeFirstKnownClose() async throws {
    // Range starts two days BEFORE the only wire close (04-20). The leading
    // days (04-18, 04-19) precede any known close, so the carry-forward walk
    // must emit nothing for them; 04-20 then appears and carries to 04-21.
    let service = FakeService(wire: ["AAA": ["2026-04-20": Decimal(10)]], now: fixedNow)
    let series = try await service.prices(
      instrumentKey: "AAA", in: day("2026-04-18")...day("2026-04-21"))
    #expect(series.map { self.dayString($0.date) } == ["2026-04-20", "2026-04-21"])
    #expect(series.map(\.price) == [Decimal(10), Decimal(10)])
  }

  private func dayString(_ date: Date) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = .utc
    return formatter.string(from: date)
  }

  /// A spread of zones either side of UTC: one strongly negative (the bug case
  /// — a UTC instant read in a UTC-negative zone drifts into the prior day),
  /// UTC itself, and two strongly positive. See `guides/DATE_TIME_GUIDE.md` §6.
  private static let zones: [String] = [
    "America/Los_Angeles",  // UTC-8 / -7
    "UTC",
    "Australia/Brisbane",  // UTC+10, no DST
    "Pacific/Kiritimati",  // UTC+14, the extreme positive case
  ]

  @Test("prices() day tokens are zone-invariant under the canonical seam")
  func resultSeriesDayTokensAreZoneInvariant() async throws {
    // `prices(...)` is a NEW timezoneless producer: it emits `(date, price)`
    // day tokens for a chart axis. The day tokens are noon-UTC anchored and are
    // read back through the canonical `Calendar.utc` seam (as `buildResultSeries`
    // and every consumer does). Decoding them through that seam must yield the
    // SAME calendar day/month no matter what the process/runner zone is — this
    // is the invariant that protects a UTC-negative reader from the off-by-one
    // day drift the guide targets. (A bare noon-UTC *day* anchor rolls into the
    // next day only at UTC+14, hence the seam, not an arbitrary calendar, is the
    // contract for day-granularity tokens.)
    let service = FakeService(wire: ["AAA": ["2026-04-20": Decimal(10)]], now: fixedNow)
    let series = try await service.prices(
      instrumentKey: "AAA", in: day("2026-04-20")...day("2026-04-22"))
    let dates = series.map(\.date)
    #expect(dates.count == 3)

    let expected = ["2026-04-20", "2026-04-21", "2026-04-22"]
    // The canonical seam reads the token identically in every process zone.
    for (date, want) in zip(dates, expected) {
      let parts = Calendar.utc.dateComponents([.year, .month, .day], from: date)
      #expect(parts.year == 2026)
      #expect(parts.month == 4)
      #expect(
        String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
          == want)
    }

    // The guide's negative-drift bug class: a calendar in any of the spread of
    // zones from UTC-8 through UTC+10 must still read the same calendar day
    // (noon-UTC survives the full UTC-12..+12 span at day granularity).
    let dayInvariantZones = Self.zones.filter { $0 != "Pacific/Kiritimati" }
    for zone in dayInvariantZones {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = try #require(TimeZone(identifier: zone))
      for (date, want) in zip(dates, expected) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let got = String(
          format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
        #expect(got == want, "day drifted in \(zone)")
      }
    }
  }

  @Test
  func concurrentTwoInstrumentsNoCacheClobber() async throws {
    // The data-race regression test: two overlapping price(...) calls for
    // different keys, each suspending inside the gated fetcher, must each
    // commit their own cache entry — neither drops the other's.
    let service = FakeService(
      wire: ["AAA": ["2026-04-21": Decimal(11)], "BBB": ["2026-04-21": Decimal(22)]],
      now: fixedNow, gated: true)
    async let priceAAA = service.price(instrumentKey: "AAA", on: day("2026-04-21"))
    async let priceBBB = service.price(instrumentKey: "BBB", on: day("2026-04-21"))
    // Wait until BOTH fetches have parked on their own per-key gate, so both
    // are genuinely suspended inside fetchAndMerge at the same time, then
    // release them together.
    while await service.parkedGateCount < 2 { await Task.yield() }
    await service.releaseGates()
    let (resultAAA, resultBBB) = try await (priceAAA, priceBBB)
    #expect(resultAAA == Decimal(11))
    #expect(resultBBB == Decimal(22))
    let caches = await service.caches
    #expect(caches["AAA"] != nil)
    #expect(caches["BBB"] != nil)  // neither clobbered
  }
}
