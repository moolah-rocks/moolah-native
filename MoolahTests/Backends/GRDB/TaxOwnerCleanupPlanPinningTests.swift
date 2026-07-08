import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Tax owner cleanup plan-pinning")
struct TaxOwnerCleanupPlanPinningTests {
  @Test("owner reference cleanup uses owner-side indexes")
  func ownerReferenceCleanupUsesOwnerSideIndexes() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let ownerId = UUID()

    let accountDetail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT account_id, owner_id, position
        FROM account_tax_owner
        WHERE owner_id = ?
        """,
      arguments: [ownerId])
    #expect(accountDetail.contains("account_tax_owner_by_owner"))
    #expect(
      !PlanPinningTestHelpers.planHasFullTableScanOf(accountDetail, alias: "account_tax_owner"))

    let categoryDetail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT category_id, owner_id, position
        FROM category_tax_owner
        WHERE owner_id = ?
        """,
      arguments: [ownerId])
    #expect(categoryDetail.contains("category_tax_owner_by_owner"))
    #expect(
      !PlanPinningTestHelpers.planHasFullTableScanOf(categoryDetail, alias: "category_tax_owner"))
  }

  @Test("owner reference cleanup fetches only affected accounts and categories")
  func ownerReferenceCleanupFetchesOnlyAffectedRows() throws {
    let database = try PlanPinningTestHelpers.makeDatabase()
    let ownerId = UUID()

    let accountDetail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT a.id, a.tax_owner_ids_encoded
        FROM account_tax_owner ato
        JOIN account a ON a.id = ato.account_id
        WHERE ato.owner_id = ?
        """,
      arguments: [ownerId])
    #expect(accountDetail.contains("account_tax_owner_by_owner"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(accountDetail, alias: "ato"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(accountDetail, alias: "a"))

    let categoryDetail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT c.id, c.tax_owner_ids_encoded
        FROM category_tax_owner cto
        JOIN category c ON c.id = cto.category_id
        WHERE cto.owner_id = ?
        """,
      arguments: [ownerId])
    #expect(categoryDetail.contains("category_tax_owner_by_owner"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(categoryDetail, alias: "cto"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(categoryDetail, alias: "c"))
  }
}
