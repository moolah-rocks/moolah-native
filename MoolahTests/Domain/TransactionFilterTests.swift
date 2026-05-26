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
}
