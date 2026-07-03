import Foundation
import Testing

@testable import Moolah

@Suite("TransactionMergeBuilder merge")
struct TransactionMergeBuilderTests {
  private let builder = TransactionMergeBuilder()

  // 2024-01-10 12:00:00 UTC.
  private let baseDate = Date(timeIntervalSince1970: 1_704_888_000)

  private func tx(
    id: UUID = UUID(),
    date: Date,
    payee: String?,
    notes: String? = nil,
    legs: [TransactionLeg],
    recurPeriod: RecurPeriod? = nil
  ) -> Transaction {
    Transaction(
      id: id, date: date, payee: payee, notes: notes, recurPeriod: recurPeriod, legs: legs)
  }

  private func leg(
    id: UUID = UUID(),
    account: UUID = UUID(),
    quantity: Decimal,
    type: TransactionType = .expense,
    externalId: String? = nil,
    counterpartyAddress: String? = nil,
    categoryId: UUID? = nil,
    earmarkId: UUID? = nil
  ) -> TransactionLeg {
    TransactionLeg(
      id: id, accountId: account, instrument: .defaultTestInstrument, quantity: quantity,
      externalId: externalId, counterpartyAddress: counterpartyAddress, type: type,
      categoryId: categoryId, earmarkId: earmarkId)
  }

  @Test("merged transaction unions all legs unchanged")
  func unionsLegs() throws {
    let legA = leg(quantity: -10)
    let legB = leg(quantity: -20)
    let legC = leg(quantity: -30)
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", legs: [legA, legB]),
      tx(date: baseDate, payee: "Acme", legs: [legC]),
    ])
    #expect(merged.legs == [legA, legB, legC])
  }

  @Test("merged transaction preserves each leg's identity fields")
  func preservesLegFields() throws {
    let cat = UUID()
    let mark = UUID()
    let legA = leg(
      quantity: -10, externalId: "ext-a", counterpartyAddress: "0xabc",
      categoryId: cat, earmarkId: mark)
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", legs: [legA]),
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -5)]),
    ])
    let carried = try #require(merged.legs.first { $0.id == legA.id })
    #expect(carried.externalId == "ext-a")
    #expect(carried.counterpartyAddress == "0xabc")
    #expect(carried.categoryId == cat)
    #expect(carried.earmarkId == mark)
    #expect(carried.quantity == -10)
  }

  @Test("merged transaction takes the earliest date and a fresh id")
  func earliestDateFreshId() throws {
    let later = baseDate.addingTimeInterval(3_600)
    let txA = tx(date: later, payee: "Acme", legs: [leg(quantity: -10)])
    let txB = tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -20)])
    let merged = try builder.merged([txA, txB])
    #expect(merged.date == baseDate)
    #expect(merged.id != txA.id)
    #expect(merged.id != txB.id)
  }

  @Test("merged transaction keeps the shared payee and drops importOrigin")
  func sharedPayeeNilOrigin() throws {
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)]),
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -20)]),
    ])
    #expect(merged.payee == "Acme")
    #expect(merged.importOrigin == nil)
    #expect(merged.recurPeriod == nil)
  }

  @Test("notes are newline-joined with duplicate lines dropped in order")
  func notesDedupJoined() throws {
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", notes: "shared\nfirst-only", legs: [leg(quantity: -10)]),
      tx(date: baseDate, payee: "Acme", notes: "shared\nsecond-only", legs: [leg(quantity: -20)]),
    ])
    #expect(merged.notes == "shared\nfirst-only\nsecond-only")
  }

  @Test("all-nil notes produce nil notes")
  func nilNotes() throws {
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)]),
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -20)]),
    ])
    #expect(merged.notes == nil)
  }

  @Test("three-way merge unions all legs")
  func threeWay() throws {
    let merged = try builder.merged([
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)]),
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -20)]),
      tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -30)]),
    ])
    #expect(merged.legs.count == 3)
  }

  @Test("fewer than two transactions throws tooFewTransactions")
  func tooFew() {
    #expect(throws: TransactionMergeError.tooFewTransactions) {
      try builder.merged([tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)])])
    }
  }

  @Test("different payees throw differentPayees")
  func differentPayees() {
    #expect(throws: TransactionMergeError.differentPayees) {
      try builder.merged([
        tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)]),
        tx(date: baseDate, payee: "Other", legs: [leg(quantity: -20)]),
      ])
    }
  }

  @Test("different calendar days throw differentDays")
  func differentDays() {
    #expect(throws: TransactionMergeError.differentDays) {
      try builder.merged([
        tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)]),
        tx(
          date: baseDate.addingTimeInterval(86_400 * 3), payee: "Acme", legs: [leg(quantity: -20)]),
      ])
    }
  }

  @Test("a scheduled transaction in the selection throws containsScheduled")
  func scheduled() {
    #expect(throws: TransactionMergeError.containsScheduled) {
      try builder.merged([
        tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -10)], recurPeriod: .month),
        tx(date: baseDate, payee: "Acme", legs: [leg(quantity: -20)]),
      ])
    }
  }
}
