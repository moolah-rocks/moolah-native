import Foundation
import GRDB
import Testing

@testable import Moolah

/// Symptom-A regression coverage for the reactive `ImportRuleStore`.
///
/// "Symptom A" is the bug that motivated the reactive-sync-refresh
/// rewrite: when CloudKit delivered a remote sync write, the rules
/// settings list would not refresh until the user pulled-to-refresh.
/// The reactive `ImportRuleStore` subscribes to
/// `repository.observeAll()` from `init`, so any GRDB write — local OR
/// sync-driven — propagates to the rules list without a manual reload.
/// These tests pin that contract.
@Suite("ImportRuleStore sync refresh", .serialized)
@MainActor
struct ImportRuleStoreSyncRefreshTests {

  private func rule(
    name: String = "rule",
    position: Int = 0,
    conditions: [RuleCondition] = [],
    actions: [RuleAction] = []
  ) -> ImportRule {
    ImportRule(name: name, position: position, conditions: conditions, actions: actions)
  }

  @Test("remote rule insert refreshes the store without manual refresh")
  func remoteRuleInsertRefreshesStore() async throws {
    let (backend, _) = try TestBackend.create()
    let store = ImportRuleStore(repository: backend.importRules)
    try await store.waitForFirstEmission()
    #expect(store.rules.isEmpty)

    _ = try await backend.importRules.create(rule(name: "Synced", position: 0))

    await expectEventually("rules has one rule named Synced") {
      store.rules.count == 1 && store.rules.first?.name == "Synced"
    }
  }

  @Test("stopObserving cancels the observation task")
  func stopObservingCancelsObservationTask() async throws {
    let (backend, _) = try TestBackend.create()
    let store = ImportRuleStore(repository: backend.importRules)
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

    _ = try await backend.importRules.create(rule(name: "After cancel", position: 0))
    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("GRDB wipes during sign-out reach the store before stopObserving cancels it")
  func signOutTeardownOrdering() async throws {
    let (backend, database) = try TestBackend.create()
    _ = try await backend.importRules.create(rule(name: "WillBeWiped", position: 0))
    let store = ImportRuleStore(repository: backend.importRules)
    try await store.waitForNextEmission(
      matching: { $0.rules.count == 1 },
      description: "store sees seeded rule"
    )

    // Simulate the sign-out path: GRDB wipes happen first, then
    // `stopObserving()` cancels the observation. The wipe-emission
    // must reach the store BEFORE cancellation, otherwise the user
    // would see the last-known-populated state frozen on screen until
    // they switched profiles or relaunched.
    try await database.write { connection in
      try connection.execute(sql: "DELETE FROM import_rule")
    }
    try await store.waitForNextEmission(
      matching: { $0.rules.isEmpty },
      description: "wipe propagated to store before cancellation",
      timeout: .seconds(2)
    )
    store.stopObserving()
    #expect(store.rules.isEmpty)
  }
}
