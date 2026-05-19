import Foundation
import Testing

@testable import Moolah

@Suite("Transaction importOrigin accessors")
struct TransactionImportOriginAccessorTests {
  @Test("importOrigin defaults to nil and round-trips a .single origin")
  func defaults() {
    let leg = TransactionLeg(
      accountId: UUID(), instrument: .defaultTestInstrument, quantity: -10,
      type: .expense)
    var transaction = Transaction(date: Date(), legs: [leg])
    #expect(transaction.importOrigin == nil)
    let origin = ImportOrigin(
      rawDescription: "x", rawAmount: 10, importedAt: Date(),
      importSessionId: UUID(), parserIdentifier: "p")
    transaction.importOrigin = .single(origin)
    #expect(transaction.importOrigin?.singleOrigin == origin)
  }
}
