import Foundation
import Testing

@testable import Moolah

@Suite("Import-origin filter plan-pinning")
struct ImportOriginFilterPlanTests {
  @Test("import timestamp count uses transaction_by_import_origin")
  func importedAtCountUsesIndex() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT COUNT(*) FROM "transaction"
        WHERE recur_period IS NULL
          AND (import_origin_kind = 'single' OR import_origin_kind IS NULL)
          AND import_origin_imported_at >= ?
          AND import_origin_imported_at <= ?
        """,
      arguments: [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_000)])

    #expect(detail.contains("transaction_by_import_origin"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction"))
  }

  @Test("import timestamp page uses transaction_by_import_origin")
  func importedAtPageUsesIndex() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT * FROM "transaction"
        WHERE recur_period IS NULL
          AND (import_origin_kind = 'single' OR import_origin_kind IS NULL)
          AND import_origin_imported_at >= ?
          AND import_origin_imported_at <= ?
        ORDER BY date DESC, id ASC
        LIMIT ? OFFSET ?
        """,
      arguments: [
        Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: 1_000), 50, 0,
      ])

    #expect(detail.contains("transaction_by_import_origin"))
    // Filtering and display ordering use different indexes. Sorting the
    // selective imported subset is intentional and avoids scanning all
    // transactions in date order to discover matching imports.
    #expect(detail.contains("USE TEMP B-TREE FOR ORDER BY"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "transaction"))
  }
}
