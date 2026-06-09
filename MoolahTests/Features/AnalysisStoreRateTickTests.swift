import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — rate-tick reload")
@MainActor
struct AnalysisStoreRateTickTests {

  private func makeDefaults() throws -> UserDefaults {
    let name = "com.moolah.test.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: name))
    defaults.removePersistentDomain(forName: name)
    return defaults
  }

  @Test("reloadForRateTick reloads even when the window is unchanged")
  func rateTickBypassesCacheGuard() async throws {
    let repository = CountingAnalysisRepository()
    let store = AnalysisStore(
      repository: repository,
      conversionService: StubConversionService(),
      defaults: try makeDefaults())
    await store.loadAll()  // initial load → count 1, cache populated
    let afterInitial = await repository.loadAllCount
    await store.reloadForRateTick()  // same window → would early-return without force
    let afterTick = await repository.loadAllCount
    #expect(afterTick == afterInitial + 1)
  }

  @Test("a burst of rate ticks during a reload coalesces to one extra reload")
  func burstCoalesces() async throws {
    let repository = GatedCountingAnalysisRepository()
    let store = AnalysisStore(
      repository: repository, conversionService: StubConversionService(),
      defaults: try makeDefaults())
    // Hold the first reload on the gated repository so the burst lands
    // while it is unambiguously in flight.
    let first = Task { @MainActor in await store.reloadForRateTick() }
    await repository.waitUntilFetchStarted()
    // These three observe the in-flight reload and coalesce to a single
    // pending re-run. Each returns synchronously (no suspension) because
    // `reloadForRateTick` short-circuits on `rateTickReloadInFlight`,
    // so awaiting them sequentially is deterministic.
    await store.reloadForRateTick()
    await store.reloadForRateTick()
    await store.reloadForRateTick()
    await repository.releaseAll()
    await first.value
    // Exactly one in-flight reload + one coalesced re-run.
    let count = await repository.loadAllCount
    #expect(count == 2)
  }

  @Test("a rate-cache tick triggers a forced reload (initial tick ignored)")
  func rateTickDrivesReload() async throws {
    let repository = CountingAnalysisRepository()
    let conversion = StubConversionService()  // emits an initial tick on subscribe
    let store = AnalysisStore(
      repository: repository, conversionService: conversion, defaults: try makeDefaults())
    // Single iterator over the store's deterministic observation-tick
    // seam: tick 1 = the on-subscribe emission (proves the init-spawned
    // observation task is live); tick 2 = the forced reload completing.
    var ticks = store.testObservationTickStream.makeAsyncIterator()
    _ = await ticks.next()  // await the on-subscribe tick (subscription live)

    await store.loadAll()
    let baseline = await repository.loadAllCount

    conversion.emitRate()  // a warm write landed
    _ = await ticks.next()  // await the triggered reload

    let after = await repository.loadAllCount
    #expect(after == baseline + 1)
  }
}
