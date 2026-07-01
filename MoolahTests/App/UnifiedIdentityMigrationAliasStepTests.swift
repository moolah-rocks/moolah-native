// MoolahTests/App/UnifiedIdentityMigrationAliasStepTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

extension MigrationTestHarness {
  /// Reads `alias_of` from the shared `instrument` table for the given id.
  /// Returns `nil` when the row does not exist OR when `alias_of IS NULL`.
  func aliasOf(_ id: String) async throws -> String? {
    try await migration.profileIndexDatabase.read { database in
      try String.fetchOne(
        database,
        sql: "SELECT alias_of FROM instrument WHERE id = ?",
        arguments: [id])
    }
  }
}

@MainActor
@Suite
struct UnifiedIdentityMigrationAliasStepTests {
  @Test("alias step sets alias_of on retired rows, canonical rows untouched, idempotent")
  func aliasesRetiredRows() async throws {
    let harness = try MigrationTestHarness.make()
    try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism, .ethBase])
    let mapping = try await harness.migration.deriveMapping()

    try await harness.migration.applyAliasStep(mapping: mapping)

    #expect(try await harness.aliasOf("10:native") == "1:native")
    #expect(try await harness.aliasOf("8453:native") == "1:native")
    #expect(try await harness.aliasOf("1:native") == nil)  // canonical stays NULL

    // Idempotent: second run leaves the same values.
    try await harness.migration.applyAliasStep(mapping: mapping)
    #expect(try await harness.aliasOf("10:native") == "1:native")
  }

  @Test("applyAliasStep rolls back every alias write when one UPDATE fails mid-loop")
  func rollsBackOnMidLoopFailure() async throws {
    let harness = try MigrationTestHarness.make()
    try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism, .ethBase])
    // Two retired entries: "10:native" -> "1:native" and "8453:native" -> "1:native".
    let mapping = try await harness.migration.deriveMapping()

    // A temp trigger raises FAIL once one row is already aliased, forcing the
    // second UPDATE in the loop to throw. count(*) >= 1 (not == 1) makes the
    // trigger fire regardless of dictionary iteration order.
    try await harness.migration.profileIndexDatabase.write { database in
      try database.execute(
        sql: """
          CREATE TEMP TRIGGER fail_on_second_alias_update
          BEFORE UPDATE OF alias_of ON instrument
          WHEN (SELECT count(*) FROM instrument WHERE alias_of IS NOT NULL) >= 1
          BEGIN SELECT RAISE(FAIL, 'test-rollback'); END
          """)
    }

    await #expect(throws: (any Error).self) {
      try await harness.migration.applyAliasStep(mapping: mapping)
    }

    // The whole transaction rolled back: neither retired row is aliased.
    #expect(try await harness.aliasOf("10:native") == nil)
    #expect(try await harness.aliasOf("8453:native") == nil)
  }
}
