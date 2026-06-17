import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("v8_crypto_first_traded_on migration")
struct CryptoFirstTradedOnMigrationTests {
  @Test("v8 adds nullable first_traded_on and preserves existing rows")
  func addsColumnPreservingRows() throws {
    let dbQueue = try DatabaseQueue()
    try ProfileIndexSchema.migrator.migrate(dbQueue, upTo: "v7_purge_crypto_price_cache")
    try dbQueue.write { database in
      try database.execute(
        sql: """
          INSERT INTO crypto_token_meta (token_id, symbol, earliest_date, latest_date)
          VALUES ('1:native', 'ETH', '2021-01-01', '2026-06-01');
          """)
    }
    try ProfileIndexSchema.migrator.migrate(dbQueue)  // applies v8
    let (count, firstTraded): (Int, String?) = try dbQueue.read { database in
      let rowCount = try Table("crypto_token_meta").fetchCount(database)
      let firstTradedValue = try String.fetchOne(
        database, sql: "SELECT first_traded_on FROM crypto_token_meta WHERE token_id = '1:native'")
      return (rowCount, firstTradedValue)
    }
    #expect(count == 1)  // row preserved
    #expect(firstTraded == nil)  // new column defaults NULL
  }

  @Test("first_traded_on is writable after v8")
  func columnIsWritable() throws {
    let dbQueue = try DatabaseQueue()
    try ProfileIndexSchema.migrator.migrate(dbQueue)
    try dbQueue.write { database in
      try database.execute(
        sql: """
          INSERT INTO crypto_token_meta (token_id, symbol, earliest_date, latest_date, first_traded_on)
          VALUES ('1:native', 'ETH', '2024-10-01', '2026-06-01', '2024-10-01');
          """)
    }
    let firstTradedValue: String? = try dbQueue.read { database in
      try String.fetchOne(database, sql: "SELECT first_traded_on FROM crypto_token_meta")
    }
    #expect(firstTradedValue == "2024-10-01")
  }
}
