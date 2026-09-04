import Foundation
import Testing

@testable import Moolah

@Suite("Transaction needs review")
struct TransactionNeedsReviewTests {
  @Test("uncategorised expense needs review until categorised")
  func uncategorisedExpenseNeedsReviewUntilCategorised() {
    let accountId = UUID()
    var transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: -10,
          type: .expense)
      ])

    #expect(transaction.needsReview)

    transaction.legs[0].categoryId = UUID()
    #expect(!transaction.needsReview)
  }

  @Test("transaction types without a category action do not need review")
  func nonCategorizableTypesDoNotNeedReview() {
    let accountId = UUID()
    for type in [TransactionType.transfer, .trade, .openingBalance] {
      let transaction = Transaction(
        date: Date(),
        legs: [
          TransactionLeg(
            accountId: accountId,
            instrument: .AUD,
            quantity: 10,
            type: type)
        ])
      #expect(!transaction.needsReview)
    }
  }

  @Test("uncategorised trade fee needs review")
  func uncategorisedTradeFeeNeedsReview() {
    let accountId = UUID()
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: -100,
          type: .trade),
        TransactionLeg(
          accountId: accountId,
          instrument: .crypto(
            chainId: 1,
            contractAddress: nil,
            symbol: "ETH",
            name: "Ethereum",
            decimals: 8),
          quantity: 0.05,
          type: .trade),
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: -1,
          type: .expense),
      ])

    #expect(transaction.needsReview)
  }

  @Test("spam-only transaction does not need review")
  func spamOnlyTransactionDoesNotNeedReview() {
    let spam = Instrument.crypto(
      chainId: 1,
      contractAddress: "0xspam",
      symbol: "SPAM",
      name: "Spam Token",
      decimals: 18)
    let transaction = Transaction(
      date: Date(),
      legs: [
        TransactionLeg(
          accountId: UUID(),
          instrument: spam,
          quantity: 1_000_000,
          type: .income)
      ])

    #expect(!transaction.needsReview(excluding: [spam]))
  }
}
