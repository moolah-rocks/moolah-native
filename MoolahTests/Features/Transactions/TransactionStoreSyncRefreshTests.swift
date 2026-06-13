import Foundation
import GRDB
import Testing

@testable import Moolah

/// Symptom-A regression coverage for the reactive `TransactionStore`.
///
/// "Symptom A" is the bug that motivated the reactive-sync-refresh
/// rewrite: when CloudKit delivered a remote sync write, the
/// per-account / scheduled-only / all-transactions list would not
/// refresh until the user pulled-to-refresh. The reactive
/// `TransactionStore` subscribes to `repository.observe(filter:...)`
/// (driven by the view's `.task(id: filter)`) and to
/// `conversionService.observeRates()` from `init`, so any GRDB write
/// — local OR sync-driven — propagates to the list without a manual
/// reload. These tests pin that contract.
@Suite("TransactionStore sync refresh", .serialized)
@MainActor
struct TransactionStoreSyncRefreshTests {

  private let accountId = UUID()

  @Test("remote transaction insert refreshes the store without manual refresh")
  func remoteTransactionInsertRefreshesStore() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    let filter = TransactionFilter(accountId: accountId)
    // Kick the subscription via load(filter:) so a long-lived
    // observation task is running for `filter`. The view-driven
    // `observe(filter:)` shape would be equivalent but blocks the
    // calling Task — load() returns after the first emission and
    // leaves the subscription running.
    await store.load(filter: filter)
    #expect(store.transactions.isEmpty)

    let remote = Transaction(
      date: Date(),
      payee: "Synced",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: -42,
          type: .expense
        )
      ]
    )
    _ = try await backend.transactions.create(remote)

    await expectEventually("store sees synced transaction") {
      store.transactions.count == 1
        && store.transactions.first?.transaction.payee == "Synced"
    }

    store.stopObserving()
  }

  @Test("stopObserving cancels the subscription task")
  func stopObservingCancelsObservationTask() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    let filter = TransactionFilter(accountId: accountId)
    await store.load(filter: filter)
    // Drain any ticks buffered between load() and the first
    // assertion so the post-cancel assertion only sees ticks that
    // arrive AFTER the backend write.
    await store.drainPendingEmissions()
    store.stopObserving()
    // See `EarmarkStoreSyncRefreshTests` for why we await termination —
    // `stopObserving()` only issues `Task.cancel()`; an in-flight
    // emission triggered by the following `create(...)` can race the
    // cancel under CI load.
    await store.awaitObservationTermination()

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "After cancel",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: .defaultTestInstrument,
            quantity: -10,
            type: .expense
          )
        ]
      ))
    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("observe(accountId:) drives the per-account subscription pattern")
  func observeAccountIdSubscribes() async throws {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )

    // Mirrors the .task(id: accountId) shape from views: the call
    // suspends until the surrounding Task is cancelled, so spawn it
    // detached and drive the assertions from the parent.
    let observeTask = Task { @MainActor in
      await store.observe(accountId: accountId)
    }
    defer { observeTask.cancel() }

    try await store.waitForFirstEmission()
    #expect(store.transactions.isEmpty)
    #expect(store.currentFilter.accountId == accountId)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "via observe(accountId:)",
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: .defaultTestInstrument,
            quantity: -25,
            type: .expense
          )
        ]
      ))
    await expectEventually("observe(accountId:) sees the new transaction") {
      store.transactions.count == 1
        && store.transactions.first?.transaction.payee == "via observe(accountId:)"
    }
  }

  @Test("GRDB wipes during sign-out reach the store before stopObserving cancels it")
  func signOutTeardownOrdering() async throws {
    let (backend, database) = try TestBackend.create()
    let seeded = Transaction(
      date: Date(),
      payee: "WillBeWiped",
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: -100,
          type: .expense
        )
      ]
    )
    _ = try await backend.transactions.create(seeded)

    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    await store.load(filter: TransactionFilter(accountId: accountId))
    try await store.waitForNextEmission(
      matching: { $0.transactions.count == 1 },
      description: "store sees seeded transaction"
    )

    // Simulate the sign-out path: GRDB wipes happen first, then
    // `stopObserving()` cancels the observation. The wipe-emission
    // must reach the store BEFORE cancellation, otherwise the user
    // would see the last-known-populated state frozen on screen until
    // they switched profiles or relaunched.
    try await database.write { connection in
      try connection.execute(sql: "DELETE FROM transaction_leg")
      try connection.execute(sql: "DELETE FROM \"transaction\"")
    }
    try await store.waitForNextEmission(
      matching: { $0.transactions.isEmpty },
      description: "wipe propagated to store before cancellation",
      timeout: .seconds(2)
    )
    store.stopObserving()
    #expect(store.transactions.isEmpty)
  }
}
