import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Transaction Operations")
@MainActor
struct AutomationServiceTransactionTests {
  private struct TransactionFixture {
    let payee: String
    let date: Date
    let accountName: String
    let amount: Decimal
    let categoryName: String?
  }

  private struct OpenSessionFailed: Error {}

  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(
      containerManager: containerManager,
      profileIndexRepository: containerManager.profileIndexRepositoryForTesting)
    let profile = Profile(
      label: "Test",
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    guard case .ready(let session) = await sessionManager.session(for: profile) else {
      Issue.record("expected .ready")
      throw OpenSessionFailed()
    }
    // AccountStore, EarmarkStore, and CategoryStore are all reactive
    // — wait for the first emission so any pre-seeded rows are visible.
    try await session.accountStore.waitForFirstEmission()
    try await session.earmarkStore.waitForFirstEmission()
    try await session.categoryStore.waitForFirstEmission()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("createTransaction creates a single-leg transaction")
  func createSingleLegTransaction() async throws {
    let (service, _) = try await makeServiceWithSession()

    // Create an account first. `createTransaction` resolves the account
    // from the authoritative repository snapshot, so there's no need to
    // wait on the reactive `accountStore` before referencing it.
    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )

    let transaction = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Grocery Store",
      date: Date(),
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: -50,
          categoryName: nil,
          earmarkName: nil
        )
      ],
      notes: "Weekly shopping"
    )

    #expect(transaction.payee == "Grocery Store")
    #expect(transaction.notes == "Weekly shopping")
    #expect(transaction.legs.count == 1)
    #expect(transaction.legs.first?.quantity == -50)
    #expect(transaction.legs.first?.type == .expense)
  }

  @Test("listTransactions returns created transactions")
  func listTransactions() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )

    _ = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Store A",
      date: Date(),
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: -25,
          categoryName: nil,
          earmarkName: nil
        )
      ]
    )

    let transactions = try await service.listTransactions(profileIdentifier: "Test")
    #expect(transactions.count == 1)
    #expect(transactions.first?.payee == "Store A")
  }

  @Test("findTransactions filters by account through the repository")
  func findTransactionsByAccount() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createAccount(profileIdentifier: "Test", name: "Checking", type: .bank)
    _ = try await service.createAccount(profileIdentifier: "Test", name: "Savings", type: .bank)

    _ = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Checking Store",
      date: try date(year: 2026, month: 1, day: 5),
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: -25,
          categoryName: nil,
          earmarkName: nil)
      ])
    _ = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Savings Store",
      date: try date(year: 2026, month: 1, day: 6),
      legs: [
        AutomationService.LegSpec(
          accountName: "Savings",
          amount: -30,
          categoryName: nil,
          earmarkName: nil)
      ])

    let transactions = try await service.findTransactions(
      profileIdentifier: "Test",
      accountName: "Checking")

    #expect(transactions.map(\.payee) == ["Checking Store"])
  }

  @Test("findTransactions combines account, inclusive date, and category filters")
  func findTransactionsWithCombinedFilters() async throws {
    let (service, _) = try await makeServiceWithSession()

    try await createFindTransactionFilterFixtures(service)

    let transactions = try await service.findTransactions(
      profileIdentifier: "Test",
      accountName: "Checking",
      categoryName: "Food:Groceries",
      fromDate: try date(year: 2026, month: 1, day: 10),
      toDate: try date(year: 2026, month: 1, day: 20))

    #expect(transactions.map(\.payee) == ["Upper Bound Groceries", "Matching Groceries"])
  }

  @Test("findTransactions rejects reversed date bounds")
  func findTransactionsRejectsReversedDateBounds() async throws {
    let (service, _) = try await makeServiceWithSession()
    let fromDate = try date(year: 2026, month: 1, day: 20)
    let toDate = try date(year: 2026, month: 1, day: 19)

    await #expect(throws: AutomationError.self) {
      _ = try await service.findTransactions(
        profileIdentifier: "Test",
        fromDate: fromDate,
        toDate: toDate)
    }
  }

  @Test("findTransactions filters scheduled state")
  func findTransactionsByScheduledState() async throws {
    let (service, session) = try await makeServiceWithSession()

    let account = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank)
    let dueDate = try date(year: 2026, month: 2, day: 1)
    _ = try await session.backend.transactions.create(
      Transaction(
        date: dueDate,
        payee: "Monthly Rent",
        recurPeriod: .month,
        recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: account.id,
            instrument: session.profile.instrument,
            quantity: -2500,
            type: .expense)
        ]))
    _ = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Posted Rent",
      date: dueDate,
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: -2500,
          categoryName: nil,
          earmarkName: nil)
      ])

    let scheduled = try await service.findTransactions(
      profileIdentifier: "Test",
      scheduled: .scheduledOnly)
    let posted = try await service.findTransactions(
      profileIdentifier: "Test",
      scheduled: .nonScheduledOnly)

    #expect(scheduled.map(\.payee) == ["Monthly Rent"])
    #expect(posted.map(\.payee) == ["Posted Rent"])
  }

  @Test("createTransaction with positive amount creates income")
  func createIncomeTransaction() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createAccount(
      profileIdentifier: "Test",
      name: "Checking",
      type: .bank
    )

    let transaction = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: "Employer",
      date: Date(),
      legs: [
        AutomationService.LegSpec(
          accountName: "Checking",
          amount: 3000,
          categoryName: nil,
          earmarkName: nil
        )
      ]
    )

    #expect(transaction.legs.first?.type == .income)
    #expect(transaction.legs.first?.quantity == 3000)
  }
}

extension AutomationServiceTransactionTests {
  private func date(year: Int, month: Int, day: Int, hour: Int = 0) throws -> Date {
    try #require(
      Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
  }

  private func createTransaction(
    _ service: AutomationService,
    fixture: TransactionFixture
  ) async throws {
    _ = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: fixture.payee,
      date: fixture.date,
      legs: [
        AutomationService.LegSpec(
          accountName: fixture.accountName,
          amount: fixture.amount,
          categoryName: fixture.categoryName,
          earmarkName: nil)
      ])
  }

  private func createFindTransactionFilterFixtures(_ service: AutomationService) async throws {
    _ = try await service.createAccount(profileIdentifier: "Test", name: "Checking", type: .bank)
    _ = try await service.createAccount(profileIdentifier: "Test", name: "Savings", type: .bank)
    _ = try await service.createCategory(profileIdentifier: "Test", name: "Food")
    _ = try await service.createCategory(
      profileIdentifier: "Test", name: "Groceries", parentName: "Food")
    _ = try await service.createCategory(profileIdentifier: "Test", name: "Transport")

    let fixtures = [
      TransactionFixture(
        payee: "Outside Date",
        date: try date(year: 2026, month: 1, day: 9),
        accountName: "Checking",
        amount: -20,
        categoryName: "Food:Groceries"),
      TransactionFixture(
        payee: "Matching Groceries",
        date: try date(year: 2026, month: 1, day: 10),
        accountName: "Checking",
        amount: -45,
        categoryName: "Food:Groceries"),
      TransactionFixture(
        payee: "Upper Bound Groceries",
        date: try date(year: 2026, month: 1, day: 20, hour: 12),
        accountName: "Checking",
        amount: -35,
        categoryName: "Food:Groceries"),
      TransactionFixture(
        payee: "Wrong Category",
        date: try date(year: 2026, month: 1, day: 15),
        accountName: "Checking",
        amount: -15,
        categoryName: "Transport"),
      TransactionFixture(
        payee: "Wrong Account",
        date: try date(year: 2026, month: 1, day: 20),
        accountName: "Savings",
        amount: -60,
        categoryName: "Food:Groceries"),
    ]

    for fixture in fixtures {
      try await createTransaction(service, fixture: fixture)
    }
  }
}
