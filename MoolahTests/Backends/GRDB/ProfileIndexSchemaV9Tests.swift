// MoolahTests/Backends/GRDB/ProfileIndexSchemaV9Tests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms `v9_add_instrument_alias_of` adds the local-only `alias_of`
/// column + `instrument_by_alias` partial index to `profile-index.sqlite`,
/// and that the column is unreachable via the Codable `InstrumentRow`
/// mapping (so no upsert / sync apply can clobber it).
@Suite("ProfileIndexSchema — v9_add_instrument_alias_of")
struct ProfileIndexSchemaV9Tests {
  private func makeMigratedDatabase() throws -> DatabaseQueue {
    try ProfileIndexDatabase.openInMemory()
  }

  @Test("schema version reflects the v9 migration")
  func versionIsLatest() {
    #expect(ProfileIndexSchema.version == 9)
  }

  @Test("v9 adds the alias_of column to the instrument table")
  func aliasOfColumnExists() throws {
    let queue = try makeMigratedDatabase()
    let hasColumn: Bool = try queue.read { database in
      try database.columns(in: "instrument").contains { $0.name == "alias_of" }
    }
    #expect(hasColumn)
  }

  @Test("v9 creates the instrument_by_alias partial index")
  func aliasIndexExists() throws {
    let queue = try makeMigratedDatabase()
    let names: Set<String> = try queue.read { database in
      let rows = try Row.fetchAll(
        database,
        sql: "SELECT name FROM sqlite_master WHERE type='index'")
      return Set(rows.compactMap { $0["name"] as String? })
    }
    #expect(names.contains("instrument_by_alias"))
  }

  @Test("CHECK rejects a self-referential alias_of")
  func checkRejectsSelfReference() throws {
    let queue = try makeMigratedDatabase()
    do {
      try queue.write { database in
        try database.execute(
          sql: """
            INSERT INTO instrument
              (id, record_name, kind, name, decimals, alias_of)
            VALUES ('1:native', '1:native', 'cryptoToken', 'Ethereum', 18, '1:native');
            """)
      }
      Issue.record("expected CHECK constraint violation for self-referential alias_of")
    } catch let error as DatabaseError {
      #expect(error.resultCode == .SQLITE_CONSTRAINT)
    }
  }

  @Test("a non-self alias_of is accepted")
  func acceptsNonSelfAlias() throws {
    let queue = try makeMigratedDatabase()
    try queue.write { database in
      try database.execute(
        sql: """
          INSERT INTO instrument
            (id, record_name, kind, name, decimals, alias_of)
          VALUES ('10:native', '10:native', 'cryptoToken', 'Ethereum', 18, '1:native');
          """)
    }
    let stored: String? = try queue.read { database in
      try String.fetchOne(
        database, sql: "SELECT alias_of FROM instrument WHERE id = '10:native'")
    }
    #expect(stored == "1:native")
  }

  @Test("a Codable InstrumentRow update cannot clobber alias_of")
  func codableUpdateDoesNotClobberAliasOf() throws {
    let queue = try makeMigratedDatabase()

    // Seed a crypto row via the Codable record (no alias_of in CodingKeys),
    // then set alias_of via raw SQL — mirroring how the data migration writes it.
    try queue.write { database in
      var row = InstrumentRow(
        id: "10:native", recordName: "10:native", kind: "cryptoToken",
        name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
        chainId: 10, contractAddress: nil, coingeckoId: "ethereum",
        cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT",
        encodedSystemFields: nil, pricingStatus: "priced")
      try row.insert(database)
      try database.execute(
        sql: "UPDATE instrument SET alias_of = '1:native' WHERE id = '10:native'")

      // A normal Codable update (as registerCrypto / sync-apply would issue)
      // rewrites the mapped columns only.
      row.name = "Ether"
      try row.update(database)
    }

    let (name, aliasOf): (String, String?) = try queue.read { database in
      let row = try #require(
        try Row.fetchOne(
          database,
          sql: "SELECT name, alias_of FROM instrument WHERE id = '10:native'"))
      return (row["name"], row["alias_of"])
    }
    #expect(name == "Ether")  // Codable update landed…
    #expect(aliasOf == "1:native")  // …without touching the local-only column.
  }
}
