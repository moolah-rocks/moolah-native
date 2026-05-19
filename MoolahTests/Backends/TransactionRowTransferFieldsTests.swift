import Foundation
import Testing

@testable import Moolah

@Suite("TransactionRow ⇄ import-origin fields")
struct TransactionRowTransferFieldsTests {
  private func origin(_ tag: String) -> ImportOrigin {
    ImportOrigin(
      rawDescription: tag, rawAmount: 3, importedAt: Date(timeIntervalSince1970: 10),
      importSessionId: UUID(), parserIdentifier: "p-\(tag)")
  }

  @Test("single origin round-trips")
  func single() throws {
    let leg = TransactionLeg(
      accountId: UUID(), instrument: .defaultTestInstrument, quantity: -5, type: .expense)
    var transaction = Transaction(date: Date(timeIntervalSince1970: 1), legs: [leg])
    transaction.importOrigin = .single(origin("a"))
    let back = try TransactionRow(domain: transaction).toDomain(legs: transaction.legs)
    #expect(back.importOrigin == transaction.importOrigin)
  }

  @Test("merged origin round-trips both sides")
  func merged() throws {
    let leg = TransactionLeg(
      accountId: UUID(), instrument: .defaultTestInstrument, quantity: 5, type: .transfer)
    var transaction = Transaction(date: Date(timeIntervalSince1970: 1), legs: [leg])
    transaction.importOrigin = .merged(
      MergedImportOrigin(outgoing: origin("out"), incoming: origin("in")))
    let back = try TransactionRow(domain: transaction).toDomain(legs: transaction.legs)
    #expect(back.importOrigin == transaction.importOrigin)
  }

  @Test("legacy NULL kind with populated origin columns reads as .single")
  func legacyNilKindIsSingle() throws {
    let leg = TransactionLeg(
      accountId: UUID(), instrument: .defaultTestInstrument, quantity: -5, type: .expense)
    let transaction = Transaction(date: Date(timeIntervalSince1970: 1), legs: [leg])
    var row = TransactionRow(domain: transaction)  // no importOrigin set
    row.importOriginKind = nil  // pre-v12 shape
    row.importOriginRawDescription = "legacy"
    row.importOriginRawAmount = "7"
    row.importOriginImportedAt = Date(timeIntervalSince1970: 0)
    row.importOriginImportSessionId = UUID()
    row.importOriginParserIdentifier = "p"
    let back = try row.toDomain(legs: transaction.legs)
    #expect(back.importOrigin?.singleOrigin?.rawDescription == "legacy")
  }
}
