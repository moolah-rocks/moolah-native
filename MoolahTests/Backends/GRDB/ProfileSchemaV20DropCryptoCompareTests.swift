// MoolahTests/Backends/GRDB/ProfileSchemaV20DropCryptoCompareTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Confirms `v20_drop_cryptocompare_symbol` runs cleanly.
///
/// The per-profile `instrument` table was dropped by v10 on every live
/// database, so the migration is effectively a no-op for all existing
/// profiles. This test confirms the migrator applies all migrations
/// through v20 (and, transitively, every migration registered after it)
/// without error.
@Suite("ProfileSchema — v20_drop_cryptocompare_symbol")
struct ProfileSchemaV20DropCryptoCompareTests {
  @Test("schema version reflects the latest migration")
  func versionIsLatest() {
    // Bumped alongside `v21_leg_analysis_uncategorised` — see
    // `ProfileSchema.version`'s doc comment ("bumped each time a
    // migration is added").
    #expect(ProfileSchema.version == 21)
  }

  @Test("v20 migration runs cleanly (per-profile instrument table was already dropped by v10)")
  func migrationRunsCleanly() throws {
    let queue = try DatabaseQueue()
    // Runs all registered migrations (v1 through the latest); must
    // complete without error.
    try ProfileSchema.migrator.migrate(queue)
    // The per-profile instrument table was dropped by v10_drop_shared_instrument_legacy
    // before v20 fires, so the v20 migration is a guarded no-op and the table is absent.
    let tableExists = try queue.read { database in try database.tableExists("instrument") }
    #expect(!tableExists)
  }
}
