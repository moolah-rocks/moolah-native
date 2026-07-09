// MoolahTests/Backends/GRDB/TaxIncomeSummaryPersistenceTests.swift

import Foundation
import GRDB
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

struct TaxIncomeFixture {
  let database: any DatabaseWriter
  let accounts: GRDBAccountRepository
  let categories: GRDBCategoryRepository
  let transactions: GRDBTransactionRepository
  let analysis: GRDBAnalysisRepository
  let account: Account
  let defaultOwner: UUID
  let date: Date
}

struct TaxTestLeg {
  let amount: Decimal
  let type: TransactionType
  let categoryId: UUID
  let instrument: Instrument

  init(
    _ amount: Decimal,
    _ type: TransactionType,
    _ categoryId: UUID,
    instrument: Instrument = .AUD
  ) {
    self.amount = amount
    self.type = type
    self.categoryId = categoryId
    self.instrument = instrument
  }
}

struct TaxReportableTransactionFilterFixture {
  let fixture: TaxIncomeFixture
  let accountOwner: UUID
}

func makeTaxReportableTransactionFilterFixture() async throws
  -> TaxReportableTransactionFilterFixture
{
  let fixture = try await makeTaxIncomeFixture()
  let accountOwner = UUID()
  let categoryOwner = UUID()
  var account = fixture.account
  account.taxOwnerIds = [accountOwner]
  _ = try await fixture.accounts.create(account)
  let accountOwned = try await fixture.categories.create(
    Moolah.Category(name: "Interest", isTaxReportable: true))
  let categoryOwned = try await fixture.categories.create(
    Moolah.Category(
      name: "Distribution",
      isTaxReportable: true,
      taxOwnerIds: [categoryOwner]))
  let ignored = try await fixture.categories.create(
    Moolah.Category(name: "Gift", isTaxReportable: false))
  try await insertTaxTransaction(
    fixture.database,
    accountId: account.id,
    payee: "Account owner income",
    legs: [TaxTestLeg(100, .income, accountOwned.id)])
  try await insertTaxTransaction(
    fixture.database,
    accountId: account.id,
    payee: "Category owner income",
    legs: [TaxTestLeg(200, .income, categoryOwned.id)])
  try await insertTaxTransaction(
    fixture.database,
    accountId: account.id,
    payee: "Account owner deduction",
    legs: [TaxTestLeg(-30, .expense, accountOwned.id)])
  try await insertTaxTransaction(
    fixture.database,
    accountId: account.id,
    payee: "Ignored income",
    legs: [TaxTestLeg(999, .income, ignored.id)])
  return TaxReportableTransactionFilterFixture(fixture: fixture, accountOwner: accountOwner)
}

func makeTaxIncomeFixture(
  conversionService: any InstrumentConversionService = FakeConversionService.fixedRates([:])
) async throws -> TaxIncomeFixture {
  let database = try ProfileDatabase.openInMemory()
  let registry = try SharedRegistryTestSupport.makeSharedRegistry()
  let accounts = GRDBAccountRepository(
    database: database,
    instrumentResolver: registry,
    instrumentRegistrar: registry)
  let categories = GRDBCategoryRepository(database: database)
  let analysis = GRDBAnalysisRepository(
    database: database,
    instrument: .AUD,
    conversionService: conversionService,
    instrumentResolver: registry)
  let transactions = GRDBTransactionRepository(
    database: database,
    defaultInstrument: .AUD,
    conversionService: conversionService,
    instrumentResolver: registry,
    instrumentRegistrar: registry)
  let account = Account(
    id: UUID(),
    name: "Cash",
    type: .bank,
    instrument: .AUD)
  return TaxIncomeFixture(
    database: database,
    accounts: accounts,
    categories: categories,
    transactions: transactions,
    analysis: analysis,
    account: account,
    defaultOwner: UUID(),
    date: Date(timeIntervalSince1970: 1_735_689_600))
}

func insertTaxTransaction(
  _ database: any DatabaseWriter,
  accountId: UUID,
  payee: String = "Tax row",
  date: Date = Date(timeIntervalSince1970: 1_735_689_600),
  legs: [TaxTestLeg]
) async throws {
  let transaction = Transaction(
    date: date,
    payee: payee,
    legs: legs.map { leg in
      TransactionLeg(
        accountId: accountId,
        instrument: leg.instrument,
        quantity: leg.amount,
        type: leg.type,
        categoryId: leg.categoryId)
    })
  try await database.write { database in
    try TransactionRow(domain: transaction).insert(database)
    for (offset, leg) in transaction.legs.enumerated() {
      try TransactionLegRow(domain: leg, transactionId: transaction.id, sortOrder: offset)
        .insert(database)
    }
  }
}
