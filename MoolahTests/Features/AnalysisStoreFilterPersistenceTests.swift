import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — filter persistence")
@MainActor
struct AnalysisStoreFilterPersistenceTests {

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("defaults to historyMonths=12 and forecastMonths=1 with no saved values")
  func defaultValues() throws {
    let (backend, _) = try TestBackend.create()
    let store = AnalysisStore(
      repository: backend.analysis, conversionService: backend.conversionService,
      defaults: try makeDefaults())
    #expect(store.historyMonths == 12)
    #expect(store.forecastMonths == 1)
  }

  @Test("persists historyMonths across instances")
  func historyMonthsPersists() throws {
    let defaults = try makeDefaults()

    let (backend1, _) = try TestBackend.create()
    let store1 = AnalysisStore(
      repository: backend1.analysis, conversionService: backend1.conversionService,
      defaults: defaults)
    store1.historyMonths = 6

    let (backend2, _) = try TestBackend.create()
    let store2 = AnalysisStore(
      repository: backend2.analysis, conversionService: backend2.conversionService,
      defaults: defaults)
    #expect(store2.historyMonths == 6)
  }

  @Test("persists forecastMonths across instances")
  func forecastMonthsPersists() throws {
    let defaults = try makeDefaults()

    let (backend1, _) = try TestBackend.create()
    let store1 = AnalysisStore(
      repository: backend1.analysis, conversionService: backend1.conversionService,
      defaults: defaults)
    store1.forecastMonths = 3

    let (backend2, _) = try TestBackend.create()
    let store2 = AnalysisStore(
      repository: backend2.analysis, conversionService: backend2.conversionService,
      defaults: defaults)
    #expect(store2.forecastMonths == 3)
  }

  @Test("forecastMonths=0 (None) persists correctly")
  func forecastMonthsZeroPersists() throws {
    let defaults = try makeDefaults()

    let (backend1, _) = try TestBackend.create()
    let store1 = AnalysisStore(
      repository: backend1.analysis, conversionService: backend1.conversionService,
      defaults: defaults)
    store1.forecastMonths = 0

    let (backend2, _) = try TestBackend.create()
    let store2 = AnalysisStore(
      repository: backend2.analysis, conversionService: backend2.conversionService,
      defaults: defaults)
    #expect(store2.forecastMonths == 0)
  }
}

@Suite("AnalysisStore — refreshIfStale")
@MainActor
struct AnalysisStoreRefreshIfStaleTests {

  private func makeDefaults() throws -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  @Test("loads when no data has been loaded yet")
  func loadsWhenNoDataLoaded() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AnalysisStore(
      repository: backend.analysis, conversionService: backend.conversionService,
      defaults: try makeDefaults())

    #expect(store.lastLoadedAt == nil)
    await store.refreshIfStale(minimumInterval: 60)
    #expect(store.lastLoadedAt != nil)
  }

  @Test("reloads when elapsed time exceeds minimum interval")
  func reloadsWhenStale() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AnalysisStore(
      repository: backend.analysis, conversionService: backend.conversionService,
      defaults: try makeDefaults())

    await store.loadAll()
    let firstLoad = store.lastLoadedAt
    #expect(firstLoad != nil)

    // Simulate a stale load by rewinding lastLoadedAt.
    let staleDate = Date().addingTimeInterval(-120)
    store.overrideLastLoadedAtForTesting(staleDate)

    await store.refreshIfStale(minimumInterval: 60)
    let reloadedAt = try #require(store.lastLoadedAt)
    #expect(reloadedAt > staleDate)
  }

  @Test("skips reload when elapsed time is within minimum interval")
  func skipsReloadWhenFresh() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AnalysisStore(
      repository: backend.analysis, conversionService: backend.conversionService,
      defaults: try makeDefaults())

    await store.loadAll()
    let firstLoad = store.lastLoadedAt
    #expect(firstLoad != nil)

    await store.refreshIfStale(minimumInterval: 60)
    // Should NOT have reloaded — timestamp unchanged.
    #expect(store.lastLoadedAt == firstLoad)
  }

  @Test("loadAll updates lastLoadedAt on success")
  func loadAllUpdatesTimestampOnSuccess() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AnalysisStore(
      repository: backend.analysis, conversionService: backend.conversionService,
      defaults: try makeDefaults())

    #expect(store.lastLoadedAt == nil)
    await store.loadAll()
    #expect(store.lastLoadedAt != nil)
  }
}
