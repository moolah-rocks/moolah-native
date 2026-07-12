import Foundation
import Testing

@testable import Moolah

@Suite("InvestmentStore performance")
@MainActor
struct InvestmentStorePerformanceTests {

  @Test("loadAllData populates accountPerformance for a position-tracked account")
  func loadAllDataPositionTrackedPerformance() async throws {
    let aud = Instrument.AUD
    let (backend, _) = try TestBackend.create()
    let ledgerStore = HoldingsCostLedgerStore(
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService,
      referenceCurrency: aud)
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService,
      holdingsCostLedger: ledgerStore)

    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 10_000, instrument: aud))

    await store.loadAllData(account: account, profileCurrency: aud)

    let perf = try #require(store.accountPerformance)
    #expect(perf.instrument == aud)
    #expect(perf.currentValue == InstrumentAmount(quantity: 10_000, instrument: aud))
    // The opening balance is fiat cash → it creates no cost-basis lots, so the
    // amount invested (remaining cost basis) is 0: a fiat account shows no
    // baseline (Symptom 1). Performance is still populated from the shared
    // ledger provider.
    #expect(perf.amountInvested == InstrumentAmount(quantity: 0, instrument: aud))
  }

  @Test("loadAllData without a ledger provider leaves accountPerformance nil")
  func loadAllDataNoLedgerProviderLeavesPerformanceNil() async throws {
    let aud = Instrument.AUD
    let (backend, _) = try TestBackend.create()
    // Position-tracked performance is derived from the shared cost-basis
    // ledger; without its provider injected there is nothing to compute from,
    // so accountPerformance stays nil rather than being fabricated.
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)

    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 1_000, instrument: aud))

    await store.loadAllData(account: account, profileCurrency: aud)

    #expect(store.accountPerformance == nil)
  }

  @Test(
    "loadAllData on a valuation conversion failure surfaces the error and leaves value unavailable"
  )
  func loadAllDataConversionFailureMarksUnavailable() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let (backend, _) = try TestBackend.create()
    let conversion = FakeConversionService.failingInstruments([usd.id])
    let ledgerStore = HoldingsCostLedgerStore(
      transactionRepository: backend.transactions,
      conversionService: conversion,
      referenceCurrency: aud)
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversion,
      holdingsCostLedger: ledgerStore)

    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    // A USD position that must be valued USD → AUD. FakeConversionService
    // fails on USD, so valuatePositions cannot value the holding: it records
    // the error and the current value is unavailable (Rule 11 — no partial
    // sum). USD is fiat, so the cost-basis ledger holds no lots for it and the
    // amount invested is a genuine 0.
    let cashAccount = UUID()
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceReferenceDate: 0),
        legs: [
          TransactionLeg(
            accountId: cashAccount, instrument: usd, quantity: -100, type: .transfer),
          TransactionLeg(
            accountId: account.id, instrument: usd, quantity: 100, type: .transfer),
        ]
      )
    )

    await store.loadAllData(account: account, profileCurrency: aud)

    #expect(store.error != nil)
    #expect(store.accountPerformance?.currentValue == nil)
  }

}
