import Foundation
import GRDB
import Testing

@testable import Moolah

/// Date-sensitive conversion tests for `GRDBAnalysisRepository.fetchIncomeAndExpense`.
///
/// The SQL aggregation groups by `(DATE(t.date), instrument_id)` so
/// per-day grouping is rate-equivalent to the per-leg conversion the
/// SwiftData implementation performed. These tests pin that the right
/// calendar day is fed into the `InstrumentConversionService` per row —
/// a regression that drops the `DATE(t.date)` projection (collapsing to
/// per-month or per-range grouping) would silently pass against
/// constant-rate fixtures.
///
/// Uses `DateBasedFixedConversionService`, which returns a different
/// rate per calendar day, to detect such regressions.
@Suite("GRDBAnalysisRepository income and expense — date-sensitive conversion")
struct GRDBIncomeExpenseConversionTests {

  @Test("income and expense converts each day's USD legs at that day's rate")
  func incomeAndExpenseConvertsPerDayRate() async throws {
    // Two consecutive UTC days with different USD→AUD rates. The legs
    // are identical USD income; if SQL grouping collapses days into a
    // single bucket, both legs would convert at the same rate and the
    // totals would diverge from the per-day truth.
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 12)
    let rateOne = try AnalysisTestHelpers.decimal("1.5")
    let rateTwo = try AnalysisTestHelpers.decimal("2.0")

    // Seed at UTC midnight for each transaction's UTC calendar day so
    // `ratesAsOf`'s descending `<=` scan lands on the right rate per
    // parsed-day Date.
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 0): [
          "USD": rateOne
        ],
        try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 11, hour: 0): [
          "USD": rateTwo
        ],
      ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "USD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let usd = Instrument.fiat(code: "USD")

    _ = try await backend.transactions.create(
      Transaction(
        date: dayOne, payee: "US Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: 100, type: .income)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: dayTwo, payee: "US Salary",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: 100, type: .income)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    // Both transactions land in the same financial month (June, monthEnd
    // 25), so they collapse into one bucket. The total uses each day's
    // own rate: 100 * 1.5 + 100 * 2.0 = 350.
    #expect(data.count == 1)
    let month = try #require(data.first)
    #expect(month.income.quantity == 350)
    #expect(month.income.instrument == .defaultTestInstrument)
  }

  @Test("income and expense sums multi-instrument legs per their own day's rate")
  func incomeAndExpenseMultiInstrumentSamMonth() async throws {
    // EUR and USD legs on different days within the same financial
    // month. Each instrument converts at its leg's day rate; the bucket
    // collapses both into a single AUD total per (month, bucket).
    let dayUsd = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 12)
    let dayEur = try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 12, hour: 12)
    let usdRate = try AnalysisTestHelpers.decimal("1.5")
    let eurRate = try AnalysisTestHelpers.decimal("1.7")
    let conversion = DateBasedFixedConversionService(
      rates: [
        try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 10, hour: 0): [
          "USD": usdRate, "EUR": eurRate,
        ],
        try AnalysisTestHelpers.utcDate(year: 2025, month: 6, day: 12, hour: 0): [
          "USD": usdRate, "EUR": eurRate,
        ],
      ])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let usdAccount = Account(
      id: UUID(), name: "USD", type: .bank, instrument: .defaultTestInstrument)
    let eurAccount = Account(
      id: UUID(), name: "EUR", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(usdAccount)
    _ = try await backend.accounts.create(eurAccount)

    let usd = Instrument.fiat(code: "USD")
    let eur = Instrument.fiat(code: "EUR")

    _ = try await backend.transactions.create(
      Transaction(
        date: dayUsd, payee: "USD Income",
        legs: [
          TransactionLeg(
            accountId: usdAccount.id, instrument: usd,
            quantity: 100, type: .income)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: dayEur, payee: "EUR Income",
        legs: [
          TransactionLeg(
            accountId: eurAccount.id, instrument: eur,
            quantity: 100, type: .income)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    // Both instruments converted at 1.5 / 1.7 and summed in the
    // profile instrument: 100*1.5 + 100*1.7 = 320.
    #expect(data.count == 1)
    let month = try #require(data.first)
    #expect(month.income.quantity == 320)
    #expect(month.income.instrument == .defaultTestInstrument)
  }

  @Test("investment withdrawal: investment leg to investment layer, bank leg to base")
  func investmentTransferNegativeRoutesToEarmarkedExpense() async throws {
    // Transfers land in the expense column (both legs), so a withdrawal
    // splits across layers by account: the investment-side leg into the
    // investment layer, the bank-side leg into the available-funds base.
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 7, day: 10, hour: 12)
    let conversion = DateBasedFixedConversionService(rates: [:])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let bank = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bank)
    let investment = Account(
      id: UUID(), name: "Brokerage", type: .investment,
      instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investment)

    // Withdraw $20 from investment back to bank.
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Withdraw",
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: -20, type: .transfer),
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: 20, type: .transfer),
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let month = try #require(data.first)
    // Investment-side leg (-20) → investment layer; bank-side leg (+20) →
    // base. With investments included they net to zero.
    #expect(month.investmentExpense.quantity == -20)
    #expect(month.investmentIncome.quantity == 0)
    #expect(month.expense.quantity == 20)
    #expect(month.totalExpense.quantity == 0)
  }

  @Test("investment deposit: investment leg to investment layer, bank leg to base")
  func investmentTransferPositiveRoutesToEarmarkedIncome() async throws {
    // Sister test of `investmentTransferNegativeRoutesToEarmarkedExpense`
    // — a deposit's bank-side leg lowers the available-funds base while
    // the investment-side leg lands in the investment layer; they net to
    // zero with investments included (only own money moved).
    let day = try AnalysisTestHelpers.utcDate(year: 2025, month: 7, day: 11, hour: 12)
    let conversion = DateBasedFixedConversionService(rates: [:])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let bank = Account(
      id: UUID(), name: "Checking", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(bank)
    let investment = Account(
      id: UUID(), name: "Brokerage", type: .investment,
      instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(investment)

    // Deposit $50 from bank into investment account.
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Deposit",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .transfer),
          TransactionLeg(
            accountId: investment.id, instrument: .defaultTestInstrument,
            quantity: 50, type: .transfer),
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    let month = try #require(data.first)
    // Investment-side leg (+50) → investment layer; bank-side leg (-50) →
    // base. With investments included they net to zero.
    #expect(month.investmentExpense.quantity == 50)
    #expect(month.investmentIncome.quantity == 0)
    #expect(month.expense.quantity == -50)
    #expect(month.totalExpense.quantity == 0)
  }
}
