// MoolahTests/Backends/GRDB/ProfileIndexSchemaV10Tests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms `v10_drop_cryptocompare_symbol` drops the `cryptocompare_symbol`
/// column from the `instrument` table in `profile-index.sqlite`.
@Suite("ProfileIndexSchema — v10_drop_cryptocompare_symbol")
struct ProfileIndexSchemaV10Tests {
  private func makeMigratedDatabase() throws -> DatabaseQueue {
    try ProfileIndexDatabase.openInMemory()
  }

  @Test("schema version reflects the v10 migration")
  func versionIsLatest() {
    #expect(ProfileIndexSchema.version == 10)
  }

  @Test("v10 drops the cryptocompare_symbol column from instrument")
  func cryptocompareSymbolColumnIsAbsent() throws {
    let queue = try makeMigratedDatabase()
    let hasColumn: Bool = try queue.read { database in
      try database.columns(in: "instrument").contains { $0.name == "cryptocompare_symbol" }
    }
    #expect(!hasColumn)
  }
}
