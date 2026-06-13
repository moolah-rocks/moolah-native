import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore/Loading")
@MainActor
struct AccountStoreLoadingTests {

  @Test
  func testPopulatesFromRepository() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Checking", balance: Decimal(100000) / 100, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await expectEventually("seeded account populates the store") {
      store.accounts.count == 1 && store.accounts.first?.name == "Checking"
    }
  }

  @Test
  func testSortingByPosition() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "A1", balance: Decimal(10000) / 100, position: 2, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "A2", type: .asset, balance: Decimal(20000) / 100, position: 1, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await expectEventually("accounts settle sorted by position") {
      store.accounts.count == 2
        && store.accounts[0].name == "A2"
        && store.accounts[1].name == "A1"
    }
  }

  @Test
  func testCalculatesTotals() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Bank", balance: Decimal(100000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "Asset", type: .asset, balance: Decimal(500000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "Credit Card", type: .creditCard, balance: Decimal(-50000) / 100, in: database)
    // Use `calculatedFromTrades` so position-derived balance contributes to
    // the investment total (recordedValue + no snapshot → 0).
    _ = AccountStoreTestSupport.seedAccount(
      name: "Investment", type: .investment, balance: Decimal(2_000_000) / 100,
      valuationMode: .calculatedFromTrades, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "Hidden", type: .asset, balance: Decimal(100_000_000) / 100, isHidden: true,
      in: database)

    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    // currentTotal = 100000 + 500000 - 50000 = 550000 (hidden excluded)
    await expectEventually("all three totals settle to expected amounts") {
      store.convertedCurrentTotal
        == InstrumentAmount(
          quantity: Decimal(550000) / 100, instrument: Instrument.defaultTestInstrument)
        && store.convertedInvestmentTotal
          == InstrumentAmount(
            quantity: Decimal(2_000_000) / 100, instrument: Instrument.defaultTestInstrument)
        && store.convertedNetWorth
          == InstrumentAmount(
            quantity: Decimal(2_550_000) / 100, instrument: Instrument.defaultTestInstrument)
    }
  }

  @Test
  func testConvertedTotalsHandleMixedInstruments() async throws {
    let aud = Instrument.defaultTestInstrument  // AUD in tests
    let usd = Instrument.fiat(code: "USD")
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "AUD Bank", balance: Decimal(100000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "USD Bank", instrument: usd, balance: Decimal(50000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "USD Asset", type: .asset, instrument: usd, balance: Decimal(20000) / 100,
      in: database)

    // 1 USD = 2 AUD — simple test rate
    let conversion = FixedConversionService(rates: ["USD": 2])
    let store = AccountStore(
      repository: backend.accounts, conversionService: conversion, targetInstrument: aud)

    // 1_000.00 AUD + (500.00 USD * 2) + (200.00 USD * 2) = 1_000 + 1_000 + 400 = 2_400.00
    await expectEventually("mixed-instrument totals settle to 2400.00 AUD") {
      store.convertedCurrentTotal
        == InstrumentAmount(quantity: Decimal(240_000) / 100, instrument: aud)
        && store.convertedNetWorth
          == InstrumentAmount(quantity: Decimal(240_000) / 100, instrument: aud)
    }
  }
}
