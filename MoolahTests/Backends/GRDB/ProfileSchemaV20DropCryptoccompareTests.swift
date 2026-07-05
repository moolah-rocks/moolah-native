// MoolahTests/Backends/GRDB/ProfileSchemaV20DropCryptoccompareTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms `v20_drop_cryptocompare_symbol` runs cleanly.
///
/// The per-profile `instrument` table was dropped by v10 on every live
/// database, so the migration is effectively a no-op for all existing
/// profiles. This test confirms the migrator applies all migrations
/// through v20 without error.
@Suite("ProfileSchema — v20_drop_cryptocompare_symbol")
struct ProfileSchemaV20DropCryptoccompareTests {
  @Test("schema version reflects the v20 migration")
  func versionIsLatest() {
    #expect(ProfileSchema.version == 20)
  }

  @Test("v20 migration runs cleanly (per-profile instrument table was already dropped by v10)")
  func migrationRunsCleanly() throws {
    let queue = try DatabaseQueue()
    // Runs all migrations v1 through v20; must complete without error.
    try ProfileSchema.migrator.migrate(queue)
    #expect(Bool(true))  // Reaching here means no migration threw.
  }
}
