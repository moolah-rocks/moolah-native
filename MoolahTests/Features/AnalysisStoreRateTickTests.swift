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
      conversionService: FakeConversionService.passthrough,
      defaults: try makeDefaults())
    store.setViewActive(true)
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
      repository: repository, conversionService: FakeConversionService.passthrough,
      defaults: try makeDefaults())
    store.setViewActive(true)
    // Hold the first reload on the gated repository so the burst lands
    // while it is unambiguously in flight.
    let first = Task { @MainActor in await store.reloadForRateTick() }
    await repository.waitUntilFetchStarted()
    // These three observe the in-flight reload and coalesce to a single
    // pending re-run. Each returns synchronously (no suspension) because
    // the in-flight load gate short-circuits a concurrent reload, so
    // awaiting them sequentially is deterministic.
    await store.reloadForRateTick()
    await store.reloadForRateTick()
    await store.reloadForRateTick()
    await repository.releaseAll()
    await first.value
    // Exactly one in-flight reload + one coalesced re-run.
    let count = await repository.loadAllCount
    #expect(count == 2)
  }

  @Test("rate ticks during the view's initial load coalesce to one reconcile")
  func ticksDuringInitialLoadCoalesce() async throws {
    let repository = GatedCountingAnalysisRepository()
    let store = AnalysisStore(
      repository: repository, conversionService: FakeConversionService.passthrough,
      defaults: try makeDefaults())
    store.setViewActive(true)
    // The view-initiated initial load is held at the gate, unambiguously
    // in flight. Rate ticks that land during it (the load fetching prices
    // writes the very cache `observeRates()` watches — the reload storm)
    // must coalesce into exactly ONE trailing reconcile, not spawn a fresh
    // full reload each. See #1163.
    let initial = Task { @MainActor in await store.loadAll() }
    await repository.waitUntilFetchStarted()
    await store.reloadForRateTick()
    await store.reloadForRateTick()
    await store.reloadForRateTick()
    await repository.releaseAll()
    await initial.value
    // Initial load (1) + one coalesced reconcile from the 3 ticks (1) = 2,
    // not 4 (which is what spawning a fresh reload per tick would give).
    let count = await repository.loadAllCount
    #expect(count == 2)
  }

  @Test("rate ticks during every pass stop after one quiesced cycle")
  func ticksDuringReconcileAreDebounced() async throws {
    let repository = FivePassGatedAnalysisRepository()
    let store = AnalysisStore(
      repository: repository, conversionService: FakeConversionService.passthrough,
      defaults: try makeDefaults(), rateRefreshDebounce: .zero)
    store.setViewActive(true)

    let initial = Task { @MainActor in await store.loadAll() }
    await repository.waitUntilFetchStarted(call: 1)
    await store.reloadForRateTick()
    await repository.release(call: 1)

    await repository.waitUntilFetchStarted(call: 2)
    await store.reloadForRateTick()
    await Task.yield()
    #expect(await repository.loadAllCount == 2)
    await repository.release(call: 2)
    await initial.value

    await repository.waitUntilFetchStarted(call: 3)
    await store.reloadForRateTick()
    await repository.release(call: 3)

    await repository.waitUntilFetchStarted(call: 4)
    await store.reloadForRateTick()
    await repository.release(call: 4)
    await store.waitForDeferredRateRefreshForTesting()

    let count = await repository.loadAllCount
    #expect(count == 4)
  }

  @Test("leaving Analysis cancels an in-flight quiesced refresh")
  func deactivationCancelsQuiescedRefresh() async throws {
    let repository = FivePassGatedAnalysisRepository()
    let store = AnalysisStore(
      repository: repository, conversionService: FakeConversionService.passthrough,
      defaults: try makeDefaults(), rateRefreshDebounce: .zero)
    store.setViewActive(true)

    let initial = Task { @MainActor in await store.loadAll() }
    await repository.waitUntilFetchStarted(call: 1)
    await store.reloadForRateTick()
    await repository.release(call: 1)
    await repository.waitUntilFetchStarted(call: 2)
    await store.reloadForRateTick()
    await repository.release(call: 2)
    await initial.value
    #expect(store.dailyBalances.first?.balance.quantity == 2)

    await repository.waitUntilFetchStarted(call: 3)
    await store.reloadForRateTick()
    await repository.release(call: 3)
    await repository.waitUntilFetchStarted(call: 4)

    store.setViewActive(false)
    store.setViewActive(true)
    let remount = Task { @MainActor in await store.loadAll() }
    #expect(store.dailyBalances.first?.balance.quantity == 3)
    await repository.release(call: 4)
    await repository.waitUntilFetchStarted(call: 5)
    #expect(store.dailyBalances.first?.balance.quantity == 3)
    await repository.release(call: 5)
    await remount.value
    #expect(await repository.loadAllCount == 5)
    #expect(store.dailyBalances.first?.balance.quantity == 5)
  }

  @Test("a rate-cache tick triggers a forced reload (initial tick ignored)")
  func rateTickDrivesReload() async throws {
    let repository = CountingAnalysisRepository()
    let conversion = FakeConversionService.passthrough  // emits an initial tick on subscribe
    let store = AnalysisStore(
      repository: repository, conversionService: conversion, defaults: try makeDefaults())
    store.setViewActive(true)
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

  @Test("a rate-cache tick waits until the Analysis view is active")
  func rateTickWaitsWhileViewIsInactive() async throws {
    let repository = CountingAnalysisRepository()
    let conversion = FakeConversionService.passthrough
    let store = AnalysisStore(
      repository: repository, conversionService: conversion, defaults: try makeDefaults())
    var ticks = store.testObservationTickStream.makeAsyncIterator()
    _ = await ticks.next()

    store.setViewActive(true)
    await store.loadAll()
    let baseline = await repository.loadAllCount
    store.setViewActive(false)

    conversion.emitRate()
    _ = await ticks.next()
    let whileInactive = await repository.loadAllCount
    #expect(whileInactive == baseline)

    store.setViewActive(true)
    await store.loadAll()
    let afterActivation = await repository.loadAllCount
    #expect(afterActivation == baseline + 1)
  }
}
