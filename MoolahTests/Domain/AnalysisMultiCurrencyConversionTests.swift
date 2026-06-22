import Foundation
import Testing

@testable import Moolah

/// Contract tests for multi-currency conversion via `FakeConversionService`
/// across expense breakdown, income/expense, category balances, and forecasts.
@Suite("AnalysisRepository Contract Tests — Multi-Currency Conversion")
struct AnalysisMultiCurrencyConversionTests {

  @Test("expense breakdown converts foreign-currency legs to profile currency")
  func expenseBreakdownConvertsForeignCurrency() async throws {
    // USD -> AUD at 1.5x rate
    let rate = try AnalysisTestHelpers.decimal("1.5")
    let conversion = FakeConversionService.fixedRates(["USD": rate])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)
    let account = Account(
      id: UUID(), name: "USD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Groceries")
    _ = try await backend.categories.create(category)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let usd = Instrument.fiat(code: "USD")

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -100, type: .expense, categoryId: category.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "AU Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -50, type: .expense, categoryId: category.id)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)

    #expect(breakdown.count == 1)
    // -100 USD * 1.5 = -150 AUD, plus -50 AUD = -200 AUD
    #expect(breakdown[0].totalExpenses.quantity == -200)
    #expect(breakdown[0].totalExpenses.instrument == .defaultTestInstrument)
  }

  @Test("income/expense converts foreign-currency legs to profile currency")
  func incomeExpenseConvertsForeignCurrency() async throws {
    let rate = try AnalysisTestHelpers.decimal("1.5")
    let conversion = FakeConversionService.fixedRates(["USD": rate])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)
    let account = Account(
      id: UUID(), name: "Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let usd = Instrument.fiat(code: "USD")

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "US Employer",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: 200, type: .income)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -80, type: .expense)
        ]))

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)

    #expect(!data.isEmpty)
    let month = data[0]
    #expect(month.income.quantity == 300)
    #expect(month.expense.quantity == -120)
    #expect(month.profit.quantity == 180)
    #expect(month.income.instrument == .defaultTestInstrument)
  }

  @Test("category balances converts foreign-currency legs to profile currency")
  func categoryBalancesConvertsForeignCurrency() async throws {
    let rate = try AnalysisTestHelpers.decimal("1.5")
    let conversion = FakeConversionService.fixedRates(["USD": rate])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)
    let account = Account(
      id: UUID(), name: "Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(category)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())
    let usd = Instrument.fiat(code: "USD")

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "US Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: usd,
            quantity: -40, type: .expense, categoryId: category.id)
        ]))

    let balances = try await backend.analysis.fetchCategoryBalances(
      dateRange: today...today,
      transactionType: .expense,
      filters: nil,
      targetInstrument: .defaultTestInstrument)

    // -40 USD * 1.5 = -60 AUD
    #expect(
      balances[category.id] == InstrumentAmount(quantity: -60, instrument: .defaultTestInstrument))
  }

  @Test("forecast converts foreign-currency scheduled transactions to profile currency")
  func forecastConvertsForeignCurrencyScheduled() async throws {
    let rate = try AnalysisTestHelpers.decimal("1.5")
    let conversion = FakeConversionService.fixedRates(["USD": rate])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let audAccount = Account(
      id: UUID(), name: "AUD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(audAccount)

    let today = AnalysisTestHelpers.calendar.startOfDay(for: Date())
    let yesterday = try AnalysisTestHelpers.addingDays(-1, to: today)
    let tomorrow = try AnalysisTestHelpers.addingDays(1, to: today)
    let nextWeek = try AnalysisTestHelpers.addingDays(7, to: today)
    let usd = Instrument.fiat(code: "USD")

    // Opening AUD balance so forecast has a starting value.
    _ = try await backend.transactions.create(
      Transaction(
        date: yesterday, payee: "Opening",
        legs: [
          TransactionLeg(
            accountId: audAccount.id, instrument: .defaultTestInstrument,
            quantity: 1000, type: .openingBalance)
        ]))

    // Scheduled USD expense -100 USD (one-off, future-dated).
    _ = try await backend.transactions.create(
      Transaction(
        id: UUID(), date: tomorrow, payee: "US Subscription",
        recurPeriod: .once,
        legs: [
          TransactionLeg(
            accountId: audAccount.id, instrument: usd,
            quantity: -100, type: .expense)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nextWeek)

    let forecastEntry = try #require(balances.first { $0.date == tomorrow && $0.isForecast })

    // 1000 AUD starting - 100 USD * 1.5 = 850 AUD.
    #expect(forecastEntry.balance.quantity == 850)
    #expect(forecastEntry.balance.instrument == .defaultTestInstrument)
  }

  @Test("forecast leaves profile-currency scheduled transactions unchanged")
  func forecastLeavesProfileCurrencyUnchanged() async throws {
    // Inject a service that throws on any invocation. If the short-circuit is
    // removed, this test fails because the throwing service propagates.
    let conversion = FakeConversionService.alwaysThrows
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)

    let account = Account(
      id: UUID(), name: "AUD Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let today = AnalysisTestHelpers.calendar.startOfDay(for: Date())
    let yesterday = try AnalysisTestHelpers.addingDays(-1, to: today)
    let tomorrow = try AnalysisTestHelpers.addingDays(1, to: today)
    let nextWeek = try AnalysisTestHelpers.addingDays(7, to: today)

    _ = try await backend.transactions.create(
      Transaction(
        date: yesterday, payee: "Opening",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: 500, type: .openingBalance)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        id: UUID(), date: tomorrow, payee: "Rent",
        recurPeriod: .once,
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -200, type: .expense)
        ]))

    let balances = try await backend.analysis.fetchDailyBalances(
      after: nil, forecastUntil: nextWeek)

    let forecastEntry = try #require(balances.first { $0.date == tomorrow && $0.isForecast })
    #expect(forecastEntry.balance.quantity == 300)
  }

  @Test("single-currency profiles work without conversion")
  func singleCurrencyNoConversion() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let account = Account(
      id: UUID(), name: "Account", type: .bank, instrument: .defaultTestInstrument)
    _ = try await backend.accounts.create(account)

    let category = Category(id: UUID(), name: "Food")
    _ = try await backend.categories.create(category)

    let today = AnalysisTestHelpers.currentCalendar.startOfDay(for: Date())

    _ = try await backend.transactions.create(
      Transaction(
        date: today, payee: "Store",
        legs: [
          TransactionLeg(
            accountId: account.id, instrument: .defaultTestInstrument,
            quantity: -25, type: .expense, categoryId: category.id)
        ]))

    let breakdown = try await backend.analysis.fetchExpenseBreakdown(monthEnd: 25, after: nil)
    #expect(breakdown.count == 1)
    #expect(breakdown[0].totalExpenses.quantity == -25)

    let data = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 25, after: nil)
    #expect(!data.isEmpty)
    #expect(data[0].expense.quantity == -25)
  }
}
