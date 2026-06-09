import Foundation
import Testing

@testable import Moolah

@Suite("CategoriesOverTimeCard — hasUnavailable")
struct CategoriesOverTimeCardUnavailableTests {

  private func point(_ month: String, isUnavailable: Bool) -> CategoryOverTimePoint {
    CategoryOverTimePoint(
      month: month,
      monthDate: Date(timeIntervalSince1970: 0),
      actualAmount: 100,
      percentage: 25,
      isUnavailable: isUnavailable
    )
  }

  private func entry(_ points: [CategoryOverTimePoint]) -> CategoryOverTimeEntry {
    CategoryOverTimeEntry(categoryId: UUID(), points: points, totalAmount: 100)
  }

  @Test
  func emptyEntriesAreAvailable() {
    #expect(CategoriesOverTimeCard.hasUnavailable(in: []) == false)
  }

  @Test
  func allAvailablePointsReturnFalse() {
    let entries = [
      entry([point("202604", isUnavailable: false), point("202605", isUnavailable: false)]),
      entry([point("202604", isUnavailable: false)]),
    ]
    #expect(CategoriesOverTimeCard.hasUnavailable(in: entries) == false)
  }

  @Test
  func anyUnavailablePointReturnsTrue() {
    let entries = [
      entry([point("202604", isUnavailable: false)]),
      entry([point("202604", isUnavailable: false), point("202605", isUnavailable: true)]),
    ]
    #expect(CategoriesOverTimeCard.hasUnavailable(in: entries) == true)
  }
}
