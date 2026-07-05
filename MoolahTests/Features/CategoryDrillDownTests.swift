import Foundation
import Testing

@testable import Moolah

/// Covers `CategoryDrillDown.categoryIds(in:)` — the mapping from a
/// Reports drill-down to the set of category ids its transaction list
/// filters on. A subcategory row matches only its own category; a root
/// header (`includeDescendants`) covers the whole subtree so the drilled
/// list matches the aggregated header total.
struct CategoryDrillDownTests {
  private let now = Date(timeIntervalSince1970: 1_700_000_000)
  private var range: ClosedRange<Date> {
    now.addingTimeInterval(-86_400)...now
  }

  @Test
  func exactCategorySelectionMatchesOnlyThatCategory() {
    let income = Category(name: "Income")
    let salary = Category(name: "Salary", parentId: income.id)
    let categories = Categories(from: [income, salary])

    let drillDown = CategoryDrillDown(categoryId: salary.id, dateRange: range)

    #expect(drillDown.categoryIds(in: categories) == [salary.id])
  }

  @Test
  func includeDescendantsCoversTheWholeSubtree() {
    let income = Category(name: "Income")
    let salary = Category(name: "Salary", parentId: income.id)
    let bonus = Category(name: "Bonus", parentId: income.id)
    let janet = Category(name: "Janet", parentId: salary.id)
    let categories = Categories(from: [income, salary, bonus, janet])

    let drillDown = CategoryDrillDown(
      categoryId: income.id, dateRange: range, includeDescendants: true)

    #expect(
      drillDown.categoryIds(in: categories) == [income.id, salary.id, bonus.id, janet.id])
  }

  @Test
  func includeDescendantsOnALeafReturnsOnlyThatLeaf() {
    let groceries = Category(name: "Groceries")
    let categories = Categories(from: [groceries])

    let drillDown = CategoryDrillDown(
      categoryId: groceries.id, dateRange: range, includeDescendants: true)

    #expect(drillDown.categoryIds(in: categories) == [groceries.id])
  }
}
