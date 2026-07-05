import Foundation
import Testing

@testable import Moolah

@Suite("TransactionFilter Tests")
struct TransactionFilterTests {

  @Test("Empty filter has no active filters")
  func testEmptyFilterHasNoActiveFilters() {
    let filter = TransactionFilter()
    #expect(filter.hasActiveFilters == false)
  }

  @Test("Filter with accountId is active")
  func testFilterWithAccountIdIsActive() {
    let filter = TransactionFilter(accountId: UUID())
    #expect(filter.hasActiveFilters == true)
  }

  @Test("Filter with dateRange is active")
  func testFilterWithDateRangeIsActive() {
    let now = Date()
    let filter = TransactionFilter(dateRange: now...now.addingTimeInterval(86400))
    #expect(filter.hasActiveFilters == true)
  }

  @Test("Filter with categoryIds is active")
  func testFilterWithCategoryIdsIsActive() {
    let filter = TransactionFilter(categoryIds: [UUID()])
    #expect(filter.hasActiveFilters == true)
  }

  @Test("Filter with payee is active")
  func testFilterWithPayeeIsActive() {
    let filter = TransactionFilter(payee: "Coffee Shop")
    #expect(filter.hasActiveFilters == true)
  }

  @Test("Filter with uncategorisedLegType is active")
  func testFilterWithUncategorizedLegTypeIsActive() {
    let filter = TransactionFilter(uncategorisedLegType: .expense)
    #expect(filter.hasActiveFilters == true)
  }

  @Test("Filter with non-empty accountIds is active")
  func testFilterWithAccountIdsIsActive() {
    let filter = TransactionFilter(accountIds: [UUID()])
    #expect(filter.hasActiveFilters == true)
    #expect(filter.hasAccountFilter == true)
  }

  @Test("Filter with empty accountIds set is inactive")
  func testFilterWithEmptyAccountIdsIsInactive() {
    let filter = TransactionFilter(accountIds: Set<UUID>())
    #expect(filter.hasActiveFilters == false)
    #expect(filter.hasAccountFilter == false)
  }

  @Test("hasAccountFilter is true for single accountId and false otherwise")
  func testHasAccountFilter() {
    #expect(TransactionFilter().hasAccountFilter == false)
    #expect(TransactionFilter(accountId: UUID()).hasAccountFilter == true)
    #expect(TransactionFilter(accountIds: [UUID(), UUID()]).hasAccountFilter == true)
  }

  // MARK: - scopedAccountIds

  @Test("Empty selection in a group resolves to the whole group scope")
  func testEmptySelectionResolvesToScope() {
    let idA = UUID()
    let idB = UUID()
    let idC = UUID()
    let scope: Set<UUID> = [idA, idB, idC]
    let resolved = TransactionFilter.scopedAccountIds(
      forSelection: [], scope: scope, available: scope)
    #expect(resolved == scope)
  }

  @Test("Selecting every available account resolves to the scope (treated as all)")
  func testAllSelectedResolvesToScope() {
    let idA = UUID()
    let idB = UUID()
    let idC = UUID()
    let scope: Set<UUID> = [idA, idB, idC]
    let resolved = TransactionFilter.scopedAccountIds(
      forSelection: [idA, idB, idC], scope: scope, available: scope)
    #expect(resolved == scope)
  }

  @Test("A strict subset narrows to that subset")
  func testSubsetSelectionNarrows() {
    let idA = UUID()
    let idB = UUID()
    let idC = UUID()
    let scope: Set<UUID> = [idA, idB, idC]
    let resolved = TransactionFilter.scopedAccountIds(
      forSelection: [idA], scope: scope, available: scope)
    #expect(resolved == [idA])
  }

  @Test("Empty selection in the global list stays empty (all accounts)")
  func testEmptySelectionGlobalStaysEmpty() {
    let idA = UUID()
    let idB = UUID()
    let resolved = TransactionFilter.scopedAccountIds(
      forSelection: [], scope: [], available: [idA, idB])
    #expect(resolved.isEmpty)
  }

  @Test("A subset in the global list narrows to that subset")
  func testSubsetSelectionGlobalNarrows() {
    let idA = UUID()
    let idB = UUID()
    let resolved = TransactionFilter.scopedAccountIds(
      forSelection: [idA], scope: [], available: [idA, idB])
    #expect(resolved == [idA])
  }
}
