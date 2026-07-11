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
        SELECT t.date AS transaction_date,
               leg.category_id AS category_id,
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
        GROUP BY t.date, leg.category_id, leg.instrument_id, leg.type, owner_ids
        ORDER BY t.date ASC, leg.category_id ASC, leg.type ASC
        """,
      arguments: [UUID().uuidString, Date(), Date().addingTimeInterval(86_400)])
    #expect(detail.contains("leg_analysis_by_type_category"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "leg"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "t"))
    // The query groups by tax dimensions after filtering by reportable
    // category/type. The useful index work is the leg/category/date probe
    // above; materialising grouped rows in a temp B-tree is accepted so the
    // planner does not abandon those selective probes for a worse scan.
    #expect(detail.contains("USE TEMP B-TREE FOR GROUP BY"))
  }

  @Test("tax income details group rows before display")
  func taxIncomeDetailsGroupRowsBeforeDisplay() async throws {
    let fixture = try await makeTaxIncomeFixture()
    let owner = UUID()
    let category = try await fixture.categories.create(
      Moolah.Category(name: "Interest", isTaxReportable: true, taxOwnerIds: [owner]))
    _ = try await fixture.accounts.create(fixture.account)
    try await insertTaxTransaction(
      fixture.database,
      accountId: fixture.account.id,
      legs: [TaxTestLeg(10, .income, category.id)])
    try await insertTaxTransaction(
      fixture.database,
      accountId: fixture.account.id,
      payee: "Second row",
      legs: [TaxTestLeg(20, .income, category.id)])

    let rows = try await fixture.analysis.fetchTaxIncomeExpenseDetails(
      dateInterval: fixture.date..<fixture.date.addingTimeInterval(1),
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner,
      ownerId: owner,
      type: .income)

    let row = try #require(rows.first)
    #expect(rows.count == 1)
    #expect(row.ownerId == owner)
    #expect(row.categoryId == category.id)
    #expect(row.amount?.quantity == 30)
  }
}
