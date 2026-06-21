import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the four SQL fetches that
/// drive `GRDBAnalysisRepository.fetchDailyBalances`: the per-day
/// account-dimension SUM, the per-day earmark-dimension SUM, and the
/// investment-value latest-as-of-day lookup. Same methodology as
/// `AnalysisAggregationPlanPinningTests`, different aggregation
/// surface.
///
/// **Temp B-tree GROUP/ORDER lines are accepted across this whole
/// file.** Every aggregation here groups and orders by
/// `day = DATE(t.date)` — a derived expression with no index keying,
/// so SQLite has no choice but to materialise the groups and the sort
/// in temp B-trees. Trying to forbid `USE TEMP B-TREE FOR GROUP BY` /
/// `USE TEMP B-TREE FOR ORDER BY` would force the planner away from
/// the leg-side / covering index entirely. The perf-critical signals
/// are the bare-SCAN rejection (`planHasFullTableScanOf`) and the
/// `USING COVERING INDEX` assertion where applicable. Each `@Test`
/// references this rationale rather than restating it.
@Suite("Daily-balance aggregation plan-pinning")
struct DailyBalancesPlanPinningTests {
  private func makeDatabase() throws -> DatabaseQueue {
    try PlanPinningTestHelpers.makeDatabase()
  }

  private func planDetail(
    _ database: DatabaseQueue, query: String, arguments: StatementArguments = []
  ) throws -> String {
    try PlanPinningTestHelpers.planDetail(database, query: query, arguments: arguments)
  }

  @Test("fetchDailyBalances per-day account-dimension SUM avoids a SCAN")
  func fetchDailyBalancesAccountDimensionAvoidsScan() throws {
    let database = try makeDatabase()
    // Mirrors the per-(day, account, instrument, type) aggregation that
    // drives the historic span of
    // `GRDBAnalysisRepository.fetchDailyBalances(after:forecastUntil:)`.
    // Restricted to non-scheduled legs with a non-null account id — the
    // earmark dimension is fetched by a sibling query.
    //
    // We do NOT assert `USING COVERING INDEX` here. The composite
    // `leg_analysis_by_type_account` covers the SELECT list, but
    // SQLite's planner picks the more selective partial
    // `leg_by_account` index for the `account_id IS NOT NULL` predicate
    // even though the composite would also work. Either index keeps the
    // read off a full table scan; the perf-critical signal is "no full
    // table scan on leg or transaction", which the alias-aware
    // `planHasFullTableScanOf` helper catches.
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)        AS day,
               MIN(t.date)         AS sample_date,
               leg.account_id      AS account_id,
               leg.instrument_id   AS instrument_id,
               leg.type            AS type,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND (:after IS NULL OR t.date >= :after)
          AND leg.account_id IS NOT NULL
        GROUP BY day, leg.account_id, leg.instrument_id, leg.type
        ORDER BY day ASC
        """,
      arguments: ["after": Date?.none])
    // Either of the leg-side indexes that narrow on `account_id IS NOT
    // NULL` is acceptable: the partial `leg_by_account` (planner's
    // typical choice on a quiescent table) and the covering composite
    // `leg_analysis_by_type_account` both keep the read off a full
    // scan.
    let usesAcceptableLegIndex =
      detail.contains("leg_by_account")
      || detail.contains("leg_analysis_by_type_account")
    #expect(usesAcceptableLegIndex)
    // SQLite emits `SCAN <alias>` for aliased FROM clauses — here
    // `transaction_leg leg`. Pin against the alias rather than the bare
    // table name (which would silently pass even on a full scan).
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
    // Temp B-tree GROUP/ORDER lines accepted — see file-header rationale.
  }

  @Test("fetchDailyBalances pre-cutoff account-dimension SUM avoids a SCAN")
  func fetchDailyBalancesAccountDimensionPreCutoffAvoidsScan() throws {
    let database = try makeDatabase()
    // Mirrors the pre-cutoff variant of the per-(day, account,
    // instrument, type) aggregation that seeds the `PositionBook` for
    // `GRDBAnalysisRepository.fetchDailyBalances(after:forecastUntil:)`.
    // Same shape as the post-cutoff query but with a `t.date < :after`
    // upper bound — pinned independently so a future planner regression
    // on either variant surfaces.
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)        AS day,
               MIN(t.date)         AS sample_date,
               leg.account_id      AS account_id,
               leg.instrument_id   AS instrument_id,
               leg.type            AS type,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND :after IS NOT NULL AND t.date < :after
          AND leg.account_id IS NOT NULL
        GROUP BY day, leg.account_id, leg.instrument_id, leg.type
        ORDER BY day ASC
        """,
      arguments: ["after": Date?.none])
    let usesAcceptableLegIndex =
      detail.contains("leg_by_account")
      || detail.contains("leg_analysis_by_type_account")
    #expect(usesAcceptableLegIndex)
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
    // Temp B-tree GROUP/ORDER lines accepted — see file-header rationale.
  }

  @Test("fetchDailyBalances per-day earmark-dimension SUM uses leg_analysis_by_earmark_type")
  func fetchDailyBalancesEarmarkDimensionUsesEarmarkIndex() throws {
    let database = try makeDatabase()
    // Sister of the account-dimension query: the same per-day SUM but
    // grouped by `(day, earmark_id, instrument_id, type)` and
    // restricted to non-null earmark legs. The earmark dimension is the
    // path that lights up the COVERING composite — the partial
    // `leg_analysis_by_earmark_type` indexes
    // `(earmark_id, type, instrument_id, transaction_id, quantity)` and
    // the WHERE/SELECT touch only those columns.
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)        AS day,
               MIN(t.date)         AS sample_date,
               leg.earmark_id      AS earmark_id,
               leg.instrument_id   AS instrument_id,
               leg.type            AS type,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND (:after IS NULL OR t.date >= :after)
          AND leg.earmark_id IS NOT NULL
        GROUP BY day, leg.earmark_id, leg.instrument_id, leg.type
        ORDER BY day ASC
        """,
      arguments: ["after": Date?.none])
    #expect(detail.contains("leg_analysis_by_earmark_type"))
    #expect(detail.contains("USING COVERING INDEX"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
    // Temp B-tree GROUP/ORDER lines accepted — see file-header rationale.
  }

  @Test("fetchDailyBalances pre-cutoff earmark-dimension SUM uses leg_analysis_by_earmark_type")
  func fetchDailyBalancesEarmarkDimensionPreCutoffUsesEarmarkIndex() throws {
    let database = try makeDatabase()
    // Pre-cutoff variant of the earmark-dimension SUM. Same shape as
    // the post-cutoff query, with the upper-bound predicate
    // `t.date < :after`. The partial composite
    // `leg_analysis_by_earmark_type` covers
    // `(earmark_id, type, instrument_id, transaction_id, quantity)`,
    // so the planner emits `USING COVERING INDEX` here too.
    let detail = try planDetail(
      database,
      query: """
        SELECT DATE(t.date)        AS day,
               MIN(t.date)         AS sample_date,
               leg.earmark_id      AS earmark_id,
               leg.instrument_id   AS instrument_id,
               leg.type            AS type,
               SUM(leg.quantity)   AS qty
        FROM transaction_leg leg
        JOIN "transaction"    t ON leg.transaction_id = t.id
        WHERE t.recur_period IS NULL
          AND :after IS NOT NULL AND t.date < :after
          AND leg.earmark_id IS NOT NULL
        GROUP BY day, leg.earmark_id, leg.instrument_id, leg.type
        ORDER BY day ASC
        """,
      arguments: ["after": Date?.none])
    #expect(detail.contains("leg_analysis_by_earmark_type"))
    #expect(detail.contains("USING COVERING INDEX"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
    // Temp B-tree GROUP/ORDER lines accepted — see file-header rationale.
  }

  @Test("fetchInvestmentAccountIds uses account_by_type")
  func fetchInvestmentAccountIdsUsesAccountByType() throws {
    let database = try makeDatabase()
    // Mirrors the per-account id loader driven by
    // `GRDBAnalysisRepository.fetchInvestmentAccountIds`. The
    // production SQL filters on an investment-like `type`
    // (`investmentLikeTypesSQLList`) AND `valuation_mode =
    // 'recordedValue'` so the snapshot fold only applies to
    // recorded-value investment-like accounts. The `account_by_type`
    // index keys on `(type)` and serves the selective type `IN` list
    // via per-value index seeks; the `valuation_mode` predicate filters
    // the candidate rows post-seek. SQLite emits `SEARCH account USING
    // INDEX account_by_type` for this shape, which is *not* a full
    // table scan.
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM account
        WHERE type IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
          AND valuation_mode = 'recordedValue'
        """)
    #expect(detail.contains("SEARCH account USING INDEX account_by_type"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "account"))
  }

  @Test("fetchTradesModeInvestmentAccountIds uses account_by_type")
  func fetchTradesModeInvestmentAccountIdsUsesAccountByType() throws {
    let database = try makeDatabase()
    // Mirrors the per-account id loader driven by
    // `GRDBAnalysisRepository.fetchTradesModeInvestmentAccountIds`. The
    // production SQL filters on an investment-like `type`
    // (`investmentLikeTypesSQLList`) AND `valuation_mode =
    // 'calculatedFromTrades'`. The `account_by_type` index keys on
    // `(type)` and serves the selective type `IN` list via per-value
    // index seeks; the `valuation_mode` predicate filters the candidate
    // rows post-seek. SQLite emits `SEARCH account USING INDEX
    // account_by_type` for this shape, which is *not* a full table
    // scan.
    let detail = try planDetail(
      database,
      query: """
        SELECT id FROM account
        WHERE type IN (\(GRDBAnalysisRepository.investmentLikeTypesSQLList))
          AND valuation_mode = 'calculatedFromTrades'
        """)
    #expect(detail.contains("SEARCH account USING INDEX account_by_type"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "account"))
  }

  @Test("fetchDailyBalances investment-value lookup uses iv_by_account_date_value")
  func fetchDailyBalancesInvestmentValuesUseAccountDateIndex() throws {
    let database = try makeDatabase()
    // Mirrors the per-account snapshot loader driven by
    // `GRDBAnalysisRepository.fetchDailyBalances`. The composite
    // `iv_by_account_date_value` covers `(account_id, date, value,
    // instrument_id)` so the SELECT list is served by the index —
    // SQLite emits `SCAN ... USING COVERING INDEX`, which is the
    // no-base-row read shape we want; that is *not* a full table scan
    // and `planHasFullTableScanOf` correctly distinguishes it from a
    // bare `SCAN`.
    //
    // Note: there is intentionally no `:after` lower bound on the
    // production query — the cursor walk in `applyInvestmentValues`
    // needs every historical snapshot so the most-recent pre-window
    // value can carry forward into the first in-window day.
    let detail = try planDetail(
      database,
      query: """
        SELECT account_id, date, value, instrument_id
        FROM investment_value
        ORDER BY account_id ASC, date ASC
        """)
    #expect(detail.contains("iv_by_account_date_value"))
    #expect(detail.contains("USING COVERING INDEX"))
    // No alias on `investment_value` here — pin the bare-table form
    // against the helper, which catches `SCAN investment_value` not
    // followed by ` USING `.
    #expect(
      !PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "investment_value"))
  }
}
