import Foundation
import GRDB
import Testing
import os

@testable import Moolah

@Suite("CryptoPriceService.warmRange")
struct CryptoPriceServiceWarmRangeTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    binanceSymbol: "ETHUSDT"
  )

  private func makeService(
    clients: [CryptoPriceClient] = [],
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil,
    now: @Sendable @escaping () -> Date = { Date() }
  ) throws -> CryptoPriceService {
    let clientList =
      clients.isEmpty
      ? [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)]
      : clients
    let resolved = try database ?? ProfileIndexDatabase.openInMemory()
    return CryptoPriceService(
      clients: clientList,
      database: resolved,
      now: now
    )
  }

  private func date(_ string: String) -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    guard let result = formatter.date(from: string) else {
      fatalError("Could not parse ISO8601 full-date string: \(string)")
    }
    return result
  }

  @Test("cooldown is surfaced with its deadline")
  func cooldownSurfaced() async throws {
    let deadline = date("2026-06-07")
    let client = FixedCryptoPriceClient(
      prices: [:], shouldFail: true,
      failureError: RateLimitGateError.cooldown(until: deadline),
      syncProvider: .binance)
    let service = try makeService(clients: [client], now: { self.date("2026-06-01") })
    let from = date("2026-01-01")
    let to = date("2026-05-31")

    let outcome = await service.warmRange(
      for: ethInstrument, mapping: ethMapping, in: from...to)

    #expect(outcome == .cooledDown(until: deadline))
  }

  @Test("a fillable range returns .filled and populates the cache")
  func fillableReturnsFilled() async throws {
    let prices = ["1:native": ["2026-01-01": dec("100"), "2026-01-02": dec("110")]]
    let database = try ProfileIndexDatabase.openInMemory()
    let service = try makeService(
      prices: prices, database: database, now: { self.date("2026-02-01") })
    let from = date("2026-01-01")
    let to = date("2026-01-02")

    let outcome = await service.warmRange(for: ethInstrument, mapping: ethMapping, in: from...to)
    #expect(outcome == .filled)

    // A fresh reader over the same DB now serves the cached price with no fetch.
    let reader = try makeService(
      clients: [FixedCryptoPriceClient(prices: [:], shouldFail: true)],
      database: database, now: { self.date("2026-02-01") })
    let price = try await reader.price(for: ethInstrument, mapping: ethMapping, on: from)
    #expect(price == dec("100"))
  }

  @Test("an already-cached range is a no-op (no extra fetch)")
  func idempotentNoRefetch() async throws {
    let inner = FixedCryptoPriceClient(
      prices: ["1:native": ["2026-01-01": dec("100"), "2026-01-02": dec("110")]])
    let counting = CountingCryptoPriceClient(inner)
    let database = try ProfileIndexDatabase.openInMemory()
    let service = try makeService(
      clients: [counting], database: database, now: { self.date("2026-02-01") })
    let range = date("2026-01-01")...date("2026-01-02")

    _ = await service.warmRange(for: ethInstrument, mapping: ethMapping, in: range)
    let afterFirst = counting.fetchCount
    let outcome = await service.warmRange(for: ethInstrument, mapping: ethMapping, in: range)

    #expect(outcome == .filled)
    #expect(counting.fetchCount == afterFirst)  // second warm fetched nothing
  }

  @Test("no provider data and no cooldown returns .unavailable")
  func emptyReturnsUnavailable() async throws {
    let client = FixedCryptoPriceClient(prices: [:])  // returns empty dict, no throw
    let service = try makeService(clients: [client], now: { self.date("2026-02-01") })
    let outcome = await service.warmRange(
      for: ethInstrument, mapping: ethMapping,
      in: date("2026-01-01")...date("2026-01-02"))
    #expect(outcome == .unavailable)
  }

  /// A spread of host zones either side of UTC: one strongly negative (the
  /// case that drifts a midnight-UTC instant into the prior day), UTC
  /// itself, and two strongly positive. See `guides/DATE_TIME_GUIDE.md` §6.
  private static let zones: [String] = [
    "America/Los_Angeles",  // UTC-8 / -7
    "UTC",
    "Australia/Brisbane",  // UTC+10, no DST
    "Pacific/Kiritimati",  // UTC+14, the extreme positive case
  ]

  @Test("warmRange warms the same days regardless of the host time zone")
  func warmedDaysAreZoneInvariant() async throws {
    // `warmRange`'s uncovered-sub-range arithmetic is a timezoneless
    // producer (UTC day keys). Driven across a spread of host zones with a
    // fixed input range + pinned `now`, the days it fetches — observed via
    // the recorded request ranges — must be identical on every host.
    let originalZone = NSTimeZone.default
    defer { NSTimeZone.default = originalZone }

    let from = date("2026-01-01")
    let to = date("2026-01-05")
    var recordedKeysPerZone: [String: Set<String>] = [:]

    for identifier in Self.zones {
      NSTimeZone.default = try #require(TimeZone(identifier: identifier))
      let recorder = RecordingCryptoPriceClient(
        FixedCryptoPriceClient(
          prices: [
            "1:native": [
              "2026-01-01": dec("100"), "2026-01-02": dec("110"),
              "2026-01-03": dec("120"), "2026-01-04": dec("130"),
            ]
          ]))
      let service = try makeService(
        clients: [recorder], database: ProfileIndexDatabase.openInMemory(),
        now: { self.date("2026-02-01") })

      _ = await service.warmRange(for: ethInstrument, mapping: ethMapping, in: from...to)
      recordedKeysPerZone[identifier] = recorder.requestedDayKeys
    }

    // Every zone produced exactly the same set of requested day keys.
    let reference = try #require(recordedKeysPerZone["UTC"])
    #expect(!reference.isEmpty)
    for identifier in Self.zones {
      #expect(
        recordedKeysPerZone[identifier] == reference,
        "warmed days drifted in \(identifier)")
    }
  }
}

/// Records the UTC day keys spanned by every `dailyPrices(for:in:)`
/// request so a test can assert that `warmRange` asks for the same days
/// regardless of the host time zone.
private final class RecordingCryptoPriceClient: CryptoPriceClient {
  private let inner: any CryptoPriceClient
  private let recorded = OSAllocatedUnfairLock<Set<String>>(initialState: [])

  init(_ inner: any CryptoPriceClient) {
    self.inner = inner
  }

  var syncProvider: SyncProvider { inner.syncProvider }

  /// The union of UTC `YYYY-MM-DD` keys covered by all recorded requests.
  var requestedDayKeys: Set<String> {
    recorded.withLock { $0 }
  }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    try await inner.dailyPrice(for: mapping, on: date)
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    // Build the day keys outside the lock so the non-`Sendable` formatter
    // is never captured by the `@Sendable` `withLock` closure.
    let formatter = Self.makeUTCDayFormatter()
    var dayKeys: Set<String> = []
    var current = range.lowerBound
    while current <= range.upperBound {
      dayKeys.insert(formatter.string(from: current))
      guard let next = Calendar.utc.date(byAdding: .day, value: 1, to: current) else { break }
      current = next
    }
    let recordedKeys = dayKeys
    recorded.withLock { $0.formUnion(recordedKeys) }
    return try await inner.dailyPrices(for: mapping, in: range)
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    try await inner.currentPrices(for: mappings)
  }

  /// UTC day formatter so the recorded keys are themselves zone-invariant
  /// — the test asserts the *fetch* days don't drift, not the formatter.
  /// Built per call (cheap, test-only) to dodge a shared non-`Sendable`
  /// static.
  private static func makeUTCDayFormatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = .utc
    return formatter
  }
}
