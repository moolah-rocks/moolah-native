import Foundation
import Testing

@testable import Moolah

/// Regression for the flaky `EarmarkStoreApplyDeltaTests` emission-wait timeout
/// (CI: "Timed out waiting for EarmarkStore emission matching seeded earmark
/// observed", iOS-only).
///
/// Root cause: a reactive store assigns its published state (`earmarks`)
/// **before** it yields its test-only observation tick — the tick fires only
/// **after** the intervening `recomputeConvertedTotals()`, which suspends in
/// the conversion layer. `waitForNextEmission(matching:)` parked on the tick
/// iterator and only polled the predicate as a *post-stream-finish* fallback,
/// so while the recompute was suspended (gated here; scheduler-starved on a
/// loaded CI runner) the awaited state was already present but no tick had
/// fired, and the wait timed out.
///
/// The fix races a concurrent predicate poll against the tick iterator, so the
/// already-true predicate is observed even when its tick is delayed.
@Suite("TestableStoreObservation -- waitForNextEmission race")
@MainActor
struct TestableStoreObservationRaceTests {

  @Test
  func waitForNextEmissionObservesStateSetBeforeItsTick() async throws {
    let aud = Instrument.AUD
    let earmark = Earmark(name: "Holiday", instrument: aud)
    let conversion = GatingConversionService()
    let store = EarmarkStore(
      repository: SilentEarmarkRepository(),
      conversionService: conversion,
      targetInstrument: aud,
      retryDelay: .seconds(60))

    // Park a value-wait for the earmark. `earmarks` is empty, so it cannot take
    // the fast path and must block inside the tick/poll race.
    let waiter = Task { @MainActor in
      try await store.waitForNextEmission(
        matching: { $0.earmarks.by(id: earmark.id) != nil },
        description: "earmark observed")
    }

    // Drive an empty apply first: it yields ticks (predicate still false) that
    // the waiter consumes and re-parks on the NEXT tick — guaranteeing it is
    // past the fast path and blocked awaiting a further tick.
    await store.apply(earmarks: [])
    for _ in 0..<50 { await Task.yield() }

    // Now set the matching state under a gated recompute: `apply` assigns
    // `earmarks` (predicate becomes TRUE), then suspends inside the gated
    // `convertResultBatch`, so NO tick is emitted for this apply.
    conversion.armGate()
    let applyTask = Task { @MainActor in await store.apply(earmarks: [earmark]) }
    await conversion.waitUntilGateReached()

    // The predicate is now true, but the tick is still pending behind the gate.
    // The concurrent poll must observe the state; without the fix the waiter
    // stays parked on the tick iterator and this `value` throws a timeout.
    try await waiter.value
    #expect(store.earmarks.by(id: earmark.id) != nil)

    // Release the gated recompute and tear down.
    conversion.releaseGate()
    await applyTask.value
    store.stopObserving()
    await store.awaitObservationTermination()
  }
}

/// A repository whose reactive streams finish immediately without emitting, so
/// a test drives `EarmarkStore.apply(earmarks:)` explicitly and controls tick
/// timing deterministically. No stored state, so `Sendable` is trivial.
private final class SilentEarmarkRepository {}

extension SilentEarmarkRepository: EarmarkRepository {
  func fetchAll() async throws -> [Earmark] { [] }
  func create(_ earmark: Earmark) async throws -> Earmark { earmark }
  func update(_ earmark: Earmark) async throws -> Earmark { earmark }
  func fetchBudget(earmarkId: UUID) async throws -> [EarmarkBudgetItem] { [] }
  func setBudget(earmarkId: UUID, categoryId: UUID, amount: InstrumentAmount) async throws {}
  nonisolated func observeAll() -> AsyncStream<[Earmark]> { AsyncStream { $0.finish() } }
  nonisolated func observeErrors() -> AsyncStream<any Error> { AsyncStream { $0.finish() } }
  nonisolated func observeBudget(earmarkId: UUID) -> AsyncStream<[EarmarkBudgetItem]> {
    AsyncStream { $0.finish() }
  }
}

extension SilentEarmarkRepository: Sendable {}
