// MoolahTests/Backends/GRDB/TaxIncomeSummaryPersistenceTests.swift

import Foundation
import Testing

@testable import Moolah

@Suite("Tax income summary persistence")
struct TaxIncomeSummaryPersistenceTests {
  @Test("tax income summaries include only reportable categories")
  func taxIncomeSummariesIncludeOnlyReportableCategories() async throws {
    let fixture = try await makeTaxIncomeFixture()
    let reportable = try await fixture.categories.create(
      Moolah.Category(name: "Interest", isTaxReportable: true))
    let ignored = try await fixture.categories.create(
      Moolah.Category(name: "Gift", isTaxReportable: false))
    _ = try await fixture.accounts.create(fixture.account)
    try await insertTaxTransaction(
      fixture.database,
      accountId: fixture.account.id,
      legs: [
        TaxTestLeg(100, .income, reportable.id),
        TaxTestLeg(80, .income, ignored.id),
        TaxTestLeg(-40, .expense, reportable.id),
      ])

    let summaries = try await fixture.analysis.fetchTaxIncomeExpenseSummaries(
      dateInterval: fixture.date..<fixture.date.addingTimeInterval(1),
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner)

    let summary = try #require(summaries.first)
    #expect(summaries.count == 1)
    #expect(summary.ownerId == fixture.defaultOwner)
    #expect(summary.taxableIncome.quantity == 100)
    #expect(summary.deductibleExpenses.quantity == 40)
    #expect(summary.netTaxableIncome.quantity == 60)
  }

  @Test("category tax owners override account owners")
  func taxIncomeSummariesUseCategoryOwnersFirst() async throws {
    let fixture = try await makeTaxIncomeFixture()
    let accountOwner = UUID()
    let categoryOwner = UUID()
    var account = fixture.account
    account.taxOwnerIds = [accountOwner]
    let category = try await fixture.categories.create(
      Moolah.Category(
        name: "Distribution",
        isTaxReportable: true,
        taxOwnerIds: [categoryOwner]))
    _ = try await fixture.accounts.create(account)
    try await insertTaxTransaction(
      fixture.database,
      accountId: account.id,
      legs: [TaxTestLeg(120, .income, category.id)])

    let summaries = try await fixture.analysis.fetchTaxIncomeExpenseSummaries(
      dateInterval: fixture.date..<fixture.date.addingTimeInterval(1),
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner)

    #expect(summaries.map(\.ownerId) == [categoryOwner])
    #expect(summaries.first?.taxableIncome.quantity == 120)
  }

  @Test("account tax owners split evenly when category has none")
  func taxIncomeSummariesSplitAcrossAccountOwners() async throws {
    let fixture = try await makeTaxIncomeFixture()
    let ownerA = UUID()
    let ownerB = UUID()
    let ownerC = UUID()
    var account = fixture.account
    account.taxOwnerIds = [ownerA, ownerB, ownerC]
    let category = try await fixture.categories.create(
      Moolah.Category(name: "Dividends", isTaxReportable: true))
    _ = try await fixture.accounts.create(account)
    try await insertTaxTransaction(
      fixture.database,
      accountId: account.id,
      legs: [TaxTestLeg(90, .income, category.id), TaxTestLeg(-30, .expense, category.id)])

    let summaries = try await fixture.analysis.fetchTaxIncomeExpenseSummaries(
      dateInterval: fixture.date..<fixture.date.addingTimeInterval(1),
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner)

    #expect(Set(summaries.map(\.ownerId)) == [ownerA, ownerB, ownerC])
    for summary in summaries {
      #expect(summary.taxableIncome.quantity == 30)
      #expect(summary.deductibleExpenses.quantity == 10)
    }
  }

  @Test("tax income details are tax specific and split by owner category instrument and day")
  func taxIncomeDetailsUseTaxDimensions() async throws {
    let usd = Instrument.USD
    let fixture = try await makeTaxIncomeFixture(
      conversionService: FakeConversionService.fixedRates([usd.id: 2]))
    let ownerA = UUID()
    let ownerB = UUID()
    var account = fixture.account
    account.taxOwnerIds = [ownerA, ownerB]
    let category = try await fixture.categories.create(
      Moolah.Category(name: "Dividends", isTaxReportable: true))
    _ = try await fixture.accounts.create(account)
    try await insertTaxTransaction(
      fixture.database,
      accountId: account.id,
      legs: [
        TaxTestLeg(90, .income, category.id, instrument: usd),
        TaxTestLeg(-30, .expense, category.id),
      ])

    let incomeRows = try await fixture.analysis.fetchTaxIncomeExpenseDetails(
      dateInterval: fixture.date..<fixture.date.addingTimeInterval(1),
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner,
      ownerId: ownerA,
      type: .income)
    let deductionRows = try await fixture.analysis.fetchTaxIncomeExpenseDetails(
      dateInterval: fixture.date..<fixture.date.addingTimeInterval(1),
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner,
      ownerId: nil,
      type: .expense)

    let income = try #require(incomeRows.first)
    #expect(incomeRows.count == 1)
    #expect(income.ownerId == ownerA)
    #expect(income.categoryId == category.id)
    #expect(income.instrument == usd)
    #expect(income.amount?.quantity == 90)
    #expect(Set(deductionRows.map(\.ownerId)) == [ownerA, ownerB])
    #expect(Set(deductionRows.compactMap { $0.amount?.quantity }) == [15])
  }

  @Test("tax income details group rows by Australian tax day across Sydney DST")
  func taxIncomeDetailsGroupByAustralianTaxDayAcrossDST() async throws {
    let fixture = try await makeTaxIncomeFixture()
    _ = try await fixture.accounts.create(fixture.account)
    let category = try await fixture.categories.create(
      Moolah.Category(name: "Interest", isTaxReportable: true))
    let sameSydneyDayStartUTC = try AnalysisTestHelpers.utcDate(
      year: 2026, month: 1, day: 4, hour: 14)
    let sameSydneyDayEndUTC = try AnalysisTestHelpers.utcDate(
      year: 2026, month: 1, day: 5, hour: 12)
    let nextSydneyDayUTC = try AnalysisTestHelpers.utcDate(
      year: 2026, month: 1, day: 5, hour: 13)
    try await insertTaxTransaction(
      fixture.database,
      accountId: fixture.account.id,
      date: sameSydneyDayStartUTC,
      legs: [TaxTestLeg(10, .income, category.id)])
    try await insertTaxTransaction(
      fixture.database,
      accountId: fixture.account.id,
      date: sameSydneyDayEndUTC,
      legs: [TaxTestLeg(20, .income, category.id)])
    try await insertTaxTransaction(
      fixture.database,
      accountId: fixture.account.id,
      date: nextSydneyDayUTC,
      legs: [TaxTestLeg(30, .income, category.id)])
    let financialYearStart = try #require(
      AustralianTaxCalendar.calendar.date(from: DateComponents(year: 2025, month: 7, day: 1)))
    let financialYearEnd = try #require(
      AustralianTaxCalendar.calendar.date(from: DateComponents(year: 2026, month: 7, day: 1)))

    let rows = try await fixture.analysis.fetchTaxIncomeExpenseDetails(
      dateInterval: financialYearStart..<financialYearEnd,
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner,
      ownerId: fixture.defaultOwner,
      type: .income)

    #expect(rows.map(\.amount?.quantity) == [30, 30])
    let days = rows.compactMap(\.day).map {
      AustralianTaxCalendar.calendar.dateComponents([.year, .month, .day], from: $0)
    }
    #expect(days.map(\.year) == [2026, 2026])
    #expect(days.map(\.month) == [1, 1])
    #expect(days.map(\.day) == [5, 6])
  }

  @Test("tax income conversion uses Australian tax day at UTC boundary")
  func taxIncomeConversionUsesAustralianTaxDayAtUTCBoundary() async throws {
    let usd = Instrument.USD
    let australianTaxDay = try #require(
      AustralianTaxCalendar.calendar.date(
        from: DateComponents(year: 2025, month: 7, day: 1)))
    let utcTaxDay = try AnalysisTestHelpers.utcDate(year: 2025, month: 7, day: 1, hour: 0)
    let nextFinancialYear = try #require(
      AustralianTaxCalendar.calendar.date(
        from: DateComponents(year: 2026, month: 7, day: 1)))
    let utcBoundaryInstant = try AnalysisTestHelpers.utcDate(
      year: 2025, month: 6, day: 30, hour: 15)
    let conversion = FakeConversionService.dateRates([
      utcTaxDay: [usd.id: 3]
    ])
    let fixture = try await makeTaxIncomeFixture(conversionService: conversion)
    _ = try await fixture.accounts.create(fixture.account)
    let category = try await fixture.categories.create(
      Moolah.Category(name: "Foreign interest", isTaxReportable: true))
    try await insertTaxTransaction(
      fixture.database,
      accountId: fixture.account.id,
      date: utcBoundaryInstant,
      legs: [TaxTestLeg(100, .income, category.id, instrument: usd)])

    let summaries = try await fixture.analysis.fetchTaxIncomeExpenseSummaries(
      dateInterval: australianTaxDay..<nextFinancialYear,
      targetInstrument: .AUD,
      defaultTaxOwnerId: fixture.defaultOwner)

    let summary = try #require(summaries.first)
    let conversionRequest = try #require(conversion.recordedBatches.last?.first)
    #expect(summaries.count == 1)
    #expect(summary.taxableIncome.quantity == 300)
    #expect(conversionRequest.date == utcTaxDay)
  }

  @Test("tax reportable transaction filters use resolved tax owner")
  func taxReportableTransactionFiltersUseResolvedTaxOwner() async throws {
    let seeded = try await makeTaxReportableTransactionFilterFixture()
    let fixture = seeded.fixture
    let accountOwner = seeded.accountOwner

    let accountOwnerIncome = try await fixture.transactions.fetchAll(
      filter: TransactionFilter(
        dateRange: fixture.date...fixture.date,
        taxReportableLegType: .income,
        taxOwnerId: accountOwner,
        taxDefaultOwnerId: fixture.defaultOwner))
    let allIncome = try await fixture.transactions.fetchAll(
      filter: TransactionFilter(
        dateRange: fixture.date...fixture.date,
        taxReportableLegType: .income,
        taxDefaultOwnerId: fixture.defaultOwner))
    let accountOwnerDeductions = try await fixture.transactions.fetchAll(
      filter: TransactionFilter(
        dateRange: fixture.date...fixture.date,
        taxReportableLegType: .expense,
        taxOwnerId: accountOwner,
        taxDefaultOwnerId: fixture.defaultOwner))

    #expect(accountOwnerIncome.map(\.payee) == ["Account owner income"])
    #expect(Set(allIncome.map(\.payee)) == ["Account owner income", "Category owner income"])
    #expect(accountOwnerDeductions.map(\.payee) == ["Account owner deduction"])
  }

  @Test("tax reportable transaction filters preserve exclusive upper date")
  func taxReportableTransactionFiltersPreserveExclusiveUpperDate() async throws {
    let fixture = try await makeTaxIncomeFixture()
    _ = try await fixture.accounts.create(fixture.account)
    let category = try await fixture.categories.create(
      Moolah.Category(name: "Interest", isTaxReportable: true))
    let upperBound = fixture.date.addingTimeInterval(10)
    try await insertTaxTransaction(
      fixture.database,
      accountId: fixture.account.id,
      payee: "Inside boundary",
      date: upperBound.addingTimeInterval(-1),
      legs: [TaxTestLeg(100, .income, category.id)])
    try await insertTaxTransaction(
      fixture.database,
      accountId: fixture.account.id,
      payee: "Outside boundary",
      date: upperBound,
      legs: [TaxTestLeg(200, .income, category.id)])

    let page = try await fixture.transactions.fetchAll(
      filter: TransactionFilter(
        dateInterval: fixture.date..<upperBound,
        taxReportableLegType: .income,
        taxDefaultOwnerId: fixture.defaultOwner))

    #expect(page.map(\.payee) == ["Inside boundary"])
  }
}
