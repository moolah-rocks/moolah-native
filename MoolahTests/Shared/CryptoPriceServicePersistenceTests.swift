// MoolahTests/Shared/CryptoPriceServicePersistenceTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Persistence tests for `CryptoPriceService`. Covers the SQL save/load
/// round-trip, the rollback contract for
/// `CryptoPriceService.persistDelta`, and the delta-write + in-range
/// short-circuit semantics that keep chart renders off the GRDB serial
/// queue.
@Suite("CryptoPriceService — Persistence")
struct CryptoPriceServicePersistenceTests {
  private let ethInstrument = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18
  )
  private let ethMapping = CryptoProviderMapping(
    instrumentId: "1:native", coingeckoId: "ethereum",
    binanceSymbol: "ETHUSDT"
  )

  private var ethRegistration: CryptoRegistration {
    CryptoRegistration(instrument: ethInstrument, mapping: ethMapping)
  }

  private func makeService(
    clients: [CryptoPriceClient] = [],
    prices: [String: [String: Decimal]] = [:],
    shouldFail: Bool = false,
    database: DatabaseQueue? = nil
  ) throws -> CryptoPriceService {
    let clientList =
      clients.isEmpty
      ? [FixedCryptoPriceClient(prices: prices, shouldFail: shouldFail)]
      : clients
    let resolved = try database ?? ProfileIndexDatabase.openInMemory()
    return CryptoPriceService(clients: clientList, database: resolved)
  }

  private func date(_ string: String) throws -> Date {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    return try #require(formatter.date(from: string))
  }

  // MARK: - SQL round-trip

  /// Two service instances sharing the same `DatabaseQueue` — the second
  /// must load prices persisted by the first.
  @Test
  func sqlRoundTripPreservesData() async throws {
    let database = try ProfileIndexDatabase.openInMemory()

    let service1 = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45")]],
      database: database
    )
    let price = try await service1.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2026-04-10"))
    #expect(price == dec("1623.45"))

    let service2 = try makeService(shouldFail: true, database: database)
    let cached = try await service2.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2026-04-10"))
    #expect(cached == dec("1623.45"))
  }

  // MARK: - Rollback for multi-statement save

  /// Rollback contract: `CryptoPriceService.persistDelta` writes the
  /// delta rows (`INSERT OR REPLACE`) plus the meta row inside a single
  /// `database.write` transaction. If any statement throws, every
  /// statement in the same closure must roll back together so prior
  /// rows survive untouched.
  ///
  /// Drives the **production** save path by installing a trigger that
  /// raises `ABORT` on a sentinel date. A second fetch through the
  /// service merges that sentinel, `persistDelta` writes the row, the
  /// trigger aborts mid-transaction, and SQLite rolls the meta insert
  /// back along with it.
  @Test
  func saveCacheRollsBackOnInsertFailure() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let service = try makeService(
      prices: ["1:native": ["2026-04-10": dec("1623.45"), "2026-04-11": dec("1700")]],
      database: database
    )
    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2026-04-10"))

    let beforeCount = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .fetchCount(database)
    }
    #expect(beforeCount > 0)

    // Install a trigger that aborts inserts carrying the sentinel date.
    // The trigger fires inside `persistDelta`'s transaction so the
    // failed `INSERT OR REPLACE` and the meta insert roll back together.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_save_cache
          BEFORE INSERT ON crypto_price
          WHEN NEW.date = '9999-12-31'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    // Drive the real `persistDelta` by feeding a price set that
    // contains the sentinel date.
    let failingService = try makeService(
      prices: ["1:native": ["9999-12-31": dec("9999.0")]],
      database: database
    )
    _ = try? await failingService.price(
      for: ethInstrument, mapping: ethMapping, on: try date("9999-12-31"))

    let afterCount = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .fetchCount(database)
    }
    #expect(afterCount == beforeCount)

    // Probe a specific priming row to prove the original insert
    // survived the aborted transaction. The exact-row check matters
    // because `persistDelta` is upsert-only (no DELETE), so a row-count
    // assertion alone would pass even if the rollback hadn't fired.
    // Re-looking-up `(1:native, 2026-04-10, 1623.45)` by value proves
    // the original write is intact.
    let surviving = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .filter(CryptoPriceRecord.Columns.date == "2026-04-10")
        .fetchOne(database)
    }
    #expect(surviving != nil)
    #expect(surviving?.priceUsd == 1623.45)
  }

  // MARK: - Persistence efficiency

  /// `prefetchLatest` must skip the disk write when the latest price is
  /// already cached at the same value. The pre-fix code unconditionally
  /// rewrote the entire token partition on every prefetch, so a periodic
  /// "no change since last poll" tick still saturated the GRDB queue.
  /// Detected via an `AFTER INSERT ON crypto_price` counter trigger.
  @Test
  func prefetchWithUnchangedPriceDoesNotRewriteCache() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    let today = formatter.string(from: Date())
    let service = try makeService(
      prices: ["1:native": [today: dec("1623.45")]],
      database: database
    )

    // Prime the cache by running prefetchLatest once.
    await service.prefetchLatest(for: [ethRegistration])

    // Install the counter only AFTER priming so we measure just the
    // second (no-op) prefetch.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TABLE crypto_price_write_counter (n INTEGER NOT NULL);
          INSERT INTO crypto_price_write_counter (n) VALUES (0);
          CREATE TRIGGER count_crypto_price_writes
          AFTER INSERT ON crypto_price
          BEGIN
              UPDATE crypto_price_write_counter SET n = n + 1;
          END;
          """)
    }

    // Same price still in client; prefetch returns unchanged data.
    await service.prefetchLatest(for: [ethRegistration])

    let writes = try await database.read { database in
      try Int.fetchOne(database, sql: "SELECT n FROM crypto_price_write_counter") ?? -1
    }
    #expect(writes == 0)
  }

  /// `persistDelta` must persist only the rows the latest fetch added
  /// or changed. With the pre-fix delete-all + insert-each path a fetch
  /// returning N existing dates plus M new dates wrote N+M rows; with
  /// delta-write only the M new dates are persisted.
  @Test
  func saveCacheWritesOnlyChangedRows() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    // Client has data for both Apr 10 (priming target) and Apr 15
    // (subsequent target). The Apr 15 forward extension fetch returns
    // both dates, but Apr 10 is already cached at the same value.
    let service = try makeService(
      prices: [
        "1:native": [
          "2026-04-10": dec("1623.45"),
          "2026-04-15": dec("1700.00"),
        ]
      ],
      database: database
    )

    // Prime cache by fetching Apr 10.
    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2026-04-10"))

    let primedCount = try await database.read { database in
      try CryptoPriceRecord
        .filter(CryptoPriceRecord.Columns.tokenId == "1:native")
        .fetchCount(database)
    }
    #expect(primedCount >= 1)

    // Install the counter after priming so it only sees the second save.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TABLE crypto_price_write_counter (n INTEGER NOT NULL);
          INSERT INTO crypto_price_write_counter (n) VALUES (0);
          CREATE TRIGGER count_crypto_price_writes
          AFTER INSERT ON crypto_price
          BEGIN
              UPDATE crypto_price_write_counter SET n = n + 1;
          END;
          """)
    }

    // Forward extension for Apr 15 returns {Apr 10, Apr 15}. Apr 10 is
    // unchanged; only Apr 15 is a delta.
    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2026-04-15"))

    let writes = try await database.read { database in
      try Int.fetchOne(database, sql: "SELECT n FROM crypto_price_write_counter") ?? -1
    }
    #expect(writes == 1)
  }

  /// Requests for a date strictly inside `[earliestDate, latestDate]`
  /// whose exact cached price is missing must be served via
  /// `fallbackPrice` without going to the network. This is the chart
  /// hot path: every non-trading-day in the visible range falls into
  /// this case, and the pre-fix code dispatched a 30-day fetch on
  /// every one of them. Mirrors `ExchangeRateService.rate(...)`'s
  /// in-range short-circuit.
  @Test
  func inRangeMissUsesFallbackWithoutFetching() async throws {
    let inner = FixedCryptoPriceClient(prices: [
      "1:native": [
        "2026-04-10": dec("1623.45"),  // Fri
        "2026-04-13": dec("1700.00"),  // Mon
      ]
    ])
    let client = CountingCryptoPriceClient(inner)
    let service = try makeService(clients: [client])

    // Prime cache so the bounds span Fri … Mon. After both calls the
    // in-range request for Sat lives strictly inside this window.
    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2026-04-10"))
    _ = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2026-04-13"))
    let primedFetches = client.fetchCount

    // Saturday is in `[2026-04-10, 2026-04-13]`. The exact tuple is
    // missing (the provider posts no Saturday price for this token);
    // `fallbackPrice` must resolve it from Friday without a fetch.
    let saturdayPrice = try await service.price(
      for: ethInstrument, mapping: ethMapping, on: try date("2026-04-11"))

    #expect(saturdayPrice == dec("1623.45"))
    #expect(client.fetchCount == primedFetches)
  }
}
