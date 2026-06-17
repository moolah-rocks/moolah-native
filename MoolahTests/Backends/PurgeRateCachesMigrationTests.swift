// MoolahTests/Backends/PurgeRateCachesMigrationTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms that `v6_purge_rate_caches` empties all six rate-cache tables in
/// the profile-index database, so gappy legacy cache rows are not carried
/// forward into the contiguous-fill era.
@Suite("v6_purge_rate_caches migration")
struct PurgeRateCachesMigrationTests {
  @Test("seeded rows in all six cache tables are wiped by v6")
  func purgesAllSixCacheTables() throws {
    let dbQueue = try DatabaseQueue()

    // Migrate to v5 (the state before the purge migration).
    try ProfileIndexSchema.migrator.migrate(dbQueue, upTo: "v5_deletion_journal")

    // Seed one row in each of the six rate-cache tables.
    try dbQueue.write { database in
      try database.execute(
        sql: """
          INSERT INTO exchange_rate_meta (base, earliest_date, latest_date)
          VALUES ('USD', '2025-01-01', '2025-12-31');
          INSERT INTO exchange_rate (base, quote, date, rate)
          VALUES ('USD', 'AUD', '2025-06-01', 1.55);

          INSERT INTO stock_ticker_meta (ticker, instrument_id, earliest_date, latest_date)
          VALUES ('VGS.AX', 'inst-1', '2025-01-01', '2025-12-31');
          INSERT INTO stock_price (ticker, date, price)
          VALUES ('VGS.AX', '2025-06-01', 149.82);

          INSERT INTO crypto_token_meta (token_id, symbol, earliest_date, latest_date)
          VALUES ('1:native', 'ETH', '2025-01-01', '2025-12-31');
          INSERT INTO crypto_price (token_id, date, price_usd)
          VALUES ('1:native', '2025-06-01', 2500.0);
          """)
    }

    // Apply v6 — should empty every cache table.
    try ProfileIndexSchema.migrator.migrate(dbQueue)

    try dbQueue.read { database in
      for table in [
        "crypto_price", "crypto_token_meta",
        "stock_price", "stock_ticker_meta",
        "exchange_rate", "exchange_rate_meta",
      ] {
        let count = try Table(table).fetchCount(database)
        #expect(
          count == 0, "expected \(table) to be empty after v6_purge_rate_caches, got \(count)")
      }
    }
  }

  @Test("schema is intact after v6 — re-inserts succeed")
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
        database,
        sql: "SELECT price_usd FROM crypto_price WHERE token_id = '1:native'"
      )
    }
    #expect(price == 3000.0)
  }
}
