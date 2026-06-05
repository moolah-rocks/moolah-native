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
    let store = AnalysisStore(repository: repo, defaults: try makeDefaults())
    store.historyMonths = 12
    await store.loadAll()
    store.historyMonths = 3
    await store.loadAll()
    #expect(await repo.loadCount == 1)
  }

  @Test("widening beyond the cache refetches")
  func wideningRefetches() async throws {
    let repo = RecordingAnalysisRepository()
    let store = AnalysisStore(repository: repo, defaults: try makeDefaults())
    store.historyMonths = 12
    await store.loadAll()
    store.historyMonths = 60
    await store.loadAll()
    #expect(await repo.loadCount == 2)
  }

  @Test("a forecast-window change refetches")
  func forecastChangeRefetches() async throws {
    let repo = RecordingAnalysisRepository()
    let store = AnalysisStore(repository: repo, defaults: try makeDefaults())
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
    let store = AnalysisStore(repository: repo, defaults: try makeDefaults())
    store.historyMonths = 0
    await store.loadAll()
    #expect(await repo.lastAfter == nil)
    #expect(await repo.loadCount == 1)
  }
}
