import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — effective load window")
struct AnalysisStoreDisplayWindowTests {

  @Test("a narrow display filter still loads the insight floor")
  func narrowFilterLoadsFloor() {
    #expect(
      AnalysisStore.effectiveLoadMonths(
        historyMonths: 3, floorMonths: AnalysisStore.insightHistoryFloorMonths)
        == AnalysisStore.insightHistoryFloorMonths)
  }

  @Test("a wide display filter loads the wider window, not the floor")
  func wideFilterLoadsRequested() {
    #expect(
      AnalysisStore.effectiveLoadMonths(
        historyMonths: 60, floorMonths: AnalysisStore.insightHistoryFloorMonths)
        == 60)
  }

  @Test("All (0) loads everything")
  func allLoadsEverything() {
    #expect(
      AnalysisStore.effectiveLoadMonths(
        historyMonths: 0, floorMonths: AnalysisStore.insightHistoryFloorMonths)
        == Int.max)
  }
}

@Suite("AnalysisStore — display clipping")
struct AnalysisStoreClipTests {
  // 2026-06-15 anchor so month maths is deterministic.
  private let now = {
    var components = DateComponents()
    components.year = 2026
    components.month = 6
    components.day = 15
    return Calendar.current.date(from: components) ?? Date()
  }()

  private func breakdown(_ month: String) -> ExpenseBreakdown {
    ExpenseBreakdown(
      categoryId: UUID(), month: month,
      totalExpenses: InstrumentAmount(quantity: -100, instrument: .defaultTestInstrument))
  }

  private func cal(monthsFromNow: Int) -> Date {
    Calendar.current.date(byAdding: .month, value: monthsFromNow, to: now) ?? now
  }

  @Test("breakdown clips to the display window, keeping recent months")
  func clipsBreakdown() {
    let rows = ["202506", "202507", "202601", "202606"].map(breakdown)
    // 3-month display window from 2026-06 keeps 202603..202606 → only 202606.
    let clipped = AnalysisStore.clipBreakdown(rows, historyMonths: 3, now: now)
    #expect(clipped.map(\.month) == ["202606"])
  }

  @Test("breakdown All (0) returns everything")
  func clipsBreakdownAll() {
    let rows = ["202506", "202606"].map(breakdown)
    #expect(AnalysisStore.clipBreakdown(rows, historyMonths: 0, now: now).count == 2)
  }

  @Test("income/expense clips to the display window")
  func clipsIncomeExpense() {
    let rows = ["202506", "202606"].map {
      InsightTestSupport.monthly(month: $0, income: 0, expense: 0)
    }
    let clipped = AnalysisStore.clipIncomeExpense(rows, historyMonths: 3, now: now)
    #expect(clipped.map(\.month) == ["202606"])
  }

  @Test("income/expense All (0) returns everything")
  func clipsIncomeExpenseAll() {
    let rows = ["202506", "202606"].map {
      InsightTestSupport.monthly(month: $0, income: 0, expense: 0)
    }
    #expect(AnalysisStore.clipIncomeExpense(rows, historyMonths: 0, now: now).count == 2)
  }

  @Test("balances clip by date but always keep forecast rows")
  func clipsBalancesKeepingForecast() {
    let old = DailyBalance(
      date: cal(monthsFromNow: -10),
      balance: InstrumentAmount(quantity: 1, instrument: .defaultTestInstrument))
    let recent = DailyBalance(
      date: cal(monthsFromNow: -1),
      balance: InstrumentAmount(quantity: 2, instrument: .defaultTestInstrument))
    let forecast = DailyBalance(
      date: cal(monthsFromNow: 2),
      balance: InstrumentAmount(quantity: 3, instrument: .defaultTestInstrument),
      earmarked: .zero(instrument: .defaultTestInstrument),
      availableFunds: InstrumentAmount(quantity: 3, instrument: .defaultTestInstrument),
      investments: .zero(instrument: .defaultTestInstrument),
      investmentValue: nil,
      netWorth: InstrumentAmount(quantity: 3, instrument: .defaultTestInstrument),
      bestFit: nil,
      isForecast: true)
    let clipped = AnalysisStore.clipBalances(
      [old, recent, forecast], historyMonths: 3, now: now)
    // `old` (10 months back) drops; `recent` stays; `forecast` always stays.
    #expect(clipped.contains { $0.balance.quantity == 2 })
    #expect(clipped.contains { $0.balance.quantity == 3 })
    #expect(!clipped.contains { $0.balance.quantity == 1 })
  }

  @Test("balances All (0) returns everything including old rows")
  func clipsBalancesAll() {
    let old = DailyBalance(
      date: cal(monthsFromNow: -40),
      balance: InstrumentAmount(quantity: 1, instrument: .defaultTestInstrument))
    let recent = DailyBalance(
      date: cal(monthsFromNow: -1),
      balance: InstrumentAmount(quantity: 2, instrument: .defaultTestInstrument))
    #expect(AnalysisStore.clipBalances([old, recent], historyMonths: 0, now: now).count == 2)
  }
}

@Suite("AnalysisStore — load cache gate")
@MainActor
struct AnalysisStoreCacheGateTests {
  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("narrowing the display filter does not refetch")
  func narrowingDoesNotRefetch() async throws {
    let repo = RecordingAnalysisRepository()
    let store = AnalysisStore(
      repository: repo, conversionService: StubConversionService(), defaults: try makeDefaults())
    store.historyMonths = 12
    await store.loadAll()
    store.historyMonths = 3
    await store.loadAll()
    #expect(await repo.loadCount == 1)
  }

  @Test("widening beyond the cache refetches")
  func wideningRefetches() async throws {
    let repo = RecordingAnalysisRepository()
    let store = AnalysisStore(
      repository: repo, conversionService: StubConversionService(), defaults: try makeDefaults())
    store.historyMonths = 12
    await store.loadAll()
    store.historyMonths = 60
    await store.loadAll()
    #expect(await repo.loadCount == 2)
  }

  @Test("a forecast-window change refetches")
  func forecastChangeRefetches() async throws {
    let repo = RecordingAnalysisRepository()
    let store = AnalysisStore(
      repository: repo, conversionService: StubConversionService(), defaults: try makeDefaults())
    store.historyMonths = 12
    store.forecastMonths = 1
    await store.loadAll()
    store.forecastMonths = 3
    await store.loadAll()
    #expect(await repo.loadCount == 2)
  }

  @Test("All passes a nil history window to the repository")
  func allRequestsNilWindow() async throws {
    let repo = RecordingAnalysisRepository()
    let store = AnalysisStore(
      repository: repo, conversionService: StubConversionService(), defaults: try makeDefaults())
    store.historyMonths = 0
    await store.loadAll()
    #expect(await repo.lastAfter == nil)
    #expect(await repo.loadCount == 1)
  }

  @Test("displayed projection clips the loaded data by historyMonths, not forecastMonths")
  func displayedProjectionUsesHistoryMonths() async throws {
    // Year-2000 and year-2999 rows so the clip outcome is independent of wall-clock.
    let repo = RecordingAnalysisRepository(breakdown: [
      ExpenseBreakdown(
        categoryId: UUID(), month: "200001",
        totalExpenses: InstrumentAmount(quantity: -100, instrument: .defaultTestInstrument)),
      ExpenseBreakdown(
        categoryId: UUID(), month: "299912",
        totalExpenses: InstrumentAmount(quantity: -100, instrument: .defaultTestInstrument)),
    ])
    let store = AnalysisStore(
      repository: repo, conversionService: StubConversionService(), defaults: try makeDefaults())
    store.historyMonths = 0  // All
    await store.loadAll()
    // All keeps both rows — if `displayed*` wrongly used forecastMonths (1) it would
    // drop the year-2000 row.
    #expect(store.displayedExpenseBreakdown.count == 2)
    // Narrowing re-clips from the cached data with no reload — the year-2000 row drops.
    store.historyMonths = 12
    #expect(store.displayedExpenseBreakdown.map(\.month) == ["299912"])
    #expect(await repo.loadCount == 1)  // no refetch on narrowing
  }
}
