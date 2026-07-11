import Foundation
import GRDB

@testable import Moolah

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
