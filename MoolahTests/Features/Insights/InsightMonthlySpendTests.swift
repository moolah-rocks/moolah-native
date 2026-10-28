import Foundation
import Testing

@testable import Moolah

@Suite("Insight monthly spending")
struct InsightMonthlySpendTests {
  private let currency = Instrument.defaultTestInstrument
  private var context: InsightContext {
    InsightContext(
      now: InsightTestSupport.now, reportingCurrency: currency, financialMonthEnd: 31)
  }

  @Test
  func earmarkedInvestmentWithdrawalCannotEraseMonthlySpending() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let bank = try await backend.accounts.create(
      Account(name: "Bank", type: .bank, instrument: currency))
    let investment = try await backend.accounts.create(
      Account(name: "Investment", type: .investment, instrument: currency))
    let earmark = try await backend.earmarks.create(
      Earmark(name: "Bills", instrument: currency))
    let context = InsightContext(
      now: InsightTestSupport.date(2026, 10, 28), reportingCurrency: currency,
      financialMonthEnd: 28)
    for (month, quantity) in [(8, Decimal(-100)), (9, Decimal(-200))] {
      _ = try await backend.transactions.create(
        Transaction(
          date: InsightTestSupport.date(2026, month, 15), payee: "Bill",
          legs: [
            TransactionLeg(
              accountId: bank.id, instrument: currency, quantity: quantity, type: .expense)
          ]))
    }
    _ = try await backend.transactions.create(
      Transaction(
        date: InsightTestSupport.date(2026, 9, 16), payee: "Earmarked bill",
        legs: [
          TransactionLeg(
            accountId: bank.id, instrument: currency, quantity: -50,
            type: .expense, earmarkId: earmark.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: InsightTestSupport.date(2026, 9, 17), payee: "Investment withdrawal",
        legs: [
          TransactionLeg(
            accountId: investment.id, instrument: currency, quantity: 20000, type: .transfer),
          TransactionLeg(
            accountId: bank.id, instrument: currency, quantity: -20000,
            type: .transfer, earmarkId: earmark.id),
        ]))
    let analysis = try await backend.analysis.fetchIncomeAndExpense(monthEnd: 28, after: nil)
    #expect(analysis.map(\.totalExpense.quantity) == [19800, -100])

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(monthly: analysis), context: context)
    #expect(input.monthly == analysis)
    #expect(input.monthlySpending.map(\.expense.quantity) == [-100, -250])
    let insight = try #require(
      InsightEngine().detectAll(input).first { $0.kind == .monthOverMonthDelta })
    #expect(
      insight.facts.contains { $0.label == "Latest spend" && $0.value == context.formatted(-250) })
    #expect(insight.framing == .negative)
  }

  @Test(arguments: ["America/Los_Angeles", "UTC", "Australia/Brisbane", "Pacific/Kiritimati"])
  func monthlyTotalsUseCutoffSignedRefundsAndHistoricRates(zoneId: String) async throws {
    let usd = Instrument.fiat(code: "USD")
    let first = InsightTestSupport.date(2026, 8, 28)
    let second = InsightTestSupport.date(2026, 8, 29)
    let backend = try CloudKitAnalysisTestBackend(
      conversionService: FakeConversionService.dateRates([
        first: ["USD": 2], second: ["USD": 3],
      ]))
    var calendar = Calendar.utc
    calendar.timeZone = try #require(TimeZone(identifier: zoneId))
    let context = InsightContext(
      now: InsightTestSupport.date(2026, 10, 28), reportingCurrency: currency,
      calendar: calendar, financialMonthEnd: 28)
    let entries: [(Date, (Decimal, TransactionType))] = [
      (first, (-100, .expense)), (second, (-100, .expense)),
      (second, (20, .expense)), (second, (500, .income)),
      (second, (900, .transfer)), (second, (700, .trade)),
      (InsightTestSupport.date(2026, 10, 29), (-999, .expense)),
    ]
    for (date, entry) in entries {
      _ = try await backend.transactions.create(
        Transaction(
          date: date, payee: "Entry",
          legs: [TransactionLeg(accountId: nil, instrument: usd, quantity: entry.0, type: entry.1)])
      )
    }
    _ = try await backend.transactions.create(
      Transaction(
        date: second, payee: "Scheduled", recurPeriod: .month, recurEvery: 1,
        legs: [TransactionLeg(accountId: nil, instrument: usd, quantity: -500, type: .expense)]))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context)
    #expect(input.monthlySpending.map(\.month) == ["202608", "202609"])
    #expect(input.monthlySpending.map(\.expense.quantity) == [-200, -240])
    #expect(input.monthlySpending.allSatisfy { $0.expense.instrument == currency })
  }

  @Test
  func unavailableDailyTotalsSuppressMonthlyClaims() async throws {
    let backend = try CloudKitAnalysisTestBackend(
      conversionService: FakeConversionService.failingInstruments(["USD"]))
    _ = try await backend.transactions.create(
      Transaction(
        date: InsightTestSupport.date(2026, 5, 15), payee: "Unpriced",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .fiat(code: "USD"), quantity: -100, type: .expense)
        ]))
    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context)
    #expect(!input.dataAvailability.dailyTotals)
    #expect(input.monthlySpending.count == 1)
    #expect(input.monthlySpending.first?.hasUnavailableData == true)
  }
}

extension InsightMonthlySpendTests {
  @Test(arguments: [3, 4, 5])
  func unavailableMonthSuppressesOnlyDependentComparisonOrChart(failedMonth: Int) async throws {
    let backend = try CloudKitAnalysisTestBackend(
      conversionService: FakeConversionService.failingInstruments(["USD"]))
    for (month, quantity) in [(3, Decimal(-90)), (4, Decimal(-100)), (5, Decimal(-200))] {
      _ = try await backend.transactions.create(
        Transaction(
          date: InsightTestSupport.date(2026, month, 15), payee: "Bill",
          legs: [
            TransactionLeg(accountId: nil, instrument: currency, quantity: quantity, type: .expense)
          ]))
    }
    _ = try await backend.transactions.create(
      Transaction(
        date: InsightTestSupport.date(2026, failedMonth, 16), payee: "Unpriced",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .fiat(code: "USD"), quantity: -10, type: .expense)
        ]))
    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context)
    #expect(input.monthlySpending.map(\.hasUnavailableData) == (3...5).map { $0 == failedMonth })
    let insights = PeriodComparisonInsights.detect(
      monthly: input.monthlySpending, context: input.context)
    if failedMonth == 3 {
      let insight = try #require(insights.first)
      #expect(insight.chart == nil)
      #expect(insight.framing == .negative)
    } else {
      #expect(insights.isEmpty)
    }
  }
}

extension InsightMonthlySpendTests {
  @Test
  func unavailableIncomeDoesNotInvalidateKnownSpending() async throws {
    let backend = try CloudKitAnalysisTestBackend(
      conversionService: FakeConversionService.failingInstruments(["USD"]))
    for (month, quantity) in [(4, Decimal(-100)), (5, Decimal(-200))] {
      _ = try await backend.transactions.create(
        Transaction(
          date: InsightTestSupport.date(2026, month, 15), payee: "Bill",
          legs: [
            TransactionLeg(accountId: nil, instrument: currency, quantity: quantity, type: .expense)
          ]))
    }
    _ = try await backend.transactions.create(
      Transaction(
        date: InsightTestSupport.date(2026, 5, 16), payee: "Unpriced income",
        legs: [
          TransactionLeg(
            accountId: nil, instrument: .fiat(code: "USD"), quantity: 10, type: .income)
        ]))
    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context)
    #expect(!input.dataAvailability.dailyTotals)
    #expect(input.dataAvailability.dailyExpenseTotals)
    #expect(input.monthlySpending.allSatisfy { !$0.hasUnavailableData })
    let insight = try #require(
      InsightEngine().detectAll(input).first { $0.kind == .monthOverMonthDelta })
    #expect(insight.framing == .negative)
    #expect(insight.chart != nil)
  }
}
