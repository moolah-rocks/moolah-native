import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — unavailable projection")
@MainActor
struct AnalysisStoreUnavailableProjectionTests {

  private func amt(_ quantity: Decimal) -> InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: .defaultTestInstrument)
  }

  // MARK: - Over-time projection excludes flagged rows

  @Test("over-time projection drops a flagged month's contribution")
  func overTimeExcludesUnavailableMonth() throws {
    let catId = UUID()
    let breakdown = [
      ExpenseBreakdown(
        categoryId: catId, month: "202502",
        totalExpenses: amt(Decimal(-100))),
      // 202503 is flagged: its surviving value is a convertible subset, so it
      // must contribute nothing to the projection.
      ExpenseBreakdown(
        categoryId: catId, month: "202503",
        totalExpenses: amt(Decimal(-200)), hasUnavailableData: true),
    ]
    let categories = Categories(from: [Category(id: catId, name: "Groceries")])

    let result = AnalysisStore.buildCategoriesOverTime(
      from: breakdown, categories: categories)

    let allPoints: [CategoryOverTimePoint] = result.reduce(into: []) { $0 += $1.points }
    // Only the available month survives; the flagged month produces no point/total.
    let months = Set(allPoints.map(\.month))
    #expect(months == ["202502"])
    let point202502 = try #require(allPoints.first { $0.month == "202502" })
    #expect(point202502.actualAmount == Decimal(100))
  }

  @Test("clean breakdown keeps every month in the projection")
  func cleanBreakdownKeepsAllMonths() {
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
    #expect(Set(allPoints.map(\.month)) == ["202502", "202503"])
  }

  // MARK: - Pie breakdown excludes flagged rows

  @Test("pie breakdown drops a flagged row's contribution")
  func pieExcludesUnavailableRow() {
    let cat1 = UUID()
    let cat2 = UUID()
    let breakdown = [
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

    let result = AnalysisStore.buildExpenseBreakdown(
      from: breakdown, categories: categories, selectedCategoryId: nil)

    // Only the available category survives; the flagged row contributes nothing.
    #expect(result.count == 1)
    #expect(result.first?.categoryId == cat2)
    #expect(result.first?.totalExpenses.quantity == Decimal(50))
  }

  // MARK: - Window-level signal

  @Test("displayedExpenseHasUnavailableData is true when a displayed row is flagged")
  func displayedFlagTrueWhenRowFlagged() async throws {
    // Year-2000 / 2999 rows so the "All" clip outcome is wall-clock independent.
    let repo = RecordingAnalysisRepository(breakdown: [
      ExpenseBreakdown(
        categoryId: UUID(), month: "200001",
        totalExpenses: amt(Decimal(-100)), hasUnavailableData: true),
      ExpenseBreakdown(
        categoryId: UUID(), month: "299912",
        totalExpenses: amt(Decimal(-50))),
    ])
    let store = AnalysisStore(
      repository: repo, conversionService: StubConversionService(), defaults: try makeDefaults())
    store.historyMonths = 0  // All — keep both rows in the displayed window.
    await store.loadAll()

    #expect(store.displayedExpenseHasUnavailableData == true)
  }

  @Test("displayedExpenseHasUnavailableData is false when no displayed row is flagged")
  func displayedFlagFalseWhenClean() async throws {
    let repo = RecordingAnalysisRepository(breakdown: [
      ExpenseBreakdown(
        categoryId: UUID(), month: "299912",
        totalExpenses: amt(Decimal(-50)))
    ])
    let store = AnalysisStore(
      repository: repo, conversionService: StubConversionService(), defaults: try makeDefaults())
    store.historyMonths = 0
    await store.loadAll()

    #expect(store.displayedExpenseHasUnavailableData == false)
  }

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }
}
