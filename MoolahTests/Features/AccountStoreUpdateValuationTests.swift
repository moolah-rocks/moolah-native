import Foundation
import Testing

@testable import Moolah

/// Pins that edits cannot reintroduce the retired runtime valuation mode.
@Suite("AccountStore.update valuation canonicalization")
@MainActor
struct AccountStoreUpdateValuationTests {
  @Test("changing valuationMode and saving persists via the store")
  func picksAndSavesNewMode() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(
      name: "Brokerage", type: .investment, balance: 0,
      valuationMode: .recordedValue, in: database)
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: original.id) != nil },
      description: "seeded account observed"
    )

    // Mirror EditAccountView.save(): copy the account, assign the picker's
    // value, then hand it to the store.
    var updated = original
    updated.valuationMode = .calculatedFromTrades
    let saved = try await store.update(updated)

    #expect(saved.valuationMode == .calculatedFromTrades)
    let fetched = try await backend.accounts.fetchAll()
    let row = try #require(fetched.first { $0.id == original.id })
    #expect(row.valuationMode == .calculatedFromTrades)
  }

  @Test("recordedValue input is canonicalized to calculatedFromTrades")
  func recordedValueInputIsCanonicalized() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(
      name: "Brokerage", type: .investment, balance: 0,
      valuationMode: .calculatedFromTrades, in: database)
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: original.id) != nil },
      description: "seeded account observed"
    )

    var updated = original
    updated.valuationMode = .recordedValue
    let saved = try await store.update(updated)

    #expect(saved.valuationMode == .calculatedFromTrades)
    let fetched = try await backend.accounts.fetchAll()
    let row = try #require(fetched.first { $0.id == original.id })
    #expect(row.valuationMode == .calculatedFromTrades)
  }
}
