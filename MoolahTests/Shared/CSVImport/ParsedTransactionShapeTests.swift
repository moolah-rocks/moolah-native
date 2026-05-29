import Foundation
import Testing

@testable import Moolah

@Suite("ParsedTransaction types")
struct ParsedTransactionShapeTests {

  @Test("ParsedTransaction carries rawRow, rawDescription, legs, and a bank reference")
  func parsedTransactionInit() {
    let transaction = ParsedTransaction(
      date: Date(timeIntervalSince1970: 0),
      legs: [
        ParsedLeg(
          accountId: nil,
          instrument: .AUD,
          quantity: dec("-12.34"),
          type: .expense)
      ],
      rawRow: ["2024-01-01", "-12.34", "Coffee"],
      rawDescription: "Coffee",
      rawAmount: dec("-12.34"),
      rawBalance: nil,
      bankReference: "REF-1")
    #expect(transaction.legs.count == 1)
    #expect(transaction.bankReference == "REF-1")
    #expect(transaction.legs.first?.accountId == nil)
    #expect(transaction.legs.first?.instrument == .AUD)
  }

  @Test("ParsedRecord round-trips a .transaction and a .skip")
  func parsedRecordCases() {
    let transaction = ParsedTransaction(
      date: Date(timeIntervalSince1970: 0),
      legs: [],
      rawRow: [],
      rawDescription: "",
      rawAmount: 0,
      rawBalance: nil,
      bankReference: nil)
    let wrapped = ParsedRecord.transaction(transaction)
    let skip = ParsedRecord.skip(reason: "summary row")
    if case .transaction(let unwrapped) = wrapped {
      #expect(unwrapped == transaction)
    } else {
      Issue.record("expected .transaction case")
    }
    if case .skip(let reason) = skip {
      #expect(reason == "summary row")
    } else {
      Issue.record("expected .skip case")
    }
  }

  @Test("CSVParserError.malformedRow carries the row index, reason, and row")
  func csvParserErrorShape() {
    let error = CSVParserError.malformedRow(
      index: 7, reason: "unparseable amount", row: ["a", "b", "c"])
    if case let .malformedRow(index, reason, row) = error {
      #expect(index == 7)
      #expect(reason == "unparseable amount")
      #expect(row == ["a", "b", "c"])
    } else {
      Issue.record("expected .malformedRow")
    }
  }
}
