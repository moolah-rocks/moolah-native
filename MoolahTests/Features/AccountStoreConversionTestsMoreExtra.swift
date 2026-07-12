import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore -- Conversion")
@MainActor
struct AccountStoreConversionTestsMoreExtra {
  @Test
  func computeConvertedInvestmentTotalDoesNotDoubleConvert() async throws {
    let aud = Instrument.AUD
    let usd = Instrument.USD
    let eur = Instrument.fiat(code: "EUR")
    let accountId = UUID()
    // Position-derived totals contribute for every investment-like account.
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment, instrument: aud,
    )

    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    // Two foreign-currency positions in distinct instruments so the
    // repository yields two `Position` entries.
    let txns = [
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: usd,
            quantity: Decimal(100), type: .openingBalance)
        ]),
      Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId, instrument: eur,
            quantity: Decimal(50), type: .openingBalance)
        ]),
    ]
    TestBackend.seed(transactions: txns, in: database)

    let counter = FakeConversionService.fixedRates([
      "USD": dec("1.5"),
      "EUR": dec("2.0"),
    ])
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: counter,
      targetInstrument: aud)
    // Wait until the seeded positions are observable, then drain any
    // in-flight rate-tick recompute so the counter baseline is stable
    // before we measure this call.
    try await store.waitForNextEmission(
      matching: { $0.positions(for: accountId).count == 2 },
      description: "both positions observed"
    )
    await store.waitForPendingConversions()

    let baseline = counter.convertAmountCallCount
    let total = try await store.computeConvertedInvestmentTotal(in: aud)
    let delta = counter.convertAmountCallCount - baseline

    // 100 USD * 1.5 + 50 EUR * 2.0 = 150 + 100 = 250 AUD.
    #expect(total == InstrumentAmount(quantity: Decimal(250), instrument: aud))
    // One conversion per position (USD→AUD, EUR→AUD). The old implementation
    // made 3 calls: 2 per-position (→ account.instrument AUD) plus 1 outer
    // (accountBalance → target). New: 2 calls.
    #expect(delta == 2)
  }

  // MARK: - computeConvertedInvestmentTotal single-pass conversion

  /// Issue #96: `computeConvertedInvestmentTotal` must convert positions
  /// directly to `target` in a single pass, not chain positions → account
  /// instrument → target. For asymmetric rates (which all real-world rates
  /// are), chaining conversions compounds rounding error and produces a
  /// different result than summing positions directly to `target`. This
  /// test uses an asymmetric rate table where double-conversion and
  /// single-pass conversion produce distinct numerical answers and asserts
  /// the single-pass answer is returned.
  @Test
  func computeConvertedInvestmentTotalSumsPositionsDirectlyToTarget()
    async throws
  {
    let accountId = UUID()
    // Investment account held in AUD; target is USD. Asymmetric rates:
    //   USD -> USD (fast path, 1:1)
    //   AUD -> USD = 0.67
    // With double-conversion:
    //   displayBalance(AUD):  100 USD -> AUD at 1.5 = 150 AUD; + 1000 AUD = 1150 AUD
    //   convert 1150 AUD -> USD at 0.67 = 770.50 USD
    // With single-pass:
    //   100 USD -> USD (fast path) = 100 USD
    //   1000 AUD -> USD at 0.67 = 670 USD
    //   total = 770 USD
    // The 0.50 difference is the double-conversion drift.
    // Use `calculatedFromTrades` so positions are summed for the total.
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment, instrument: .AUD,
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let audTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .AUD,
          quantity: dec("1000.00"), type: .openingBalance)
      ])
    let usdTx = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .USD,
          quantity: dec("100.00"), type: .openingBalance)
      ])
    TestBackend.seed(transactions: [audTx, usdTx], in: database)

    let conversion = FakeConversionService.fixedRates([
      "AUD": dec("0.67"),
      "USD": dec("1.5"),
    ])
    let store = AccountStore(
      repository: backend.accounts,
      conversionService: conversion,
      targetInstrument: .USD)
    // Single-pass: 100 USD + (1000 AUD * 0.67) = 100 + 670 = 770 USD
    await expectEventually("single-pass investment total settles to 770 USD") {
      let total = try? await store.computeConvertedInvestmentTotal(in: .USD)
      return total?.instrument == .USD && total?.quantity == dec("770.00")
    }
  }

  /// Same-instrument positions and target must hit the fast path without
  /// stacking spurious conversions. For a profile where account instrument,
  /// positions, and target all share a currency, the result equals the raw
  /// position sum.
  @Test
  func computeConvertedInvestmentTotalFastPathSameInstrument()
    async throws
  {
    let accountId = UUID()
    // Use `calculatedFromTrades` so positions are summed.
    let account = Account(
      id: accountId, name: "Portfolio", type: .investment,
      instrument: .defaultTestInstrument,
    )
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(accounts: [account], in: database)

    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: dec("1234.56"), type: .openingBalance)
      ])
    TestBackend.seed(transactions: [transaction], in: database)

    let store = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .defaultTestInstrument)
    await expectEventually("fast-path total settles to the raw position sum") {
      let total = try? await store.computeConvertedInvestmentTotal(in: .defaultTestInstrument)
      return total?.instrument == .defaultTestInstrument && total?.quantity == dec("1234.56")
    }
  }
}
