// MoolahTests/Backends/GRDB/ProfileIndexSchemaV3Tests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms `v3_shared_instrument_registry` creates the expected tables
/// in their final shape on `profile-index.sqlite`.
@Suite("ProfileIndexSchema — v3_shared_instrument_registry")
struct ProfileIndexSchemaV3Tests {
  private func makeMigratedDatabase() throws -> DatabaseQueue {
    // Match production: pragma config + migrator both via the project factory.
    try ProfileIndexDatabase.openInMemory()
  }

  @Test("schema version reflects the latest migration")
  func versionIsLatest() {
    // Bumped to 8 by `v8_crypto_first_traded_on`.
    #expect(ProfileIndexSchema.version == 8)
  }

  @Test("v3 creates the instrument table plus all six rate-cache tables")
  func v3CreatesAllExpectedTables() throws {
    let queue = try makeMigratedDatabase()

    let names: Set<String> = try queue.read { database in
      let rows = try Row.fetchAll(
        database, sql: "SELECT name FROM sqlite_master WHERE type='table'")
      return Set(rows.compactMap { $0["name"] as String? })
    }

    for table in [
      "instrument",
      "exchange_rate", "exchange_rate_meta",
      "stock_price", "stock_ticker_meta",
      "crypto_price", "crypto_token_meta",
    ] {
      #expect(names.contains(table), "missing \(table)")
    }
  }

  @Test("instrument.kind CHECK accepts every Instrument.Kind raw value and rejects others")
  func instrumentTableAcceptsValidKindsAndRejectsInvalid() throws {
    let queue = try makeMigratedDatabase()

    try queue.write { database in
      for kind in ["fiatCurrency", "stock", "cryptoToken"] {
        try database.execute(
          sql: """
            INSERT INTO instrument
            (id, record_name, kind, name, decimals, pricing_status)
            VALUES (?, ?, ?, ?, ?, 'priced')
            """,
          arguments: ["test-\(kind)", "test-\(kind)", kind, "Test \(kind)", 0])
      }
    }

    do {
      try queue.write { database in
        try database.execute(
          sql: """
            INSERT INTO instrument
            (id, record_name, kind, name, decimals, pricing_status)
            VALUES ('bogus', 'bogus', 'fiat', 'Bogus', 0, 'priced')
            """)
      }
      Issue.record("expected CHECK violation for kind='fiat'")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_CONSTRAINT)
    }
  }

  @Test("instrument.decimals CHECK rejects negative values")
  func instrumentTableEnforcesNonNegativeDecimals() throws {
    let queue = try makeMigratedDatabase()

    do {
      try queue.write { database in
        try database.execute(
          sql: """
            INSERT INTO instrument
            (id, record_name, kind, name, decimals, pricing_status)
            VALUES ('neg', 'neg', 'cryptoToken', 'Neg', -1, 'priced')
            """)
      }
      Issue.record("expected CHECK violation for decimals = -1")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_CONSTRAINT)
    }
  }

  @Test("instrument.pricing_status CHECK accepts priced/unpriced/spam and rejects others")
  func instrumentTableAcceptsValidPricingStatusesAndRejectsInvalid() throws {
    let queue = try makeMigratedDatabase()

    try queue.write { database in
      for status in ["priced", "unpriced", "spam"] {
        try database.execute(
          sql: """
            INSERT INTO instrument
            (id, record_name, kind, name, decimals, pricing_status)
            VALUES (?, ?, 'cryptoToken', ?, 0, ?)
            """,
          arguments: ["s-\(status)", "s-\(status)", "Status \(status)", status])
      }
    }

    do {
      try queue.write { database in
        try database.execute(
          sql: """
            INSERT INTO instrument
            (id, record_name, kind, name, decimals, pricing_status)
            VALUES ('bad', 'bad', 'cryptoToken', 'Bad', 0, 'wat')
            """)
      }
      Issue.record("expected CHECK violation for pricing_status='wat'")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_CONSTRAINT)
    }
  }

  @Test("all six rate-cache tables are STRICT, WITHOUT ROWID (post-v4 shape)")
  func allRateCacheTablesAreWithoutRowid() throws {
    let queue = try makeMigratedDatabase()

    let withoutRowid: Set<String> = try queue.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT name FROM sqlite_master
          WHERE type='table' AND sql LIKE '%WITHOUT ROWID%'
          """)
      return Set(rows.compactMap { $0["name"] as String? })
    }

    for table in [
      "exchange_rate", "exchange_rate_meta",
      "stock_price", "stock_ticker_meta",
      "crypto_price", "crypto_token_meta",
    ] {
      #expect(withoutRowid.contains(table), "\(table) must be WITHOUT ROWID")
    }
  }

  @Test("instrument is a ROWID table — encoded_system_fields BLOB dominates row size")
  func instrumentTableIsRowidNotWithoutRowid() throws {
    // The encoded_system_fields BLOB dominates row size, so WITHOUT
    // ROWID's interior-page packing would be a net loss. Match the
    // per-profile decision (see ProfileSchema+CoreFinancialGraph.swift).
    let queue = try makeMigratedDatabase()

    let isRowid: Bool = try queue.read { database in
      let sql =
        try String.fetchOne(
          database,
          sql: """
            SELECT sql FROM sqlite_master
            WHERE type='table' AND name='instrument'
            """) ?? ""
      return !sql.contains("WITHOUT ROWID")
    }
    #expect(isRowid, "instrument must be a ROWID table")
  }

  @Test("crypto_price uses price_usd column — not price")
  func cryptoPriceUsesPriceUsdColumn() throws {
    // Regression: an earlier draft of the plan used `price` instead of
    // `price_usd`. Confirm the actual column is price_usd to match the
    // per-profile DDL.
    let queue = try makeMigratedDatabase()

    try queue.write { database in
      try database.execute(
        sql:
          "INSERT INTO crypto_price (token_id, date, price_usd) VALUES (?, ?, ?)",
        arguments: ["bitcoin", "2026-05-09", 50_000.0])
    }
    let row: Row? = try queue.read { database in
      try Row.fetchOne(database, sql: "SELECT * FROM crypto_price")
    }
    let stored = try #require(row)
    #expect(stored["price_usd"] as Double? == 50_000.0)
  }

  @Test("exchange_rate primary key column order is (base, date, quote)")
  func exchangeRatePrimaryKeyOrderIsBaseDateQuote() throws {
    // The base-leading PK is what justifies omitting the per-profile
    // exchange_rate_lookup index — `loadCache` issues `WHERE base = ?`
    // and resolves quote/date in-memory.
    let queue = try makeMigratedDatabase()

    let pkColumns: [String] = try queue.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: """
          SELECT name FROM pragma_table_info('exchange_rate')
          WHERE pk > 0
          ORDER BY pk
          """)
      return rows.compactMap { $0["name"] as String? }
    }
    #expect(pkColumns == ["base", "date", "quote"])
  }
}
