import Foundation
import GRDB
import Testing

@testable import Moolah

/// Symptom-A regression coverage for the reactive `InvestmentStore`.
///
/// "Symptom A" is the bug that motivated the reactive-sync-refresh
/// rewrite: when CloudKit delivered a remote sync write, the active
/// view would not refresh until the user pulled-to-refresh. The reactive
/// `InvestmentStore` subscribes to `repository.observeValues(...)`,
/// `repository.observeDailyBalances(...)`, `repository.observeErrors()`,
/// and `conversionService.observeRates()`/`...observeErrors()`. The
/// per-account streams (values + dailyBalances) come up via
/// `setActiveAccount(...)`; the always-on streams come up in `init`.
@Suite("InvestmentStore sync refresh", .serialized)
@MainActor
struct InvestmentStoreSyncRefreshTests {

  @Test("remote investment-value insert refreshes the store without manual refresh")
  func remoteInvestmentValueInsertRefreshesStore() async throws {
    let accountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      conversionService: FixedConversionService())

    // Activate the per-account subscription.
    store.setActiveAccount(accountId)
    try await store.waitForFirstEmission()
    #expect(store.values.isEmpty)
    await store.drainPendingEmissions()

    // Simulate a remote sync write directly through the repository.
    let amount = InstrumentAmount(quantity: dec("12345.00"), instrument: .defaultTestInstrument)
    try await backend.investments.setValue(
      accountId: accountId, date: Date(), value: amount)

    try await store.waitForNextEmission(
      matching: { $0.values.contains(where: { $0.value.quantity == dec("12345.00") }) },
      description: "values contains the remote-sync write"
    )
  }

  @Test("stopObserving cancels the observation tasks")
  func stopObservingCancelsObservation() async throws {
    let accountId = UUID()
    let (backend, _) = try TestBackend.create()
    let store = InvestmentStore(
      repository: backend.investments,
      conversionService: FixedConversionService())

    store.setActiveAccount(accountId)
    try await store.waitForFirstEmission()
    await store.drainPendingEmissions()
    store.stopObserving()
    // See `EarmarkStoreSyncRefreshTests` for why we await termination —
    // `stopObserving()` only issues `Task.cancel()`; an in-flight
    // emission triggered by the following `setValue(...)` can race the
    // cancel under CI load.
    await store.awaitObservationTermination()

    let amount = InstrumentAmount(quantity: dec("99.00"), instrument: .defaultTestInstrument)
    try await backend.investments.setValue(
      accountId: accountId, date: Date(), value: amount)
    let didEmit = await store.didEmitWithin(timeout: .milliseconds(200))
    #expect(didEmit == false)
  }

  @Test("setActiveAccount switches per-account subscription")
  func setActiveAccountSwitchesSubscription() async throws {
    let accountA = UUID()
    let accountB = UUID()
    let (backend, _) = try TestBackend.create()

    let amountA = InstrumentAmount(quantity: dec("100.00"), instrument: .defaultTestInstrument)
    try await backend.investments.setValue(
      accountId: accountA, date: Date(), value: amountA)
    let amountB = InstrumentAmount(quantity: dec("200.00"), instrument: .defaultTestInstrument)
    try await backend.investments.setValue(
      accountId: accountB, date: Date(), value: amountB)

    let store = InvestmentStore(
      repository: backend.investments,
      conversionService: FixedConversionService())

    store.setActiveAccount(accountA)
    try await store.waitForNextEmission(
      matching: { $0.values.first?.value.quantity == dec("100.00") },
      description: "store sees account A's value")

    store.setActiveAccount(accountB)
    try await store.waitForNextEmission(
      matching: { $0.values.first?.value.quantity == dec("200.00") },
      description: "store sees account B's value after switch")
  }
}
