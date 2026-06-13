import Foundation
import GRDB
import Testing

@testable import Moolah

/// Symptom-A regression coverage for the reactive `EarmarkStore`.
///
/// "Symptom A" is the bug that motivated the reactive-sync-refresh
/// rewrite: when CloudKit delivered a remote sync write, the sidebar
/// would not refresh until the user pulled-to-refresh. The reactive
/// `EarmarkStore` subscribes to `repository.observeAll()` and
/// `conversionService.observeRates()` from `init`, so any GRDB write —
/// local OR sync-driven — propagates to the sidebar without a manual
/// reload. These tests pin that contract.
@Suite("EarmarkStore sync refresh", .serialized)
@MainActor
struct EarmarkStoreSyncRefreshTests {

  @Test("remote earmark insert refreshes the store without manual refresh")
  func remoteEarmarkInsertRefreshesStore() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()
    #expect(store.earmarks.ordered.isEmpty)

    _ = try await backend.earmarks.create(
      Earmark(name: "Synced", instrument: .defaultTestInstrument)
    )

    await expectEventually("remote insert refreshes the store with the synced earmark") {
      store.earmarks.count == 1 && store.earmarks.ordered.first?.name == "Synced"
    }
  }

  @Test("stopObserving cancels the observation task")
  func stopObservingCancelsObservationTask() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForFirstEmission()
    // Drain any ticks buffered between init and the first
    // `waitForFirstEmission` so the post-cancel assertion only sees
    // ticks that arrive AFTER the backend write.
    await store.drainPendingEmissions()
    store.stopObserving()
    // `stopObserving()` returns the moment `Task.cancel()` is issued;
    // the observation task's `for await` loops only notice cancellation
    // on the next stream check, so an in-flight emission triggered by
    // the following `create(...)` can race the cancel under CI load
    // and a 200 ms `didEmitWithin` window then flakes. Awaiting
    // termination makes the cancel deterministic.
    await store.awaitObservationTermination()

    _ = try await backend.earmarks.create(
      Earmark(name: "After cancel", instrument: .defaultTestInstrument)
    )
    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("GRDB wipes during sign-out reach the store before stopObserving cancels it")
  func signOutTeardownOrdering() async throws {
    let (backend, database) = try TestBackend.create()
    _ = try await backend.earmarks.create(
      Earmark(name: "WillBeWiped", instrument: .defaultTestInstrument)
    )
    let store = EarmarkStore(
      repository: backend.earmarks,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument
    )
    try await store.waitForNextEmission(
      matching: { $0.earmarks.count == 1 },
      description: "store sees seeded earmark"
    )

    // Simulate the sign-out path: GRDB wipes happen first, then
    // `stopObserving()` cancels the observation. The wipe-emission
    // must reach the store BEFORE cancellation, otherwise the user
    // would see the last-known-populated state frozen on screen until
    // they switched profiles or relaunched.
    try await database.write { connection in
      try connection.execute(sql: "DELETE FROM earmark")
    }
    try await store.waitForNextEmission(
      matching: { $0.earmarks.ordered.isEmpty },
      description: "wipe propagated to store before cancellation"
    )
    store.stopObserving()
    #expect(store.earmarks.ordered.isEmpty)
  }
}
