import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — unavailable projection")
@MainActor
struct AnalysisStoreUnavailableProjectionTests {

  private func amt(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: .defaultTestInstrument)
  }

  @Test
  func categoryOverTimePointDefaultsToAvailable() {
    let point = CategoryOverTimePoint(
      month: "202503",
      monthDate: Date(),
      actualAmount: Decimal(100),
      percentage: 50.0
    )
    #expect(point.isUnavailable == false)
  }

  @Test
  func unavailableMonthMarksAllItsPoints() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202502",
        totalExpenses: amt(Decimal(-100))),
      ExpenseBreakdown(
        categoryId: catId, month: "202503",
        totalExpenses: amt(Decimal(-200)), hasUnavailableData: true),
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    let allPoints: [CategoryOverTimePoint] = result.reduce(into: []) { $0 += $1.points }
    for point in allPoints where point.month == "202503" {
      #expect(point.isUnavailable == true)
    }
    for point in allPoints where point.month == "202502" {
      #expect(point.isUnavailable == false)
    }
  }

  @Test
  func unavailableMonthMarksEveryCategoryEvenIfOnlyOneRowFlagged() {
    let cat1 = UUID()
    let cat2 = UUID()
    let breakdown = [
      // cat1's 202503 row carries the unavailable flag; cat2's does not,
      // yet both categories' 202503 points must be marked unavailable.
      ExpenseBreakdown(
        categoryId: cat1, month: "202503",
        totalExpenses: amt(Decimal(-100)), hasUnavailableData: true),
      ExpenseBreakdown(
        categoryId: cat2, month: "202503",
        totalExpenses: amt(Decimal(-50))),
    ]
    let categories = Categories(from: [
      Category(id: cat1, name: "Groceries"),
      Category(id: cat2, name: "Transport"),
    ])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    let allPoints: [CategoryOverTimePoint] = result.reduce(into: []) { $0 += $1.points }
    let pointsFor202503 = allPoints.filter { $0.month == "202503" }
    #expect(pointsFor202503.count == 2)
    let allUnavailable = pointsFor202503.allSatisfy { $0.isUnavailable }
    #expect(allUnavailable)
  }

  @Test
  func cleanBreakdownProducesNoUnavailablePoints() {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202502",
        totalExpenses: amt(Decimal(-100))),
      ExpenseBreakdown(
        categoryId: catId, month: "202503",
        totalExpenses: amt(Decimal(-200))),
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    let allPoints: [CategoryOverTimePoint] = result.reduce(into: []) { $0 += $1.points }
    let anyUnavailable = allPoints.contains { $0.isUnavailable }
    #expect(anyUnavailable == false)
  }
}
