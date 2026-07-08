import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Tax income expense plan-pinning")
struct TaxIncomeExpensePlanPinningTests {
  @Test("fetchTaxIncomeExpense SQL avoids leg and transaction scans")
  func fetchTaxIncomeExpenseAvoidsHotPathScans() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT DATE(t.date) AS day,
               leg.instrument_id AS instrument_id,
               leg.type AS type,
               COALESCE(
                 NULLIF(c.tax_owner_ids_encoded, ''),
                 NULLIF(a.tax_owner_ids_encoded, ''),
                 ?
               ) AS owner_ids,
               SUM(leg.quantity) AS qty
        FROM transaction_leg leg
        JOIN "transaction" t ON leg.transaction_id = t.id
        JOIN category c ON leg.category_id = c.id
        LEFT JOIN account a ON leg.account_id = a.id
        WHERE t.recur_period IS NULL
          AND t.date >= ? AND t.date < ?
          AND c.is_tax_reportable = 1
          AND leg.type IN ('income', 'expense')
        GROUP BY DATE(t.date), leg.instrument_id, leg.type, owner_ids
        ORDER BY DATE(t.date) ASC, leg.type ASC
        """,
      arguments: [UUID().uuidString, Date(), Date().addingTimeInterval(86_400)])
    #expect(detail.contains("leg_analysis_by_type_category"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!detail.contains("SCAN \"transaction\""))
  }
}
