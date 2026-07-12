import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("InvestmentStore ignores persisted Account.valuationMode")
struct InvestmentStoreValuationModeTests {
  @Test("loadAllData(account:) uses positions when mode is recordedValue")
  func recordedTakesPositionsPath() async throws {
    let (backend, _) = try TestBackend.create()
    let account = try await backend.accounts.create(
      Account(
        name: "Recorded", type: .investment, instrument: .AUD,
        valuationMode: .recordedValue))
    try await backend.investments.setValue(
      accountId: account.id,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 100, instrument: .AUD))
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: .AUD, quantity: -4_000, type: .trade),
        ]))

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    await store.loadAllData(account: account, profileCurrency: .AUD)

    #expect(store.values.isEmpty)
    #expect(!store.positions.isEmpty)
  }

  @Test("loadAllData(account:) also uses positions when mode is calculatedFromTrades")
  func calculatedModeTakesPositionsPath() async throws {
    let (backend, _) = try TestBackend.create()
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let account = try await backend.accounts.create(
      Account(
        name: "Trades", type: .investment, instrument: .AUD,
        valuationMode: .calculatedFromTrades))
    try await backend.investments.setValue(
      accountId: account.id,
      date: Date(timeIntervalSince1970: 1_700_000_000),
      value: InstrumentAmount(quantity: 9999, instrument: .AUD))
    // Seed a trade so the position path produces a non-empty result.
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(accountId: account.id, instrument: bhp, quantity: 100, type: .trade),
          TransactionLeg(accountId: account.id, instrument: .AUD, quantity: -4_000, type: .trade),
        ]))

    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    await store.loadAllData(account: account, profileCurrency: .AUD)

    #expect(store.values.isEmpty)
    #expect(!store.positions.isEmpty)
  }
}
