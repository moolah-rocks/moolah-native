import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning for
/// `GRDBTransactionRepository.fetchCostBasisEventLegs()`. The perf-critical
/// signal is that neither the OUTER `leg` alias (the rows materialised to
/// Swift) nor the membership `nf` subquery is read via a bare full-table
/// scan.
///
/// The query mirrors the production `costBasisEventLegsSQL`, with the
/// non-fiat instrument-id membership rendered as a single `?` placeholder
/// (production interpolates the id collection, which GRDB expands to the
/// same `IN (?, ?, …)` bound-placeholder shape, so the plan is structurally
/// identical regardless of how many non-fiat instruments a profile has).
///
/// The observed plan drives from the membership list and probes both
/// tables by index:
///
///     SEARCH t USING INDEX sqlite_autoindex_transaction_1 (id=?)
///     LIST SUBQUERY 1
///     SCAN nf USING COVERING INDEX leg_analysis_by_type_category
///     SEARCH leg USING INDEX leg_by_transaction (transaction_id=?)
///     REUSE LIST SUBQUERY 1
///     USE TEMP B-TREE FOR ORDER BY
///
/// - The materialised outer `leg` rows ride `leg_by_transaction` — no bare
///   scan of the ~20k-row leg table.
/// - The membership subquery rides the full covering index
///   `leg_analysis_by_type_category` (full, not partial, since
///   `v21_leg_analysis_category_include_null`), so even null-category legs
///   qualify — never a bare table scan.
/// - `USE TEMP B-TREE FOR ORDER BY` is accepted: the plan drives by
///   transaction id (the membership list), so ordering by `t.date` has no
///   index to ride. Same rationale as the analysis-aggregation suites.
@Suite("fetchCostBasisEventLegs plan-pinning")
struct CostBasisEventLegsPlanPinningTests {
  private let query = """
    SELECT
        leg.transaction_id  AS transaction_id,
        leg.id              AS leg_id,
        t.date              AS date,
        leg.account_id      AS account_id,
        leg.instrument_id   AS instrument_id,
        leg.quantity        AS quantity,
        leg.type            AS type,
        leg.sort_order      AS sort_order,
        NULLIF(a.tax_owner_ids_encoded, '') AS owner_ids
    FROM transaction_leg leg
    JOIN "transaction" t ON leg.transaction_id = t.id
    LEFT JOIN account a ON leg.account_id = a.id
    WHERE t.recur_period IS NULL
      AND leg.transaction_id IN (
          SELECT nf.transaction_id
          FROM transaction_leg nf
          WHERE nf.instrument_id NOT IN (?)
      )
    ORDER BY t.date ASC, leg.transaction_id ASC, leg.sort_order ASC
    """

  @Test("both leg aliases are index-driven, not bare full scans")
  func legAliasesNotFullyScanned() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database, query: query, arguments: ["AUD"])
    // The outer `leg` (materialised rows) and the membership `nf`
    // subquery must both avoid a bare full-table scan of transaction_leg.
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "nf"))
    // The outer probe rides the FK index on `transaction_id`; the
    // membership subquery rides a covering index (never a base-row scan).
    #expect(detail.contains("leg_by_transaction"))
    #expect(detail.contains("USING COVERING INDEX"))
    #expect(detail.contains("sqlite_autoindex_account_1"))
    // Guard a future join-order regression onto the `t` alias (matches
    // every sibling analysis plan-pinning suite).
    #expect(!detail.contains("SCAN \"transaction\""))
  }
}
