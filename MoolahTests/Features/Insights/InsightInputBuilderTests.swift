import Foundation
import Testing

@testable import Moolah

/// Tests for `InsightInputBuilder`, the off-main assembler that joins a
/// main-actor-gathered `InsightInputSnapshot` with the SQL-backed
/// `InsightDataSource` summaries and the repository aggregates.
///
/// Seeds a real `CloudKitAnalysisTestBackend` (CloudKitBackend on an in-memory
/// GRDB queue) via the repository APIs so the data source observes real rows.
@Suite("InsightInputBuilder")
struct InsightInputBuilderTests {
  private let aud = Instrument.defaultTestInstrument

  private func context(now: Date) -> InsightContext {
    InsightContext(now: now, reportingCurrency: aud)
  }

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

  // MARK: - Data-source half

  @Test("recentCandidates include recent legs and exclude stale ones")
  func recentCandidatesWindow() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let recent = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10)
    let stale = try AnalysisTestHelpers.utcDate(year: 2026, month: 1, day: 1)
    _ = try await backend.transactions.create(
      Transaction(date: recent, payee: "Cafe", legs: [leg(-12, type: .expense, instrument: aud)]))
    _ = try await backend.transactions.create(
      Transaction(date: stale, payee: "Old", legs: [leg(-99, type: .expense, instrument: aud)]))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context(now: now))

    #expect(input.recentCandidates.count == 1)
    #expect(input.recentCandidates.first?.amount == -12)
  }

  @Test("dailyTotals, payees, categorySamples, incomeSamples populate from seeded rows")
  func summariesPopulate() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let dining = Category(name: "Dining")
    let day = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10)
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Cafe",
        legs: [leg(-40, type: .expense, instrument: aud, categoryId: dining.id)]))
    _ = try await backend.transactions.create(
      Transaction(date: day, payee: "Salary", legs: [leg(2000, type: .income, instrument: aud)]))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(categories: Categories(from: [dining])),
      context: context(now: now))

    #expect(!input.dailyTotals.isEmpty)
    #expect(input.payees.contains { $0.normalizedPayee.contains("cafe") })
    #expect(input.categorySamples.contains { $0.categoryId == dining.id })
    #expect(input.incomeSamples == [2000])
  }

  @Test("feeCategorySpend (365d) and unbudgetedCategorySpend (90d) reflect their windows")
  func categorySpendWindows() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let fees = Category(name: "Fees")
    let withinBoth = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 1)
    let only365 = try AnalysisTestHelpers.utcDate(year: 2025, month: 9, day: 1)
    _ = try await backend.transactions.create(
      Transaction(
        date: withinBoth, payee: "Bank",
        legs: [leg(-10, type: .expense, instrument: aud, categoryId: fees.id)]))
    _ = try await backend.transactions.create(
      Transaction(
        date: only365, payee: "Bank",
        legs: [leg(-5, type: .expense, instrument: aud, categoryId: fees.id)]))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(categories: Categories(from: [fees])),
      context: context(now: now))

    let fee365 = try #require(input.feeCategorySpend.first { $0.categoryId == fees.id })
    #expect(fee365.total.quantity == -15)
    let fee90 = try #require(input.unbudgetedCategorySpend.first { $0.categoryId == fees.id })
    #expect(fee90.total.quantity == -10)
  }

  @Test("accountSpend reflects 30d per-account spend")
  func accountSpendWindow() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let account = Account(id: UUID(), name: "Checking", type: .bank, instrument: aud)
    _ = try await backend.accounts.create(account)
    let day = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 2)
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "Shop",
        legs: [leg(-25, type: .expense, instrument: aud, accountId: account.id)]))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context(now: now))

    let entry = try #require(input.accountSpend.first { $0.accountId == account.id })
    #expect(entry.total.quantity == -25)
  }

  // MARK: - scheduledBills

  @Test("scheduledBills reflect future scheduled transactions, sign preserved")
  func scheduledBillsConverted() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = Date()
    let account = Account(id: UUID(), name: "Checking", type: .bank, instrument: aud)
    _ = try await backend.accounts.create(account)
    let future = try AnalysisTestHelpers.addingDaysCurrentCalendar(14, to: now)
    let pastScheduled = try AnalysisTestHelpers.addingDaysCurrentCalendar(-14, to: now)
    let futureScheduled = try await backend.transactions.create(
      Transaction(
        date: future, payee: "Rent", recurPeriod: .month, recurEvery: 1,
        legs: [leg(-1500, type: .expense, instrument: aud, accountId: account.id)]))
    // A past-dated scheduled transaction must be excluded (future-dated only).
    _ = try await backend.transactions.create(
      Transaction(
        date: pastScheduled, payee: "Old Bill", recurPeriod: .month, recurEvery: 1,
        legs: [leg(-50, type: .expense, instrument: aud, accountId: account.id)]))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context(now: now))

    let bill = try #require(input.scheduledBills.first { $0.id == futureScheduled.id })
    #expect(bill.amount.quantity == -1500)
    #expect(bill.amount.instrument == aud)
    #expect(bill.payee == "Rent")
    #expect(bill.accountId == account.id)
    #expect(input.scheduledBills.count == 1)
  }

  @Test("scheduledBills drop a leg whose conversion fails")
  func scheduledBillsDropFailingConversion() async throws {
    // Fail every conversion off the AUD reporting currency.
    let alwaysFail = FakeConversionService.alwaysThrows
    let backend = try CloudKitAnalysisTestBackend(conversionService: alwaysFail)
    let now = Date()
    let future = try AnalysisTestHelpers.addingDaysCurrentCalendar(14, to: now)
    let usd = Instrument.fiat(code: "USD")
    // Foreign-instrument scheduled bill — conversion fails, must be dropped.
    _ = try await backend.transactions.create(
      Transaction(
        date: future, payee: "Foreign Sub", recurPeriod: .month, recurEvery: 1,
        legs: [leg(-30, type: .expense, instrument: usd)]))
    // Same-currency bill — converts trivially, must appear.
    let localBill = try await backend.transactions.create(
      Transaction(
        date: future, payee: "Local Sub", recurPeriod: .month, recurEvery: 1,
        legs: [leg(-20, type: .expense, instrument: aud)]))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context(now: now))

    #expect(input.scheduledBills.count == 1)
    #expect(input.scheduledBills.first?.id == localBill.id)
    #expect(input.scheduledBills.first?.amount.quantity == -20)
  }

  // MARK: - repository aggregates

  @Test("uncategorizedTransactionCount matches countNeedsReview")
  func uncategorizedCount() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let day = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10)
    _ = try await backend.transactions.create(
      Transaction(date: day, payee: "A", legs: [leg(-10, type: .expense, instrument: aud)]))
    _ = try await backend.transactions.create(
      Transaction(date: day, payee: "B", legs: [leg(-20, type: .expense, instrument: aud)]))
    let categorised = Category(name: "Cat")
    _ = try await backend.transactions.create(
      Transaction(
        date: day, payee: "C",
        legs: [leg(-30, type: .expense, instrument: aud, categoryId: categorised.id)]))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context(now: now))

    let expected = try await backend.transactions.countNeedsReview()
    #expect(input.uncategorizedTransactionCount == expected)
    #expect(input.uncategorizedTransactionCount == 2)
  }

  @Test("pendingTransferCount and oldestPendingTransferDate reflect seeded suggestions")
  func pendingTransfers() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let older = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 1)
    let newer = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 10)
    _ = try await backend.transferSuggestions.create(
      TransferSuggestion(transactionIds: [UUID(), UUID()], suggestedAt: older))
    _ = try await backend.transferSuggestions.create(
      TransferSuggestion(transactionIds: [UUID(), UUID()], suggestedAt: newer))

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: InsightInputSnapshot(), context: context(now: now))

    #expect(input.pendingTransferCount == 2)
    #expect(input.oldestPendingTransferDate == older)
  }

  // MARK: - snapshot pass-through

  @Test("snapshot pass-through fields appear unchanged on the result")
  func snapshotPassThrough() async throws {
    let backend = try CloudKitAnalysisTestBackend()
    let now = try AnalysisTestHelpers.utcDate(year: 2026, month: 6, day: 15)
    let category = Category(name: "Groceries")
    let categories = Categories(from: [category])
    let earmark = EarmarkSnapshot(
      id: UUID(), name: "Holiday", balance: InstrumentAmount(quantity: 500, instrument: aud))
    let group = InsightAccountGroup(id: UUID(), name: "Everyday")
    let accountId = UUID()
    let membership: [UUID: UUID] = [accountId: group.id]
    let snapshot = InsightInputSnapshot(
      earmarks: [earmark],
      categories: categories,
      accountGroups: [group],
      accountGroupMembership: membership)

    let input = try await InsightInputBuilder(backend: backend).build(
      snapshot: snapshot, context: context(now: now))

    #expect(input.earmarks == [earmark])
    #expect(input.accountGroups == [group])
    #expect(input.accountGroupMembership == membership)
    #expect(input.categories.by(id: category.id)?.name == "Groceries")
    #expect(input.monthly.isEmpty)
    #expect(input.expenseBreakdown.isEmpty)
    #expect(input.dailyBalances.isEmpty)
    #expect(input.profitLoss.isEmpty)
    #expect(input.capitalGains.isEmpty)
  }
}
