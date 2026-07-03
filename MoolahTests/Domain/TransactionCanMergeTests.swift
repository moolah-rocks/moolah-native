import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.canMerge")
struct TransactionCanMergeTests {
  private let baseDate = Date(timeIntervalSince1970: 1_704_888_000)

  private func tx(
    date: Date, payee: String?, recurPeriod: RecurPeriod? = nil
  ) -> Transaction {
    Transaction(
      date: date, payee: payee, recurPeriod: recurPeriod,
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .defaultTestInstrument,
          quantity: -10, type: .expense)
      ])
  }

  @Test("two same-day same-payee transactions can merge")
  func happyPath() {
    #expect(
      Transaction.canMerge([
        tx(date: baseDate, payee: "Acme"), tx(date: baseDate, payee: "Acme"),
      ]))
  }

  @Test("a single transaction cannot merge")
  func single() {
    #expect(!Transaction.canMerge([tx(date: baseDate, payee: "Acme")]))
  }

  @Test("different payees cannot merge")
  func payees() {
    #expect(
      !Transaction.canMerge([
        tx(date: baseDate, payee: "Acme"), tx(date: baseDate, payee: "Other"),
      ]))
  }

  @Test("different days cannot merge")
  func days() {
    #expect(
      !Transaction.canMerge([
        tx(date: baseDate, payee: "Acme"),
        tx(date: baseDate.addingTimeInterval(86_400 * 2), payee: "Acme"),
      ]))
  }

  @Test("a scheduled transaction blocks the merge")
  func scheduled() {
    #expect(
      !Transaction.canMerge([
        tx(date: baseDate, payee: "Acme", recurPeriod: .month),
        tx(date: baseDate, payee: "Acme"),
      ]))
  }
}
