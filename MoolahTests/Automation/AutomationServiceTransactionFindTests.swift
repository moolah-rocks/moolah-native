import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Transaction Find Filters")
@MainActor
struct AutomationServiceTransactionFindTests {
  @Test("findTransactions filters by stable account id")
  func findTransactionsByAccountId() async throws {
    let (service, _) = try await AutomationTestSession.make()

    let checking = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)
    _ = try await service.createAccount(profileIdentifier: "Test", name: "Savings", type: .bank)

    try await createTransaction(service, payee: "Checking Store", account: "Checking")
    try await createTransaction(service, payee: "Savings Store", account: "Savings")

    let transactions = try await service.findTransactions(
      profileIdentifier: "Test",
      accountId: checking.id)

    #expect(transactions.map(\.payee) == ["Checking Store"])
  }

  @Test("findTransactions filters by stable category id")
  func findTransactionsByCategoryId() async throws {
    let (service, _) = try await AutomationTestSession.make()

    _ = try await service.createAccount(profileIdentifier: "Test", name: "Checking", type: .bank)
    let groceries = try await service.createCategory(profileIdentifier: "Test", name: "Groceries")
    _ = try await service.createCategory(profileIdentifier: "Test", name: "Transport")

    try await createTransaction(
      service, payee: "Grocer", account: "Checking", category: "Groceries")
    try await createTransaction(
      service, payee: "Train", account: "Checking", category: "Transport")

    let transactions = try await service.findTransactions(
      profileIdentifier: "Test",
      categoryId: groceries.id)

    #expect(transactions.map(\.payee) == ["Grocer"])
  }

  @Test("findTransactions excludes the day after the inclusive upper bound")
  func findTransactionsExcludesDayAfterUpperBound() async throws {
    let (service, _) = try await AutomationTestSession.make()

    _ = try await service.createAccount(profileIdentifier: "Test", name: "Checking", type: .bank)
    try await createTransaction(
      service,
      payee: "Upper Bound Evening",
      account: "Checking",
      date: try date(year: 2026, month: 1, day: 20, hour: 23))
    try await createTransaction(
      service,
      payee: "Next Day Midnight",
      account: "Checking",
      date: try date(year: 2026, month: 1, day: 21))

    let transactions = try await service.findTransactions(
      profileIdentifier: "Test",
      fromDate: try date(year: 2026, month: 1, day: 20),
      toDate: try date(year: 2026, month: 1, day: 20))

    #expect(transactions.map(\.payee) == ["Upper Bound Evening"])
  }

  @Test("findTransactions rejects a missing account id")
  func findTransactionsRejectsMissingAccountId() async throws {
    let (service, _) = try await AutomationTestSession.make()
    let id = UUID()

    await expectAccountNotFound(id.uuidString) {
      _ = try await service.findTransactions(
        profileIdentifier: "Test",
        accountId: id)
    }
  }

  @Test("findTransactions rejects a missing category id")
  func findTransactionsRejectsMissingCategoryId() async throws {
    let (service, _) = try await AutomationTestSession.make()
    let id = UUID()

    await expectCategoryNotFound(id.uuidString) {
      _ = try await service.findTransactions(
        profileIdentifier: "Test",
        categoryId: id)
    }
  }

  @Test("findTransactions rejects ambiguous account names")
  func findTransactionsRejectsAmbiguousAccountName() async throws {
    let (service, session) = try await AutomationTestSession.make()
    let instrument = session.profile.instrument
    _ = try await session.backend.accounts.create(
      Account(name: "Duplicate", type: .bank, instrument: instrument, position: 0))
    _ = try await session.backend.accounts.create(
      Account(name: "Duplicate", type: .bank, instrument: instrument, position: 1))

    await expectInvalidParameter("Ambiguous account name 'Duplicate'; use account id.") {
      _ = try await service.findTransactions(
        profileIdentifier: "Test",
        accountName: "Duplicate")
    }
  }

  @Test("findTransactions rejects ambiguous category names")
  func findTransactionsRejectsAmbiguousCategoryName() async throws {
    let (service, _) = try await AutomationTestSession.make()
    _ = try await service.createCategory(profileIdentifier: "Test", name: "Food")
    _ = try await service.createCategory(profileIdentifier: "Test", name: "Bills")
    _ = try await service.createCategory(
      profileIdentifier: "Test", name: "Shared", parentName: "Food")
    _ = try await service.createCategory(
      profileIdentifier: "Test", name: "Shared", parentName: "Bills")

    await expectInvalidParameter(
      "Ambiguous category name 'Shared'; use category id or full path."
    ) {
      _ = try await service.findTransactions(
        profileIdentifier: "Test",
        categoryName: "Shared")
    }
  }

  @Test("findTransactions rejects account name and id together")
  func findTransactionsRejectsAccountNameAndIdTogether() async throws {
    let (service, _) = try await AutomationTestSession.make()

    await expectInvalidParameter("Use either account or account id, not both.") {
      _ = try await service.findTransactions(
        profileIdentifier: "Test",
        accountName: "Checking",
        accountId: UUID())
    }
  }

  @Test("findTransactions rejects category name and id together")
  func findTransactionsRejectsCategoryNameAndIdTogether() async throws {
    let (service, _) = try await AutomationTestSession.make()

    await expectInvalidParameter("Use either category or category id, not both.") {
      _ = try await service.findTransactions(
        profileIdentifier: "Test",
        categoryName: "Groceries",
        categoryId: UUID())
    }
  }

  @Test("findTransactions rejects reversed date bounds with a clear error")
  func findTransactionsRejectsReversedDateBoundsWithClearError() async throws {
    let (service, _) = try await AutomationTestSession.make()

    await expectInvalidParameter("from date must be on or before to date") {
      _ = try await service.findTransactions(
        profileIdentifier: "Test",
        fromDate: try date(year: 2026, month: 1, day: 21),
        toDate: try date(year: 2026, month: 1, day: 20))
    }
  }

  @Test("findLegs filters matching legs by stable ids")
  func findLegsFiltersByStableIds() async throws {
    let (service, session) = try await AutomationTestSession.make()

    let checking = try await service.createAccount(
      profileIdentifier: "Test", name: "Checking", type: .bank)
    let savings = try await service.createAccount(
      profileIdentifier: "Test", name: "Savings", type: .bank)
    let groceries = try await service.createCategory(profileIdentifier: "Test", name: "Groceries")
    let transfer = Transaction(
      date: try date(year: 2026, month: 1, day: 12),
      payee: "Split",
      legs: [
        TransactionLeg(
          accountId: checking.id,
          instrument: session.profile.instrument,
          quantity: -40,
          type: .expense,
          categoryId: groceries.id),
        TransactionLeg(
          accountId: savings.id,
          instrument: session.profile.instrument,
          quantity: 40,
          type: .expense,
          categoryId: groceries.id),
      ])
    _ = try await session.backend.transactions.create(transfer)

    let legs = try await service.findLegs(
      profileIdentifier: "Test",
      accountId: checking.id,
      categoryId: groceries.id,
      fromDate: try date(year: 2026, month: 1, day: 1),
      toDate: try date(year: 2026, month: 1, day: 31))

    #expect(legs.count == 1)
    #expect(legs.first?.transaction.payee == "Split")
    #expect(legs.first?.leg.accountId == checking.id)
    #expect(legs.first?.leg.categoryId == groceries.id)
  }

  @Test("findLegs excludes the day after the inclusive upper bound")
  func findLegsExcludesDayAfterUpperBound() async throws {
    let (service, _) = try await AutomationTestSession.make()

    _ = try await service.createAccount(profileIdentifier: "Test", name: "Checking", type: .bank)
    try await createTransaction(
      service,
      payee: "Upper Bound Evening",
      account: "Checking",
      date: try date(year: 2026, month: 1, day: 20, hour: 23))
    try await createTransaction(
      service,
      payee: "Next Day Midnight",
      account: "Checking",
      date: try date(year: 2026, month: 1, day: 21))

    let legs = try await service.findLegs(
      profileIdentifier: "Test",
      fromDate: try date(year: 2026, month: 1, day: 20),
      toDate: try date(year: 2026, month: 1, day: 20))

    #expect(legs.map(\.transaction.payee) == ["Upper Bound Evening"])
  }

  @Test("findLegs rejects reversed date bounds")
  func findLegsRejectsReversedDateBounds() async throws {
    let (service, _) = try await AutomationTestSession.make()

    await expectInvalidParameter("from date must be on or before to date") {
      _ = try await service.findLegs(
        profileIdentifier: "Test",
        fromDate: try date(year: 2026, month: 1, day: 21),
        toDate: try date(year: 2026, month: 1, day: 20))
    }
  }
}

extension AutomationServiceTransactionFindTests {
  fileprivate func expectAccountNotFound(
    _ expected: String,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Expected accountNotFound(\(expected))")
    } catch AutomationError.accountNotFound(let actual) {
      #expect(actual == expected)
    } catch {
      Issue.record("Expected accountNotFound(\(expected)), got \(error)")
    }
  }

  fileprivate func expectCategoryNotFound(
    _ expected: String,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Expected categoryNotFound(\(expected))")
    } catch AutomationError.categoryNotFound(let actual) {
      #expect(actual == expected)
    } catch {
      Issue.record("Expected categoryNotFound(\(expected)), got \(error)")
    }
  }

  fileprivate func expectInvalidParameter(
    _ expected: String,
    operation: () async throws -> Void
  ) async {
    do {
      try await operation()
      Issue.record("Expected invalidParameter(\(expected))")
    } catch AutomationError.invalidParameter(let actual) {
      #expect(actual == expected)
    } catch {
      Issue.record("Expected invalidParameter(\(expected)), got \(error)")
    }
  }

  fileprivate func createTransaction(
    _ service: AutomationService,
    payee: String,
    account: String,
    category: String? = nil,
    date: Date? = nil
  ) async throws {
    let transactionDate: Date
    if let date {
      transactionDate = date
    } else {
      transactionDate = try Self.date(year: 2026, month: 1, day: 5)
    }

    _ = try await service.createTransaction(
      profileIdentifier: "Test",
      payee: payee,
      date: transactionDate,
      legs: [
        AutomationService.LegSpec(
          accountName: account,
          amount: -25,
          categoryName: category,
          earmarkName: nil)
      ])
  }

  fileprivate static func date(year: Int, month: Int, day: Int, hour: Int = 0) throws -> Date {
    try #require(
      Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour)))
  }

  fileprivate func date(year: Int, month: Int, day: Int, hour: Int = 0) throws -> Date {
    try Self.date(year: year, month: month, day: day, hour: hour)
  }
}
