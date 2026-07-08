// MoolahTests/Backends/GRDB/TaxReportingPersistenceTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Tax reporting persistence")
struct TaxReportingPersistenceTests {
  @Test("profile schema creates tax reporting tables and columns")
  func profileSchemaCreatesTaxReportingStorage() throws {
    let database = try ProfileDatabase.openInMemory()
    try database.read { database in
      #expect(try database.tableExists("tax_owner"))
      #expect(try database.tableExists("account_tax_owner"))
      #expect(try database.tableExists("category_tax_owner"))

      let categoryColumns = try database.columns(in: "category").map(\.name)
      #expect(categoryColumns.contains("is_tax_reportable"))
      #expect(categoryColumns.contains("tax_owner_ids_encoded"))

      let accountColumns = try database.columns(in: "account").map(\.name)
      #expect(accountColumns.contains("tax_owner_ids_encoded"))
    }
  }

  @Test("profile index schema stores default tax owner id")
  func profileIndexSchemaStoresDefaultTaxOwnerId() throws {
    let database = try ProfileIndexDatabase.openInMemory()
    try database.read { database in
      let columns = try database.columns(in: "profile").map(\.name)
      #expect(columns.contains("default_tax_owner_id"))
    }
  }

  @Test("tax owner repository round-trips owners")
  func taxOwnerRepositoryRoundTripsOwners() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repository = GRDBTaxOwnerRepository(database: database)
    let owner = TaxOwner(id: UUID(), name: "Family Trust", kind: .trust)

    _ = try await repository.create(owner)
    let fetched = try #require(try await repository.fetchAll().first)
    #expect(fetched == owner)

    let updated = TaxOwner(id: owner.id, name: "Discretionary Trust", kind: .trust)
    _ = try await repository.update(updated)
    let refetched = try #require(try await repository.fetchAll().first)
    #expect(refetched == updated)

    try await repository.delete(id: owner.id)
    #expect(try await repository.fetchAll().isEmpty)
  }

  @Test("backend bootstrap creates default tax owner row")
  func backendBootstrapCreatesDefaultTaxOwner() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let profile = Profile(label: "Family")
    let backend = CloudKitBackend(
      database: database,
      instrument: profile.instrument,
      profileLabel: profile.label,
      defaultTaxOwnerId: profile.defaultTaxOwnerId,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentRegistry: registry)

    let owners = try await backend.taxOwners.fetchAll()

    #expect(owners.map(\.id) == [profile.defaultTaxOwnerId])
    #expect(owners.first?.name == "Default owner")
  }

  @Test("account repository round-trips tax owner ids through join rows")
  func accountRepositoryRoundTripsTaxOwnerIds() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repository = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let ownerA = UUID()
    let ownerB = UUID()
    let account = Account(
      id: UUID(),
      name: "Joint",
      type: .bank,
      instrument: .defaultTestInstrument,
      position: 0,
      taxOwnerIds: [ownerA, ownerB])

    _ = try await repository.create(account)
    let fetched = try await repository.fetchAll()
    #expect(fetched.first?.taxOwnerIds == [ownerA, ownerB])

    var updated = try #require(fetched.first)
    updated.taxOwnerIds = [ownerB]
    _ = try await repository.update(updated)
    let refetched = try await repository.fetchAll()
    #expect(refetched.first?.taxOwnerIds == [ownerB])
  }

  @Test("category repository round-trips tax treatment and owners")
  func categoryRepositoryRoundTripsTaxFields() async throws {
    let database = try ProfileDatabase.openInMemory()
    let repository = GRDBCategoryRepository(database: database)
    let owner = UUID()
    let category = Moolah.Category(
      id: UUID(),
      name: "Interest",
      isTaxReportable: true,
      taxOwnerIds: [owner])

    _ = try await repository.create(category)
    let fetched = try #require(try await repository.fetchAll().first)
    #expect(fetched.isTaxReportable)
    #expect(fetched.taxOwnerIds == [owner])

    var updated = fetched
    updated.isTaxReportable = false
    updated.taxOwnerIds = []
    _ = try await repository.update(updated)
    let refetched = try #require(try await repository.fetchAll().first)
    #expect(!refetched.isTaxReportable)
    #expect(refetched.taxOwnerIds.isEmpty)
  }

  @Test("deleting tax owner removes account and category references")
  func deletingTaxOwnerRemovesReferences() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let owner = TaxOwner(name: "Spouse")
    let taxOwners = GRDBTaxOwnerRepository(database: database)
    let accounts = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let categories = GRDBCategoryRepository(database: database)

    _ = try await taxOwners.create(owner)
    _ = try await accounts.create(
      Account(
        name: "Joint",
        type: .bank,
        instrument: .AUD,
        taxOwnerIds: [owner.id]))
    _ = try await categories.create(
      Moolah.Category(
        name: "Interest",
        isTaxReportable: true,
        taxOwnerIds: [owner.id]))

    try await taxOwners.delete(id: owner.id)

    let account = try #require(try await accounts.fetchAll().first)
    let category = try #require(try await categories.fetchAll().first)
    #expect(account.taxOwnerIds.isEmpty)
    #expect(category.taxOwnerIds.isEmpty)
    try await database.read { database in
      let accountJoinCount = try AccountTaxOwnerRow.fetchCount(database)
      let categoryJoinCount = try CategoryTaxOwnerRow.fetchCount(database)
      let accountEncoded = try String.fetchOne(
        database,
        sql: "SELECT tax_owner_ids_encoded FROM account LIMIT 1")
      let categoryEncoded = try String.fetchOne(
        database,
        sql: "SELECT tax_owner_ids_encoded FROM category LIMIT 1")
      #expect(accountJoinCount == 0)
      #expect(categoryJoinCount == 0)
      #expect(accountEncoded == nil)
      #expect(categoryEncoded == nil)
    }
  }

  @Test("remote tax owner delete removes account and category references")
  func remoteTaxOwnerDeleteRemovesReferences() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let owner = TaxOwner(name: "Trust")
    let taxOwners = GRDBTaxOwnerRepository(database: database)
    let accounts = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)
    let categories = GRDBCategoryRepository(database: database)

    _ = try await taxOwners.create(owner)
    _ = try await accounts.create(
      Account(
        name: "Trust brokerage",
        type: .investment,
        instrument: .AUD,
        taxOwnerIds: [owner.id]))
    _ = try await categories.create(
      Moolah.Category(
        name: "Distribution",
        isTaxReportable: true,
        taxOwnerIds: [owner.id]))

    try taxOwners.applyRemoteChangesSync(saved: [], deleted: [owner.id])

    let account = try #require(try await accounts.fetchAll().first)
    let category = try #require(try await categories.fetchAll().first)
    #expect(account.taxOwnerIds.isEmpty)
    #expect(category.taxOwnerIds.isEmpty)
  }

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
