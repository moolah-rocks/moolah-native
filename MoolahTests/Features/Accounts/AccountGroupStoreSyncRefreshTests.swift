import Foundation
import GRDB
import Testing

@testable import Moolah

/// Symptom-A regression coverage for the reactive `AccountGroupStore`,
/// mirroring `AccountStoreSyncRefreshTests`. The store subscribes to
/// `repository.observeAll()` from `init`, so any GRDB write — local OR
/// sync-driven — propagates to the sidebar without a manual reload, and
/// `stopObserving()` cleanly severs that propagation.
@Suite("AccountGroupStore sync refresh", .serialized)
@MainActor
struct AccountGroupStoreSyncRefreshTests {

  @Test("remote group insert refreshes the store without manual refresh")
  func remoteGroupInsertRefreshesStore() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForFirstEmission()
    #expect(store.groups.isEmpty)

    _ = try await backend.accountGroups.create(
      AccountGroup(name: "Synced", bucket: .investments, instrument: .defaultTestInstrument))

    await expectEventually("inserted group reaches the store") {
      store.groups.first?.name == "Synced"
    }

    store.stopObserving()
  }

  @Test("stopObserving cancels the observation task")
  func stopObservingCancelsObservationTask() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForFirstEmission()
    // Drain any ticks buffered between init and the first
    // `waitForFirstEmission` so the post-cancel assertion only sees ticks
    // that arrive AFTER the backend write.
    await store.drainPendingEmissions()
    store.stopObserving()
    // `stopObserving()` returns the moment `Task.cancel()` is issued; the
    // observation loops only notice cancellation on the next stream check.
    // Await termination so an in-flight emission can't race the cancel.
    await store.awaitObservationTermination()

    _ = try await backend.accountGroups.create(
      AccountGroup(name: "After cancel", bucket: .investments, instrument: .defaultTestInstrument))
    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("GRDB wipes during sign-out reach the store before stopObserving cancels it")
  func signOutTeardownOrdering() async throws {
    let (backend, database) = try TestBackend.create()
    _ = try await backend.accountGroups.create(
      AccountGroup(name: "WillBeWiped", bucket: .investments, instrument: .defaultTestInstrument))
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForNextEmission(
      matching: { $0.groups.count == 1 }, description: "store sees seeded group")

    // Simulate the sign-out path: GRDB wipes happen first, then
    // `stopObserving()` cancels the observation. The wipe-emission must
    // reach the store BEFORE cancellation, otherwise the user would see the
    // last-known-populated state frozen on screen until relaunch.
    try await database.write { connection in
      try connection.execute(sql: "DELETE FROM account_group")
    }
    try await store.waitForNextEmission(
      matching: { $0.groups.isEmpty },
      description: "wipe propagated to store before cancellation")
    store.stopObserving()
    #expect(store.groups.isEmpty)
  }
}
