import Foundation
import Testing

@testable import Moolah

@Suite("TransactionRepository — Filters")
struct TransactionRepositoryFilterTests {
  @Test("filters by date range")
  func testFiltersByDateRange() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makeContractTestTransactions())
    let calendar = Calendar.current
    let middleDate = try #require(
      calendar.date(from: DateComponents(year: 2024, month: 6, day: 15)))
    let startDate = try #require(calendar.date(byAdding: .day, value: -30, to: middleDate))
    let endDate = try #require(calendar.date(byAdding: .day, value: 30, to: middleDate))
    let dateRange = startDate...endDate

    let page = try await repository.fetch(
      filter: TransactionFilter(dateRange: dateRange),
      page: 0,
      pageSize: 50
    )

    // Should only include transactions within the date range
    for transaction in page.transactions {
      #expect(dateRange.contains(transaction.date))
    }
  }

  @Test("filters by category IDs")
  func testFiltersByCategoryIds() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makeContractTestTransactions())
    let transactions = try makeContractTestTransactions()
    let firstCategoryLeg = try #require(transactions[0].legs.first(where: { $0.categoryId != nil }))
    let groceryCategory = try #require(firstCategoryLeg.categoryId)
    let categoryIds: Set<UUID> = [groceryCategory]

    let page = try await repository.fetch(
      filter: TransactionFilter(categoryIds: categoryIds),
      page: 0,
      pageSize: 50
    )

    // Should only include transactions with the specified category
    for transaction in page.transactions {
      #expect(transaction.legs.contains(where: { categoryIds.contains($0.categoryId ?? UUID()) }))
    }
  }

  @Test("filters by payee (case-insensitive contains)")
  func testFiltersByPayee() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makeContractTestTransactions())
    let page = try await repository.fetch(
      filter: TransactionFilter(payee: "wool"),
      page: 0,
      pageSize: 50
    )

    // Should include "Woolworths" (case-insensitive contains match)
    #expect(!page.transactions.isEmpty)
    for transaction in page.transactions {
      let payee = transaction.payee?.lowercased() ?? ""
      #expect(payee.contains("wool"))
    }
  }

  @Test("combines multiple filters")
  func testCombinesMultipleFilters() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makeContractTestTransactions())
    let transactions = try makeContractTestTransactions()
    let firstCategoryLeg = try #require(transactions[0].legs.first(where: { $0.categoryId != nil }))
    let groceryCategory = try #require(firstCategoryLeg.categoryId)
    let calendar = Calendar.current
    let middleDate = try #require(
      calendar.date(from: DateComponents(year: 2024, month: 6, day: 15)))
    let startDate = try #require(calendar.date(byAdding: .day, value: -30, to: middleDate))
    let endDate = try #require(calendar.date(byAdding: .day, value: 30, to: middleDate))

    let page = try await repository.fetch(
      filter: TransactionFilter(
        dateRange: startDate...endDate,
        categoryIds: [groceryCategory],
        payee: "wool"
      ),
      page: 0,
      pageSize: 50
    )

    // Should satisfy all filter criteria
    for transaction in page.transactions {
      #expect(transaction.legs.contains(where: { $0.categoryId == groceryCategory }))
      #expect((startDate...endDate).contains(transaction.date))
      let payee = transaction.payee?.lowercased() ?? ""
      #expect(payee.contains("wool"))
    }
  }

  @Test("filters by uncategorisedLegType (type-scoped)")
  func testFiltersByUncategorizedLegType() async throws {
    let accountId = UUID()
    let categoryId = UUID()
    let date = try #require(
      Calendar.current.date(from: DateComponents(year: 2024, month: 6, day: 15)))

    let uncategorisedIncome = Transaction(
      date: date, payee: "Uncategorised Income",
      legs: [
        makeContractTestLeg(
          accountId: accountId, quantity: try #require(Decimal(string: "100.00")),
          type: .income)
      ])
    let uncategorisedExpense = Transaction(
      date: date, payee: "Uncategorised Expense",
      legs: [
        makeContractTestLeg(
          accountId: accountId, quantity: try #require(Decimal(string: "-50.00")),
          type: .expense)
      ])
    let categorisedIncome = Transaction(
      date: date, payee: "Categorised Income",
      legs: [
        makeContractTestLeg(
          accountId: accountId, quantity: try #require(Decimal(string: "200.00")),
          type: .income, categoryId: categoryId)
      ])

    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: [uncategorisedIncome, uncategorisedExpense, categorisedIncome])

    let incomePage = try await repository.fetch(
      filter: TransactionFilter(uncategorisedLegType: .income),
      page: 0,
      pageSize: 50
    )
    #expect(incomePage.transactions.count == 1)
    #expect(incomePage.transactions.first?.payee == "Uncategorised Income")

    let expensePage = try await repository.fetch(
      filter: TransactionFilter(uncategorisedLegType: .expense),
      page: 0,
      pageSize: 50
    )
    #expect(expensePage.transactions.count == 1)
    #expect(expensePage.transactions.first?.payee == "Uncategorised Expense")
  }

  @Test("returns empty when no matches")
  func testReturnsEmptyWhenNoMatches() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makeContractTestTransactions())
    let page = try await repository.fetch(
      filter: TransactionFilter(payee: "NonexistentPayee"),
      page: 0,
      pageSize: 50
    )

    #expect(page.transactions.isEmpty)
  }

  @Test("clearing filter reloads all")
  func testClearingFilterReloadsAll() async throws {
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: try makeContractTestTransactions())
    // First apply a filter
    let filteredPage = try await repository.fetch(
      filter: TransactionFilter(payee: "Woolworths"),
      page: 0,
      pageSize: 50
    )

    // Then clear the filter
    let allPage = try await repository.fetch(
      filter: TransactionFilter(),
      page: 0,
      pageSize: 50
    )

    #expect(allPage.transactions.count >= filteredPage.transactions.count)
  }
}
