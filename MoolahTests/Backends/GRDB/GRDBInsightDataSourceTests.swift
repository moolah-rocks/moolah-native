import Foundation
import GRDB
import Testing

@testable import Moolah

/// Contract tests for `GRDBInsightDataSource` against a seeded
/// `TestBackend` (a real `CloudKitBackend` on an in-memory GRDB queue).
///
/// These pin the summaries the SQL aggregations produce — per-day totals,
/// per-category / per-account windowed sums, per-payee cadence, MAD-baseline
/// samples, and the bounded recent-candidate window — plus the Rule 11
/// conversion-drop path. Scaling (memory independence) lives in
/// `GRDBInsightDataSourceScalingTests`; per-day conversion correctness in
/// `GRDBInsightDataSourceConversionTests`; query-plan pinning in
/// `InsightDataSourcePlanPinningTests`.
@Suite("GRDBInsightDataSource summaries")
struct GRDBInsightDataSourceTests {
  private let aud = Instrument.defaultTestInstrument

  private func context(now: Date) -> InsightContext {
    InsightContext(now: now, reportingCurrency: aud)
  }

  /// Build an account-less expense (negative) or income (positive) leg —
  /// account-less legs still count toward the insight summaries, matching
  /// `InsightTransaction.records`.
  private func leg(
    _ quantity: Decimal,
    type: TransactionType,
    instrument: Instrument,
    accountId: UUID? = nil,
    categoryId: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId, instrument: instrument, quantity: quantity,
      type: type, categoryId: categoryId)
  }

  // MARK: - dailyTotals

  @Test("dailyTotals sums income and expense per UTC day")
  func dailyTotalsPerDay() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let dayOne = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10)
    let dayTwo = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 11)
    _ = try await backend.transactions.create(
      Transaction(date: dayOne, payee: "A", legs: [leg(-50, type: .expense, instrument: aud)]))
    _ = try await backend.transactions.create(
      Transaction(date: dayOne, payee: "B", legs: [leg(120, type: .income, instrument: aud)]))
    _ = try await backend.transactions.create(
      Transaction(date: dayTwo, payee: "C", legs: [leg(-30, type: .expense, instrument: aud)]))

    let totals = try await backend.insightDataSource.dailyTotals(
      context: context(now: try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)))

    #expect(totals.count == 2)
    let first = try #require(totals.first)
    #expect(first.spendMagnitude == 50)
    #expect(first.incomeMagnitude == 120)
    let second = try #require(totals.last)
    #expect(second.spendMagnitude == 30)
    #expect(second.incomeMagnitude == 0)
  }

  // MARK: - categorySpend / accountSpend

  @Test("categorySpend sums expenses per category inside the window")
  func categorySpendWindowed() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let groceries = Category(name: "Groceries")
    let inWindow = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 1)
    let outWindow = try AnalysisTestHelpers.utcDate(year: 2026, month: 1, day: 1)
    _ = try await backend.transactions.create(
      Transaction(
        date: inWindow, payee: "Shop",
        legs: [leg(-40, type: .expense, instrument: aud, categoryId: groceries.id)]))
    _ = try await backend.transactions.create(
      Transaction(
        date: outWindow, payee: "Shop",
        legs: [leg(-999, type: .expense, instrument: aud, categoryId: groceries.id)]))

    let spend = try await backend.insightDataSource.categorySpend(
      windowDays: 30, categories: Categories(from: [groceries]), context: context(now: now))

    #expect(spend.count == 1)
    let entry = try #require(spend.first)
    #expect(entry.categoryId == groceries.id)
    #expect(entry.categoryPath == "Groceries")
    #expect(entry.total.quantity == -40)
    #expect(entry.legCount == 1)
  }

  @Test("accountSpend sums expenses per account inside the window")
  func accountSpendWindowed() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let account = Account(id: UUID(), name: "Checking", type: .bank, instrument: aud)
    _ = try await backend.accounts.create(account)
    let day = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 2)
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Shop",
        legs: [leg(-25, type: .expense, instrument: aud, accountId: account.id)]))

    let spend = try await backend.insightDataSource.accountSpend(
      windowDays: 30, context: context(now: now))

    let entry = try #require(spend.first { $0.accountId == account.id })
    #expect(entry.total.quantity == -25)
    #expect(entry.legCount == 1)
  }

  // MARK: - payeeSummaries

  @Test("payeeSummaries clusters by normalized payee with cadence detail")
  func payeeSummariesCadence() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let first = try AnalysisTestHelpers.utcDate(year: 2026, month: 4, day: 10)
    let second = try AnalysisTestHelpers.utcDate(year: 2026, month: 5, day: 10)
    let third = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10)
    for date in [first, second, third] {
      _ = try await backend.transactions.create(
        Transaction(date: date, payee: "Netflix", legs: [leg(-15, type: .expense, instrument: aud)])
      )
    }

    let payees = try await backend.insightDataSource.payeeSummaries(
      windowDays: 395, context: context(now: now))

    let netflix = try #require(payees.first { $0.normalizedPayee.contains("netflix") })
    #expect(netflix.isExpense)
    #expect(netflix.occurrenceCount == 3)
    #expect(netflix.firstSeen == first)
    #expect(netflix.lastSeen == third)
    #expect(netflix.windowedTotal.quantity == -45)
    #expect(netflix.occurrences.map(\.date) == [first, second, third])
    #expect(netflix.displayPayee == "Netflix")
  }

  // MARK: - categorySamples

  @Test("categorySamples returns recent magnitudes most-recent first")
  func categorySamplesOrder() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let dining = Category(name: "Dining")
    let older = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 1)
    let newer = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 12)
    _ = try await backend.transactions.create(
      Transaction(
        date: older, payee: "Cafe",
        legs: [leg(-10, type: .expense, instrument: aud, categoryId: dining.id)]))
    _ = try await backend.transactions.create(
      Transaction(
        date: newer, payee: "Cafe",
        legs: [leg(-99, type: .expense, instrument: aud, categoryId: dining.id)]))

    let samples = try await backend.insightDataSource.categorySamples(
      windowDays: 365, maxPerCategory: 50, context: context(now: now))

    let entry = try #require(samples.first { $0.categoryId == dining.id })
    #expect(entry.magnitudes == [99, 10])
  }

  // MARK: - incomeSamples

  @Test("incomeSamples returns only income magnitudes, most-recent first")
  func incomeSamplesOrderAndType() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let older = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 1)
    let newer = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 12)
    _ = try await backend.transactions.create(
      Transaction(date: older, payee: "Salary A", legs: [leg(500, type: .income, instrument: aud)]))
    _ = try await backend.transactions.create(
      Transaction(date: newer, payee: "Bonus", legs: [leg(1200, type: .income, instrument: aud)]))
    // Expense leg must be excluded from income samples.
    _ = try await backend.transactions.create(
      Transaction(
        date: newer, payee: "Shop",
        legs: [leg(-80, type: .expense, instrument: aud)]))

    let samples = try await backend.insightDataSource.incomeSamples(
      windowDays: 365, maxCount: 50, context: context(now: now))

    // Only the two income legs; expense excluded; most-recent first.
    #expect(samples == [1200, 500])
    #expect(samples.allSatisfy { $0 > 0 })
  }

  @Test("incomeSamples respects maxCount cap")
  func incomeSamplesMaxCount() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    for day in 1...5 {
      let date = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: day)
      _ = try await backend.transactions.create(
        Transaction(
          date: date, payee: "Income",
          legs: [leg(Decimal(day * 100), type: .income, instrument: aud)]))
    }

    let samples = try await backend.insightDataSource.incomeSamples(
      windowDays: 365, maxCount: 3, context: context(now: now))

    #expect(samples.count == 3)
  }

  @Test("incomeSamples drops non-positive income amounts from the baseline")
  func incomeSamplesDropsNonPositive() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let day = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10)
    // Negative income (refund): must be dropped entirely, not appended as 0.
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Refund",
        legs: [leg(-50, type: .income, instrument: aud)]))
    // Positive income: must be included.
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Salary",
        legs: [leg(3000, type: .income, instrument: aud)]))

    let samples = try await backend.insightDataSource.incomeSamples(
      windowDays: 365, maxCount: 50, context: context(now: now))

    #expect(samples == [3000])
    #expect(samples.allSatisfy { $0 > 0 })
  }

  @Test("incomeSamples excludes legs outside the windowDays cutoff")
  func incomeSamplesWindowCutoff() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let inWindow = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 1)
    let outWindow = try AnalysisTestHelpers.utcDate(year: 2026, month: 1, day: 1)
    _ = try await backend.transactions.create(
      Transaction(date: inWindow, payee: "Recent", legs: [leg(300, type: .income, instrument: aud)])
    )
    _ = try await backend.transactions.create(
      Transaction(date: outWindow, payee: "Old", legs: [leg(9999, type: .income, instrument: aud)]))

    let samples = try await backend.insightDataSource.incomeSamples(
      windowDays: 30, maxCount: 50, context: context(now: now))

    #expect(samples == [300])
  }

  // MARK: - recentCandidates

  @Test("recentCandidates projects only legs inside the window, signs preserved")
  func recentCandidatesWindow() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let dining = Category(name: "Dining")
    let recent = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10)
    let stale = try AnalysisTestHelpers.utcDate(year: 2026, month: 1, day: 1)
    _ = try await backend.transactions.create(
      Transaction(
        date: recent, payee: "Cafe",
        legs: [leg(-12, type: .expense, instrument: aud, categoryId: dining.id)]))
    _ = try await backend.transactions.create(
      Transaction(date: stale, payee: "Old", legs: [leg(-12, type: .expense, instrument: aud)]))

    let candidates = try await backend.insightDataSource.recentCandidates(
      windowDays: 30, categories: Categories(from: [dining]), context: context(now: now))

    #expect(candidates.count == 1)
    let candidate = try #require(candidates.first)
    #expect(candidate.date == recent)
    #expect(candidate.amount == -12)
    #expect(candidate.spendMagnitude == 12)
    #expect(candidate.type == .expense)
    #expect(candidate.categoryPath == "Dining")
    #expect(candidate.normalizedPayee.contains("cafe"))
  }

  // MARK: - Rule 11 conversion failure

  @Test("a leg whose conversion fails is dropped and counted, siblings survive")
  func conversionFailureDropsLeg() async throws {
    let failDay = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10, hour: 0)
    let conversion = DateFailingConversionService(rates: [:], failingDates: [failDay])
    let backend = try CloudKitAnalysisTestBackend(conversionService: conversion)
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let usd = Instrument.fiat(code: "USD")
    let day = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10, hour: 12)
    _ = try await backend.transactions.create(
      Transaction(date: day, payee: "Foreign", legs: [leg(-100, type: .expense, instrument: usd)]))
    _ = try await backend.transactions.create(
      Transaction(date: day, payee: "Local", legs: [leg(-20, type: .expense, instrument: aud)]))

    let candidates = try await backend.insightDataSource.recentCandidates(
      windowDays: 30, categories: Categories(from: []), context: context(now: now))
    let summary = try await backend.insightDataSource.assemble(
      window: InsightDataWindow(), categories: Categories(from: []), context: context(now: now))

    // The AUD leg (same instrument, never converted) survives; the USD leg
    // is dropped rather than guessed, and surfaces in the drop count.
    #expect(candidates.count == 1)
    #expect(candidates.first?.amount == -20)
    #expect(summary.droppedLegCount > 0)
  }
}
