// MoolahTests/App/UnifiedIdentityMigrationFkRewriteTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

// MARK: - Seeding helpers

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
    let legIds = try await fetchAll("SELECT instrument_id FROM transaction_leg", in: queue)
    #expect(legIds == ["1:native"])
    let earmarkIds = try await fetchAll("SELECT instrument_id FROM earmark", in: queue)
    #expect(earmarkIds == ["1:native"])
    let stIds = try await fetchAll(
      "SELECT savings_target_instrument_id FROM earmark", in: queue)
    #expect(stIds == ["1:native"])
    let ebiIds = try await fetchAll(
      "SELECT instrument_id FROM earmark_budget_item", in: queue)
    #expect(ebiIds == ["1:native"])
    let groupIds = try await fetchAll("SELECT instrument_id FROM account_group", in: queue)
    #expect(groupIds == ["1:native"])
    let ivIds = try await fetchAll("SELECT instrument_id FROM investment_value", in: queue)
    #expect(ivIds == ["1:native"])
    let acctIds = try await fetchAll("SELECT instrument_id FROM account", in: queue)
    #expect(acctIds == ["1:native"])

    // needs_push = 1 on every rewritten row.
    let legNP = try await needsPushCount("transaction_leg", in: queue)
    #expect(legNP == 1)
    let emkNP = try await needsPushCount("earmark", in: queue)
    #expect(emkNP == 1)
    let ebiNP = try await needsPushCount("earmark_budget_item", in: queue)
    #expect(ebiNP == 1)
    let grpNP = try await needsPushCount("account_group", in: queue)
    #expect(grpNP == 1)
    let ivNP = try await needsPushCount("investment_value", in: queue)
    #expect(ivNP == 1)
    let actNP = try await needsPushCount("account", in: queue)
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
    let legIds = try await fetchAll("SELECT instrument_id FROM transaction_leg", in: queue)
    #expect(legIds == ["AUD"])
    let earmarkIds = try await fetchAll("SELECT instrument_id FROM earmark", in: queue)
    #expect(earmarkIds == ["AUD"])
    let ebiIds = try await fetchAll(
      "SELECT instrument_id FROM earmark_budget_item", in: queue)
    #expect(ebiIds == ["AUD"])
    let groupIds = try await fetchAll("SELECT instrument_id FROM account_group", in: queue)
    #expect(groupIds == ["AUD"])
    let ivIds = try await fetchAll("SELECT instrument_id FROM investment_value", in: queue)
    #expect(ivIds == ["AUD"])
    let acctIds = try await fetchAll("SELECT instrument_id FROM account", in: queue)
    #expect(acctIds == ["AUD"])

    // needs_push = 0 on every row — no rows were rewritten.
    let legNP = try await needsPushCount("transaction_leg", in: queue)
    #expect(legNP == 0)
    let emkNP = try await needsPushCount("earmark", in: queue)
    #expect(emkNP == 0)
    let ebiNP = try await needsPushCount("earmark_budget_item", in: queue)
    #expect(ebiNP == 0)
    let grpNP = try await needsPushCount("account_group", in: queue)
    #expect(grpNP == 0)
    let ivNP = try await needsPushCount("investment_value", in: queue)
    #expect(ivNP == 0)
    let actNP = try await needsPushCount("account", in: queue)
    #expect(actNP == 0)
  }
}
