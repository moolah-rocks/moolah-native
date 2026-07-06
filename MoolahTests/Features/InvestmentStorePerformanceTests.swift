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
    #expect(perf.totalContributions == InstrumentAmount(quantity: 0, instrument: aud))
  }

  @Test("loadAllData populates accountPerformance for a legacy-valuation account")
  func loadAllDataLegacyPerformance() async throws {
    let account = Account(
      name: "Brokerage", type: .investment, instrument: .AUD,
      valuationMode: .recordedValue)
    let aud = Instrument.AUD
    let calendar = Calendar.current
    let earlierDate = try #require(
      calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
    let laterDate = try #require(
      calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: [
        account.id: [
          InvestmentValue(
            date: earlierDate,
            value: InstrumentAmount(quantity: 10_000, instrument: aud)),
          InvestmentValue(
            date: laterDate,
            value: InstrumentAmount(quantity: 11_000, instrument: aud)),
        ]
      ],
      in: database
    )
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)

    await store.loadAllData(account: account, profileCurrency: aud)

    let perf = try #require(store.accountPerformance)
    #expect(perf.currentValue == InstrumentAmount(quantity: 11_000, instrument: aud))
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

  @Test("setValue refreshes accountPerformance on the legacy path")
  func setValueRefreshesPerformance() async throws {
    let account = Account(
      name: "Brokerage", type: .investment, instrument: .AUD,
      valuationMode: .recordedValue)
    let aud = Instrument.AUD
    let calendar = Calendar.current
    let earlierDate = try #require(
      calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
    let laterDate = try #require(
      calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: [
        account.id: [
          InvestmentValue(
            date: earlierDate,
            value: InstrumentAmount(quantity: 10_000, instrument: aud))
        ]
      ],
      in: database
    )
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    await store.loadAllData(account: account, profileCurrency: aud)

    await store.setValue(
      accountId: account.id, date: laterDate,
      value: InstrumentAmount(quantity: 12_000, instrument: aud))

    let perf = try #require(store.accountPerformance)
    #expect(perf.currentValue == InstrumentAmount(quantity: 12_000, instrument: aud))
  }

  @Test("removeValue refreshes accountPerformance on the legacy path")
  func removeValueRefreshesPerformance() async throws {
    let account = Account(
      name: "Brokerage", type: .investment, instrument: .AUD,
      valuationMode: .recordedValue)
    let aud = Instrument.AUD
    let calendar = Calendar.current
    let earlierDate = try #require(
      calendar.date(from: DateComponents(year: 2024, month: 1, day: 1)))
    let laterDate = try #require(
      calendar.date(from: DateComponents(year: 2025, month: 1, day: 1)))
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(
      investmentValues: [
        account.id: [
          InvestmentValue(
            date: earlierDate,
            value: InstrumentAmount(quantity: 10_000, instrument: aud)),
          InvestmentValue(
            date: laterDate,
            value: InstrumentAmount(quantity: 11_000, instrument: aud)),
        ]
      ],
      in: database
    )
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)
    await store.loadAllData(account: account, profileCurrency: aud)

    await store.removeValue(accountId: account.id, date: laterDate)

    let perf = try #require(store.accountPerformance)
    #expect(perf.currentValue == InstrumentAmount(quantity: 10_000, instrument: aud))
  }
}
