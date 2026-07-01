// MoolahTests/App/UnifiedIdentityMigrationFkRewriteTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

// MARK: - Per-profile database cache

/// Stores one in-memory `DatabaseQueue` per profile UUID so the same database
/// is returned to both the test (seeding + assertions) and the migration
/// (`dataDatabaseProvider` closure). Marked `@unchecked Sendable` because
/// all test access is on the main actor; the `@Sendable` closure requirement
/// on `dataDatabaseProvider` requires the captured type to be `Sendable`.
private final class ProfileDatabaseCache: @unchecked Sendable {
  private var databases: [UUID: DatabaseQueue] = [:]

  func database(for profileId: UUID) throws -> DatabaseQueue {
    if let existing = databases[profileId] { return existing }
    let queue = try ProfileDatabase.openInMemory()
    databases[profileId] = queue
    return queue
  }
}

// MARK: - Harness factory for profile-rewrite tests

/// Returns a `MigrationTestHarness` whose `dataDatabaseProvider` is backed by
/// `cache`, so seeding and the migration share the same per-profile database.
@MainActor
private func makeProfileRewriteHarness() throws -> (
  harness: MigrationTestHarness, cache: ProfileDatabaseCache
) {
  let cache = ProfileDatabaseCache()
  let indexDatabase = try ProfileIndexDatabase.openInMemory()
  let registry = GRDBInstrumentRegistryRepository(database: indexDatabase)
  let resolver = CanonicalInstrumentResolver()
  let suiteName = "test-profile-rewrite-\(UUID().uuidString)"
  let defaults = UserDefaults(suiteName: suiteName) ?? .standard
  defaults.removePersistentDomain(forName: suiteName)
  let migration = UnifiedInstrumentIdentityMigration(
    profileIndexDatabase: indexDatabase,
    dataDatabaseProvider: { profileId in try cache.database(for: profileId) },
    allProfileIds: { [] },
    registry: registry,
    resolver: resolver,
    rePush: { _ in },
    userDefaults: defaults)
  let harness = MigrationTestHarness(registry: registry, resolver: resolver, migration: migration)
  return (harness, cache)
}

// MARK: - Seeding helpers

/// Inserts one row into each of the six FK tables (transaction_leg, earmark,
/// earmark_budget_item, account_group, investment_value) and the defensive
/// account column. All instrument_id columns point at `10:native` (retired).
/// The earmark.savings_target_instrument_id is set to `8453:native` so both
/// retired ids are covered in the mapping under test.
/// FK enforcement is OFF after v5_drop_foreign_keys, so parent rows are not
/// required — transaction_id, earmark_id, account_id, and category_id can be
/// arbitrary UUIDs.
private func seedRetiredRows(_ database: Database) throws {
  let legId = UUID()
  try database.execute(
    sql:
      "INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id, quantity, type, sort_order) VALUES (?, ?, ?, '10:native', 100, 'income', 0)",
    arguments: [legId, "TxLeg|\(legId.uuidString)", UUID()])
  let earmarkId = UUID()
  try database.execute(
    sql:
      "INSERT INTO earmark (id, record_name, name, position, is_hidden, instrument_id, savings_target_instrument_id) VALUES (?, ?, 'Savings', 0, 0, '10:native', '8453:native')",
    arguments: [earmarkId, "Earmark|\(earmarkId.uuidString)"])
  let ebiId = UUID()
  try database.execute(
    sql:
      "INSERT INTO earmark_budget_item (id, record_name, earmark_id, category_id, amount, instrument_id) VALUES (?, ?, ?, ?, 500, '10:native')",
    arguments: [ebiId, "EBI|\(ebiId.uuidString)", earmarkId, UUID()])
  let groupId = UUID()
  try database.execute(
    sql:
      "INSERT INTO account_group (id, record_name, name, bucket, instrument_id, position) VALUES (?, ?, 'ETH Wallets', 'investments', '10:native', 0)",
    arguments: [groupId, "AG|\(groupId.uuidString)"])
  let ivId = UUID()
  try database.execute(
    sql:
      "INSERT INTO investment_value (id, record_name, account_id, date, value, instrument_id) VALUES (?, ?, ?, '2024-01-01', 1000, '10:native')",
    arguments: [ivId, "IV|\(ivId.uuidString)", UUID()])
  let acctId = UUID()
  try database.execute(
    sql:
      "INSERT INTO account (id, record_name, name, type, instrument_id, position, is_hidden) VALUES (?, ?, 'ETH Account', 'investment', '10:native', 0, 0)",
    arguments: [acctId, "Acct|\(acctId.uuidString)"])
}

/// Inserts one row into each of the six FK tables with a fiat instrument_id
/// (`AUD`) that is not a key in any mapping under test.
private func seedUnmappedRows(_ database: Database) throws {
  let legId = UUID()
  try database.execute(
    sql:
      "INSERT INTO transaction_leg (id, record_name, transaction_id, instrument_id, quantity, type, sort_order) VALUES (?, ?, ?, 'AUD', 50, 'expense', 0)",
    arguments: [legId, "TxLeg|\(legId.uuidString)", UUID()])
  let earmarkId = UUID()
  try database.execute(
    sql:
      "INSERT INTO earmark (id, record_name, name, position, is_hidden, instrument_id) VALUES (?, ?, 'Budget', 0, 0, 'AUD')",
    arguments: [earmarkId, "Earmark|\(earmarkId.uuidString)"])
  let ebiId = UUID()
  try database.execute(
    sql:
      "INSERT INTO earmark_budget_item (id, record_name, earmark_id, category_id, amount, instrument_id) VALUES (?, ?, ?, ?, 200, 'AUD')",
    arguments: [ebiId, "EBI|\(ebiId.uuidString)", earmarkId, UUID()])
  let groupId = UUID()
  try database.execute(
    sql:
      "INSERT INTO account_group (id, record_name, name, bucket, instrument_id, position) VALUES (?, ?, 'AUD Accounts', 'current', 'AUD', 0)",
    arguments: [groupId, "AG|\(groupId.uuidString)"])
  let ivId = UUID()
  try database.execute(
    sql:
      "INSERT INTO investment_value (id, record_name, account_id, date, value, instrument_id) VALUES (?, ?, ?, '2024-01-01', 500, 'AUD')",
    arguments: [ivId, "IV|\(ivId.uuidString)", UUID()])
  let acctId = UUID()
  try database.execute(
    sql:
      "INSERT INTO account (id, record_name, name, type, instrument_id, position, is_hidden) VALUES (?, ?, 'Bank', 'bank', 'AUD', 0, 0)",
    arguments: [acctId, "Acct|\(acctId.uuidString)"])
}

// MARK: - Tests

@MainActor
@Suite("UnifiedIdentityMigration: per-profile FK rewrite")
struct UnifiedIdentityMigrationFkRewriteTests {
  /// Seeds one profile's database with one row in each of the six FK tables
  /// plus one account row with retired instrument ids, then verifies that
  /// `rewriteProfile` rewrites every column to the canonical id and sets
  /// `needs_push = 1` on every rewritten row.
  @Test("rewriteProfile rewrites every FK column to the canonical id and sets needs_push = 1")
  func rewritesAllFkColumns() async throws {
    let (harness, cache) = try makeProfileRewriteHarness()
    let profileId = UUID()
    let queue = try cache.database(for: profileId)
    try await queue.write { database in try seedRetiredRows(database) }
    try await harness.migration.rewriteProfile(
      profileId, mapping: ["10:native": "1:native", "8453:native": "1:native"])

    // All instrument_id FK columns point at the canonical id.
    let legIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM transaction_leg")
    }
    #expect(legIds == ["1:native"])
    let earmarkIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM earmark")
    }
    #expect(earmarkIds == ["1:native"])
    let savingsIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT savings_target_instrument_id FROM earmark")
    }
    #expect(savingsIds == ["1:native"])
    let ebiIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM earmark_budget_item")
    }
    #expect(ebiIds == ["1:native"])
    let groupIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM account_group")
    }
    #expect(groupIds == ["1:native"])
    let ivIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM investment_value")
    }
    #expect(ivIds == ["1:native"])
    let acctIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM account")
    }
    #expect(acctIds == ["1:native"])

    // needs_push = 1 on every rewritten row.
    let legNP = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT count(*) FROM transaction_leg WHERE needs_push = 1")
        ?? 0
    }
    #expect(legNP == 1)
    let emkNP = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT count(*) FROM earmark WHERE needs_push = 1") ?? 0
    }
    #expect(emkNP == 1)
    let ebiNP = try await queue.read { database in
      try Int.fetchOne(
        database, sql: "SELECT count(*) FROM earmark_budget_item WHERE needs_push = 1") ?? 0
    }
    #expect(ebiNP == 1)
    let grpNP = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT count(*) FROM account_group WHERE needs_push = 1")
        ?? 0
    }
    #expect(grpNP == 1)
    let ivNP = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT count(*) FROM investment_value WHERE needs_push = 1")
        ?? 0
    }
    #expect(ivNP == 1)
    let actNP = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT count(*) FROM account WHERE needs_push = 1") ?? 0
    }
    #expect(actNP == 1)
  }

  /// Rows whose `instrument_id` is NOT a key in the mapping must be left
  /// completely unchanged — `instrument_id` stays as-is and `needs_push`
  /// remains 0 (its default).
  @Test("rewriteProfile leaves rows not in mapping unchanged with needs_push untouched")
  func leavesUnmappedRowsUnchanged() async throws {
    let (harness, cache) = try makeProfileRewriteHarness()
    let profileId = UUID()
    let queue = try cache.database(for: profileId)
    try await queue.write { database in try seedUnmappedRows(database) }
    // 'AUD' is not in the mapping — no rows should be touched.
    try await harness.migration.rewriteProfile(profileId, mapping: ["10:native": "1:native"])

    // instrument_ids are unchanged.
    let legIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM transaction_leg")
    }
    #expect(legIds == ["AUD"])
    let earmarkIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM earmark")
    }
    #expect(earmarkIds == ["AUD"])
    let ebiIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM earmark_budget_item")
    }
    #expect(ebiIds == ["AUD"])
    let groupIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM account_group")
    }
    #expect(groupIds == ["AUD"])
    let ivIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM investment_value")
    }
    #expect(ivIds == ["AUD"])
    let acctIds = try await queue.read { database in
      try String.fetchAll(database, sql: "SELECT instrument_id FROM account")
    }
    #expect(acctIds == ["AUD"])

    // needs_push = 0 on every row — no rows were rewritten.
    let legNP = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT count(*) FROM transaction_leg WHERE needs_push = 1")
        ?? 0
    }
    #expect(legNP == 0)
    let emkNP = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT count(*) FROM earmark WHERE needs_push = 1") ?? 0
    }
    #expect(emkNP == 0)
    let ebiNP = try await queue.read { database in
      try Int.fetchOne(
        database, sql: "SELECT count(*) FROM earmark_budget_item WHERE needs_push = 1") ?? 0
    }
    #expect(ebiNP == 0)
    let grpNP = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT count(*) FROM account_group WHERE needs_push = 1")
        ?? 0
    }
    #expect(grpNP == 0)
    let ivNP = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT count(*) FROM investment_value WHERE needs_push = 1")
        ?? 0
    }
    #expect(ivNP == 0)
    let actNP = try await queue.read { database in
      try Int.fetchOne(database, sql: "SELECT count(*) FROM account WHERE needs_push = 1") ?? 0
    }
    #expect(actNP == 0)
  }
}
