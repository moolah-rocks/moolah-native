import Foundation
import Testing

@testable import Moolah

/// Contract tests for `TransactionRepository.countNeedsReview()`.
///
/// "Needs review" = a posted (`recur_period IS NULL`) transaction with at
/// least one income/expense leg and no categorised income/expense leg.
@Suite("TransactionRepository — countNeedsReview")
struct CountNeedsReviewContractTests {
  private let accountId = UUID()

  // MARK: - Scenarios

  @Test("posted transaction with all legs uncategorised counts as needs-review")
  func testAllUncategorisedPostedCounts() async throws {
    let uncategorised = makePosted(payee: "Uncategorised", categoryId: nil)
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: [uncategorised])

    let count = try await repository.countNeedsReview()

    #expect(count == 1)
  }

  @Test("posted transaction with at least one categorised leg does not count")
  func testPartiallyCategorisedPostedDoesNotCount() async throws {
    let categoryId = UUID()
    let partiallyCategorised = makePostedTwoLeg(
      payee: "Partial",
      firstCategoryId: categoryId,
      secondCategoryId: nil)
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: [partiallyCategorised])

    let count = try await repository.countNeedsReview()

    #expect(count == 0)
  }

  @Test("posted transaction with all legs categorised does not count")
  func testFullyCategorisedPostedDoesNotCount() async throws {
    let categoryId = UUID()
    let fullyCategorised = makePosted(payee: "Categorised", categoryId: categoryId)
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: [fullyCategorised])

    let count = try await repository.countNeedsReview()

    #expect(count == 0)
  }

  @Test("scheduled (recur_period non-null) all-uncategorised transaction does not count")
  func testScheduledAllUncategorisedDoesNotCount() async throws {
    let scheduled = makeScheduled(payee: "Scheduled Uncategorised")
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: [scheduled])

    let count = try await repository.countNeedsReview()

    #expect(count == 0)
  }

  @Test("posted transfer without a category action does not count")
  func testTransferDoesNotCount() async throws {
    let transfer = Transaction(
      date: Date(timeIntervalSinceReferenceDate: 0),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: Decimal(-10),
          type: .transfer)
      ])
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: [transfer])

    #expect(try await repository.countNeedsReview() == 0)
  }

  @Test("count equals number of posted all-uncategorised transactions across a mixed set")
  func testCountEqualsExpectedAcrossMixedSet() async throws {
    let categoryId = UUID()
    let needsReview1 = makePosted(payee: "Needs Review A", categoryId: nil)
    let needsReview2 = makePosted(payee: "Needs Review B", categoryId: nil)
    let categorised = makePosted(payee: "Categorised", categoryId: categoryId)
    let partial = makePostedTwoLeg(
      payee: "Partial",
      firstCategoryId: categoryId,
      secondCategoryId: nil)
    let scheduled = makeScheduled(payee: "Scheduled")
    let repository = try makeContractCloudKitTransactionRepository(
      initialTransactions: [needsReview1, needsReview2, categorised, partial, scheduled])

    let count = try await repository.countNeedsReview()

    #expect(count == 2)
  }

  @Test("empty database returns zero")
  func testEmptyDatabaseReturnsZero() async throws {
    let repository = try makeContractCloudKitTransactionRepository()

    let count = try await repository.countNeedsReview()

    #expect(count == 0)
  }

  @Test("spam-only transaction does not count")
  func testSpamOnlyDoesNotCount() async throws {
    let spam = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x0000000000000000000000000000000000000001",
      symbol: "SPAM",
      name: "Spam",
      decimals: 18)
    let (backend, _) = try TestBackend.create()
    try await TestBackend.register(spam, in: backend)
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceReferenceDate: 0),
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: spam,
            quantity: -10,
            type: .expense)
        ]))

    let count = try await backend.transactions.countNeedsReview(
      excludingInstrumentIds: [spam.id])

    #expect(count == 0)
  }

  @Test("mixed spam and non-spam transaction still counts")
  func testMixedSpamStillCounts() async throws {
    let spam = Instrument.crypto(
      chainId: 1,
      contractAddress: "0x0000000000000000000000000000000000000002",
      symbol: "SPAM",
      name: "Spam",
      decimals: 18)
    let (backend, _) = try TestBackend.create()
    try await TestBackend.register(spam, in: backend)
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(timeIntervalSinceReferenceDate: 0),
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: spam,
            quantity: -10,
            type: .expense),
          TransactionLeg(
            accountId: accountId,
            instrument: .AUD,
            quantity: -1,
            type: .expense),
        ]))

    let count = try await backend.transactions.countNeedsReview(
      excludingInstrumentIds: [spam.id])

    #expect(count == 1)
  }

  // MARK: - Fixtures

  private func makePosted(payee: String, categoryId: UUID?) -> Transaction {
    Transaction(
      date: Date(timeIntervalSinceReferenceDate: 0),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: Decimal(-10),
          type: .expense,
          categoryId: categoryId)
      ]
    )
  }

  private func makePostedTwoLeg(
    payee: String,
    firstCategoryId: UUID?,
    secondCategoryId: UUID?
  ) -> Transaction {
    Transaction(
      date: Date(timeIntervalSinceReferenceDate: 0),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: Decimal(-10),
          type: .expense,
          categoryId: firstCategoryId),
        TransactionLeg(
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: Decimal(-5),
          type: .expense,
          categoryId: secondCategoryId),
      ]
    )
  }

  private func makeScheduled(payee: String) -> Transaction {
    Transaction(
      date: Date(timeIntervalSinceReferenceDate: 0),
      payee: payee,
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .defaultTestInstrument,
          quantity: Decimal(-10),
          type: .expense,
          categoryId: nil)
      ]
    )
  }
}
