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
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: backend.conversionService)

    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 10_000, instrument: aud))

    await store.loadAllData(account: account, profileCurrency: aud)

    let perf = try #require(store.accountPerformance)
    #expect(perf.instrument == aud)
    #expect(perf.totalContributions == InstrumentAmount(quantity: 10_000, instrument: aud))
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

  @Test("loadAllData with nil transactionRepository leaves accountPerformance nil")
  func loadAllDataNilTransactionRepositoryLeavesPerformanceNil() async throws {
    let aud = Instrument.AUD
    let (backend, _) = try TestBackend.create()
    // No transaction repository → position-tracked compute can't run.
    // accountPerformance must stay nil for a calculatedFromTrades account.
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: nil,
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
    "loadAllData on conversion failure marks accountPerformance unavailable and surfaces the error"
  )
  func loadAllDataConversionFailureMarksUnavailable() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let (backend, _) = try TestBackend.create()
    let conversion = FakeConversionService.failingInstruments([usd.id])
    let store = InvestmentStore(
      repository: backend.investments,
      transactionRepository: backend.transactions,
      conversionService: conversion)

    let account = Account(
      name: "Brokerage", type: .investment, instrument: aud,
      valuationMode: .calculatedFromTrades)
    _ = try await backend.accounts.create(
      account, openingBalance: InstrumentAmount(quantity: 0, instrument: aud))

    // Cross-account USD transfer in — calculator must convert USD → AUD.
    // FakeConversionService.failingInstruments throws on USD, so compute() throws and the
    // store sets accountPerformance = nil + records the error.
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

    #expect(store.accountPerformance == nil)
    #expect(store.error != nil)
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
