// MoolahTests/Backends/GRDB/PurgeIntradayCachesMigrationTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pinned to the v7 era: `v10_drop_shared_instrument_legacy` later
/// drops the six rate-cache tables from the per-profile schema, so a
/// full `migrate(queue)` would leave them absent. v7's behaviour is
/// only meaningful while the tables exist, so these tests migrate
/// `upTo: "v7_purge_intraday_cached_prices"` — each shipped migration
/// keeps its own era's contract.
@Suite("v7_purge_intraday_cached_prices migration")
struct PurgeIntradayCachesMigrationTests {
  @Test("seeded rows in all six cache tables are wiped by v7")
  func purgesAllCacheTables() throws {
    let queue = try DatabaseQueue()

    // Migrate up to v6 (state where the bug could persist poisoned rows).
    try ProfileSchema.migrator.migrate(queue, upTo: "v6_account_valuation_mode")

    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO exchange_rate_meta (base, earliest_date, latest_date)
          VALUES ('USD', '2026-04-01', '2026-05-04');
          INSERT INTO exchange_rate (base, quote, date, rate)
          VALUES ('USD', 'AUD', '2026-05-04', 1.55);

          INSERT INTO stock_ticker_meta (ticker, instrument_id, earliest_date, latest_date)
          VALUES ('VGS.AX', 'AUD', '2026-04-01', '2026-05-05');
          INSERT INTO stock_price (ticker, date, price)
          VALUES ('VGS.AX', '2026-05-05', 149.82);

          INSERT INTO crypto_token_meta (token_id, symbol, earliest_date, latest_date)
          VALUES ('1:native', 'ETH', '2026-04-01', '2026-05-04');
          INSERT INTO crypto_price (token_id, date, price_usd)
          VALUES ('1:native', '2026-05-04', 1640.0);
          """)
    }

    // Now run v7 — should empty every cache table. Stop at v7: v10
    // later drops these tables, which would defeat the assertions.
    try ProfileSchema.migrator.migrate(queue, upTo: "v7_purge_intraday_cached_prices")

    try queue.read { database in
      for table in [
        "exchange_rate", "exchange_rate_meta",
        "stock_price", "stock_ticker_meta",
        "crypto_price", "crypto_token_meta",
      ] {
        let count = try Table(table).fetchCount(database)
        #expect(count == 0, "expected \(table) to be empty after v7, got \(count)")
      }
    }
  }

  @Test("schema is intact after v7 — re-inserts work")
  func schemaIntactAfterPurge() throws {
    let queue = try DatabaseQueue()
    try ProfileSchema.migrator.migrate(queue, upTo: "v7_purge_intraday_cached_prices")

    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO stock_ticker_meta (ticker, instrument_id, earliest_date, latest_date)
          VALUES ('VGS.AX', 'AUD', '2026-05-04', '2026-05-04');
          INSERT INTO stock_price (ticker, date, price)
          VALUES ('VGS.AX', '2026-05-04', 149.91);
          """)
    }

    let price: Double? = try queue.read { database in
      try Double.fetchOne(database, sql: "SELECT price FROM stock_price WHERE ticker = 'VGS.AX'")
    }
    #expect(price == 149.91)
  }
}
