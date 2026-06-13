import Foundation
import GRDB
import Testing

@testable import Moolah

/// Symptom-A regression coverage for the reactive `CategoryStore`.
///
/// "Symptom A" is the bug that motivated the reactive-sync-refresh
/// rewrite: when CloudKit delivered a remote sync write, the sidebar /
/// list views would not refresh until the user pulled-to-refresh. The
/// reactive `CategoryStore` subscribes to `repository.observeAll()`
/// from `init`, so any GRDB write — local OR sync-driven — propagates
/// to the categories list without a manual reload. These tests pin
/// that contract.
@Suite("CategoryStore sync refresh", .serialized)
@MainActor
struct CategoryStoreSyncRefreshTests {

  @Test("remote category insert refreshes the store without manual refresh")
  func remoteCategoryInsertRefreshesStore() async throws {
    let (backend, _) = try TestBackend.create()
    let store = CategoryStore(repository: backend.categories)
    try await store.waitForFirstEmission()
    #expect(store.categories.roots.isEmpty)

    _ = try await backend.categories.create(
      Moolah.Category(name: "Synced")
    )

    await expectEventually("categories has one root named Synced") {
      store.categories.roots.count == 1
        && store.categories.roots.first?.name == "Synced"
    }
  }

  @Test("stopObserving cancels the observation task")
  func stopObservingCancelsObservationTask() async throws {
    let (backend, _) = try TestBackend.create()
    let store = CategoryStore(repository: backend.categories)
    try await store.waitForFirstEmission()
    // Drain any ticks buffered between init and the first
    // `waitForFirstEmission` so the post-cancel assertion only sees
    // ticks that arrive AFTER the backend write.
    await store.drainPendingEmissions()
    store.stopObserving()
    // See `EarmarkStoreSyncRefreshTests` for why we await termination —
    // `stopObserving()` only issues `Task.cancel()`; an in-flight
    // emission triggered by the following `create(...)` can race the
    // cancel under CI load.
    await store.awaitObservationTermination()

    _ = try await backend.categories.create(
      Moolah.Category(name: "After cancel")
    )
    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("GRDB wipes during sign-out reach the store before stopObserving cancels it")
  func signOutTeardownOrdering() async throws {
    let (backend, database) = try TestBackend.create()
    _ = try await backend.categories.create(
      Moolah.Category(name: "WillBeWiped")
    )
    let store = CategoryStore(repository: backend.categories)
    try await store.waitForNextEmission(
      matching: { $0.categories.roots.count == 1 },
      description: "store sees seeded category"
    )

    // Simulate the sign-out path: GRDB wipes happen first, then
    // `stopObserving()` cancels the observation. The wipe-emission
    // must reach the store BEFORE cancellation, otherwise the user
    // would see the last-known-populated state frozen on screen until
    // they switched profiles or relaunched.
    try await database.write { connection in
      try connection.execute(sql: "DELETE FROM category")
    }
    try await store.waitForNextEmission(
      matching: { $0.categories.roots.isEmpty },
      description: "wipe propagated to store before cancellation"
    )
    store.stopObserving()
    #expect(store.categories.roots.isEmpty)
  }
}
