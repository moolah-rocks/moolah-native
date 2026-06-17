// MoolahTests/Backends/PurgeCryptoPriceCacheMigrationTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms that `v7_purge_crypto_price_cache` empties the two crypto rate-cache
/// tables (`crypto_price` + `crypto_token_meta`) so the DefiLlama daily-gap
/// rows cached before the 12h-oversampling fix re-backfill densely. Both tables
/// must be wiped together: the cache bounds that drive `ContiguousFetchPlanner`
/// live in `crypto_token_meta`, so leaving the meta row would keep the planner
/// believing the gappy interior is already covered. The stock and exchange-rate
/// caches are not affected by the aliasing and must be left intact.
@Suite("v7_purge_crypto_price_cache migration")
struct PurgeCryptoPriceCacheMigrationTests {
  @Test("v7 wipes both crypto cache tables but leaves stock/exchange caches intact")
  func purgesCryptoCachesOnly() throws {
    let dbQueue = try DatabaseQueue()

    // Migrate to v6 (the state before the new purge migration).
    try ProfileIndexSchema.migrator.migrate(dbQueue, upTo: "v6_purge_rate_caches")

    // Seed the two crypto cache tables plus one stock and one exchange row.
    try dbQueue.write { database in
      try database.execute(
        sql: """
          INSERT INTO crypto_token_meta (token_id, symbol, earliest_date, latest_date)
          VALUES ('1:native', 'ETH', '2024-01-01', '2024-12-31');
          INSERT INTO crypto_price (token_id, date, price_usd)
          VALUES ('1:native', '2024-09-15', 2500.0);

          INSERT INTO stock_ticker_meta (ticker, instrument_id, earliest_date, latest_date)
          VALUES ('VGS.AX', 'inst-1', '2024-01-01', '2024-12-31');
          INSERT INTO stock_price (ticker, date, price)
          VALUES ('VGS.AX', '2024-09-15', 149.82);

          INSERT INTO exchange_rate_meta (base, earliest_date, latest_date)
          VALUES ('USD', '2024-01-01', '2024-12-31');
          INSERT INTO exchange_rate (base, quote, date, rate)
          VALUES ('USD', 'AUD', '2024-09-15', 1.55);
          """)
    }

    // Apply v7.
    try ProfileIndexSchema.migrator.migrate(dbQueue)

    let counts: [String: Int] = try dbQueue.read { database in
      var result: [String: Int] = [:]
      for table in [
        "crypto_price", "crypto_token_meta",
        "stock_price", "stock_ticker_meta",
        "exchange_rate", "exchange_rate_meta",
      ] {
        result[table] = try Table(table).fetchCount(database)
      }
      return result
    }
    #expect(counts["crypto_price"] == 0)
    #expect(counts["crypto_token_meta"] == 0)
    // The aliasing is crypto-specific — these must survive.
    #expect(counts["stock_price"] == 1)
    #expect(counts["stock_ticker_meta"] == 1)
    #expect(counts["exchange_rate"] == 1)
    #expect(counts["exchange_rate_meta"] == 1)
  }

  @Test("schema is intact after v7 — re-inserts succeed")
  func schemaIntactAfterPurge() throws {
    let dbQueue = try DatabaseQueue()
    try ProfileIndexSchema.migrator.migrate(dbQueue)

    try dbQueue.write { database in
      try database.execute(
        sql: """
          INSERT INTO crypto_token_meta (token_id, symbol, earliest_date, latest_date)
          VALUES ('1:native', 'ETH', '2026-01-01', '2026-06-01');
          INSERT INTO crypto_price (token_id, date, price_usd)
          VALUES ('1:native', '2026-06-01', 3000.0);
          """)
    }

    let price: Double? = try dbQueue.read { database in
      try Double.fetchOne(
        database, sql: "SELECT price_usd FROM crypto_price WHERE token_id = '1:native'")
    }
    #expect(price == 3000.0)
  }
}
