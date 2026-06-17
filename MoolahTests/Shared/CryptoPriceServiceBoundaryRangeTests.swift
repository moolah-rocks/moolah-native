// MoolahTests/Shared/CryptoPriceServiceBoundaryRangeTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Regression cover for the inverted-range trap in the crypto cache
/// backward-extension path. The extension built `requestedDate...fetchEnd`,
/// where `fetchEnd` is midnight of (`earliestDate` − 1) while
/// `requestedDate` is a noon-anchored day token from the daily-balance walk.
/// When the requested day is exactly that boundary day, `requestedDate`
/// (noon) > `fetchEnd` (midnight of the same calendar day), so the
/// `ClosedRange` initializer trapped (`EXC_BREAKPOINT`) — crashing on launch
/// for any profile whose chart history reaches the day before a crypto price
/// cache begins. The bounded `extendContiguously` /
/// `ContiguousFetchPlanner`-driven path no longer builds such a range.
@Suite("CryptoPriceService — boundary range")
struct CryptoPriceServiceBoundaryRangeTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT"
  )

  private func makeService(
    prices: [String: [String: Decimal]] = [:],
    database: DatabaseQueue,
    now: @Sendable @escaping () -> Date
  ) throws -> CryptoPriceService {
    let client = FixedCryptoPriceClient(prices: prices)
    let utc = try #require(TimeZone(identifier: "UTC"))
    return CryptoPriceService(
      clients: [client],
      database: database,
      resolutionClient: nil,
      now: now,
      timeZone: utc)
  }

  /// Midnight-UTC anchor for `YYYY-MM-DD`, matching the cache-key formatter.
  private func midnight(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  /// Noon-UTC anchor — mirrors the day tokens produced by the daily-balance
  /// walk (`FinancialMonth` / `Calendar.utc`), which is what reaches
  /// `CryptoPriceService.price` in production and triggers the trap.
  private func noon(_ string: String) throws -> Date {
    try midnight(string).addingTimeInterval(12 * 60 * 60)
  }

  /// Before the fix this traps when the requested day is exactly the day
  /// immediately before the cache's `earliestDate`: `requestedDate` (noon)
  /// exceeds `fetchEnd` (midnight of the same day), inverting the range.
  /// After the fix the branch falls through to the single-day window, which
  /// fetches the boundary day and returns its price.
  @Test
  func noonRequestOnDayBeforeEarliestDoesNotTrap() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let frozen = try self.midnight("2025-09-01")

    // Seed the shared database with a single day so the cache's
    // `earliestDate` is exactly 2025-08-15. The seeding client only knows
    // that day, so it can't accidentally widen the cached window backward.
    let seeder = try makeService(
      prices: ["1:native": ["2025-08-15": dec("1510.00")]],
      database: database,
      now: { frozen })
    _ = try await seeder.price(
      for: ethInstrument, mapping: ethMapping, on: try self.midnight("2025-08-15"))

    // A fresh service hydrates the cache from the database (earliestDate =
    // 2025-08-15) and then receives a noon-anchored request for the day
    // immediately before it — the daily-balance-walk shape that traps. Its
    // client knows 2025-08-14, so the single-day fallthrough returns it.
    let reader = try makeService(
      prices: ["1:native": ["2025-08-14": dec("1500.00")]],
      database: database,
      now: { frozen })
    let price = try await reader.price(
      for: ethInstrument, mapping: ethMapping, on: try self.noon("2025-08-14"))
    #expect(price == dec("1500.00"))
  }
}
