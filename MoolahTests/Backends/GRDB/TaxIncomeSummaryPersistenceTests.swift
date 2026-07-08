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
}

struct TaxIncomeFixture {
  let database: any DatabaseWriter
  let accounts: GRDBAccountRepository
  let categories: GRDBCategoryRepository
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
  let account = Account(
    id: UUID(),
    name: "Cash",
    type: .bank,
    instrument: .AUD)
  return TaxIncomeFixture(
    database: database,
    accounts: accounts,
    categories: categories,
    analysis: analysis,
    account: account,
    defaultOwner: UUID(),
    date: Date(timeIntervalSince1970: 1_735_689_600))
}

func insertTaxTransaction(
  _ database: any DatabaseWriter,
  accountId: UUID,
  legs: [TaxTestLeg]
) async throws {
  let transaction = Transaction(
    date: Date(timeIntervalSince1970: 1_735_689_600),
    payee: "Tax row",
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
