import Foundation
import Testing

@testable import Moolah

/// Pins the default valuation mode that `AccountStore.create(_:)` applies to
/// user-driven account creation. Investment accounts default to
/// `.calculatedFromTrades` so a freshly-created brokerage starts in
/// position-driven mode rather than the struct-default snapshot mode.
/// Migration writes go through `AccountRepository.update`, not `create`, so
/// they remain unaffected.
@Suite("AccountStore.create defaults investment accounts to calculatedFromTrades")
@MainActor
struct AccountStoreNewAccountDefaultTests {
  private func makeStore() throws -> (AccountStore, CloudKitBackend) {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    return (store, backend)
  }

  @Test("new investment account whose mode is the struct default → trades")
  func newInvestmentDefaultsToTrades() async throws {
    let (store, backend) = try makeStore()
    let saved = try await store.create(
      Account(name: "Brokerage", type: .investment, instrument: .defaultTestInstrument))

    let all = try await backend.accounts.fetchAll()
    let after = try #require(all.first { $0.id == saved.id })
    #expect(after.valuationMode == .calculatedFromTrades)
  }

  @Test("new bank account stays at recordedValue (the unread default)")
  func newBankUnchanged() async throws {
    let (store, backend) = try makeStore()
    let saved = try await store.create(
      Account(name: "Checking", type: .bank, instrument: .defaultTestInstrument))

    let all = try await backend.accounts.fetchAll()
    let after = try #require(all.first { $0.id == saved.id })
    #expect(after.valuationMode == .recordedValue)
  }

  @Test("explicit recordedValue on investment input is overridden to trades")
  func explicitRecordedOnInvestmentOverriddenToTrades() async throws {
    let (store, backend) = try makeStore()
    let saved = try await store.create(
      Account(
        name: "B",
        type: .investment,
        instrument: .defaultTestInstrument,
        valuationMode: .recordedValue))
    let all = try await backend.accounts.fetchAll()
    let after = try #require(all.first { $0.id == saved.id })
    #expect(after.valuationMode == .calculatedFromTrades)
  }
}
