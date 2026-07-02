// MoolahTests/App/UnifiedIdentityRewritePlanPinningTests.swift

import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the seven FK-rewrite UPDATEs in
/// `UnifiedInstrumentIdentityMigration.rewriteStatements`.
///
/// Each UPDATE issues `WHERE instrument_id = ?` (or
/// `WHERE savings_target_instrument_id = ?`) against a table that has no
/// leading `instrument_id` index, so SQLite plans a full-table SCAN.
///
/// **The SCAN is intentional and correct for this workload.** The migration
/// runs once per profile, rewrites a small number of instruments (typically
/// two or three cross-chain ETH ids → one canonical id), and then never
/// executes again. Reasons no index is warranted:
///
/// - Adding a permanent `CREATE INDEX ON <table> (instrument_id)` solely for
///   a one-shot migration incurs ongoing index-maintenance overhead on every
///   future INSERT/UPDATE/DELETE across those six tables, with zero benefit
///   once the migration is complete.
/// - Adding a v19 migrator step to create and then immediately drop the index
///   is worse still: a transient-index migrator complicates schema history,
///   cannot be undone cleanly, and buys nothing over a bare SCAN on a table
///   that fits in a single page for most users.
/// - The per-profile `write` transaction for this migration is batched with
///   `cachedStatement` (DATABASE_CODE_GUIDE §4) so it stays fast even without
///   an index.
///
/// These plan-pins document and guard the decision. If a future reviewer
/// requires seek indexes, that is a separate ProfileSchema migration step that
/// adds `CREATE INDEX ON <table> (instrument_id)` on all six tables — a new
/// migrator step is not in scope for the unified-identity migration.
@Suite("UnifiedIdentityMigration: rewrite UPDATE query plans (intentional full-table SCAN)")
struct UnifiedIdentityRewritePlanPinningTests {

  // MARK: - transaction_leg

  @Test("transaction_leg instrument_id UPDATE is an intentional full-table SCAN (no index)")
  func transactionLegInstrumentIdScan() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: "UPDATE transaction_leg SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
      arguments: ["1:native", "10:native"])
    // No instrument_id index on transaction_leg — SCAN is the expected and
    // intentional plan for this one-shot migration. See suite-level doc.
    #expect(PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction_leg"))
  }

  // MARK: - earmark (instrument_id)

  @Test("earmark instrument_id UPDATE is an intentional full-table SCAN (no index)")
  func earmarkInstrumentIdScan() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: "UPDATE earmark SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
      arguments: ["1:native", "10:native"])
    // No instrument_id index on earmark — intentional SCAN. See suite-level doc.
    #expect(PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "earmark"))
  }

  // MARK: - earmark (savings_target_instrument_id)

  @Test("earmark savings_target UPDATE is an intentional full-table SCAN (no index)")
  func earmarkSavingsTargetScan() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        UPDATE earmark SET savings_target_instrument_id = ?, needs_push = 1 \
        WHERE savings_target_instrument_id = ?
        """,
      arguments: ["1:native", "8453:native"])
    // No savings_target_instrument_id index on earmark — intentional SCAN.
    // This legacy column is rewritten for correctness even though toDomain()
    // currently ignores it. See suite-level doc.
    #expect(PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "earmark"))
  }

  // MARK: - earmark_budget_item

  @Test("earmark_budget_item instrument_id UPDATE is an intentional full-table SCAN (no index)")
  func earmarkBudgetItemInstrumentIdScan() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query:
        "UPDATE earmark_budget_item SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
      arguments: ["1:native", "10:native"])
    // No instrument_id index on earmark_budget_item — intentional SCAN.
    #expect(PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "earmark_budget_item"))
  }

  // MARK: - account_group

  @Test("account_group instrument_id UPDATE is an intentional full-table SCAN (no index)")
  func accountGroupInstrumentIdScan() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: "UPDATE account_group SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
      arguments: ["1:native", "10:native"])
    // No instrument_id index on account_group — intentional SCAN.
    #expect(PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "account_group"))
  }

  // MARK: - investment_value

  @Test("investment_value instrument_id UPDATE is an intentional full-table SCAN (no index)")
  func investmentValueInstrumentIdScan() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query:
        "UPDATE investment_value SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
      arguments: ["1:native", "10:native"])
    // No instrument_id index on investment_value — intentional SCAN.
    #expect(PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "investment_value"))
  }

  // MARK: - account (defensive)

  @Test("account instrument_id UPDATE is an intentional full-table SCAN (no index)")
  func accountInstrumentIdScan() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: "UPDATE account SET instrument_id = ?, needs_push = 1 WHERE instrument_id = ?",
      arguments: ["1:native", "10:native"])
    // No instrument_id index on account — intentional SCAN. This is a
    // defensive rewrite: account.instrument_id is normally a fiat denomination
    // but the schema does not enforce it. See suite-level doc.
    #expect(PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "account"))
  }
}
