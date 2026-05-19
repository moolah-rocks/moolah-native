import Foundation
import Testing

@testable import Moolah

@Suite("TransferMergeBuilder merge")
struct TransferMergeBuilderTests {
  private let fixture = TransferMergeBuilderFixture()

  private var builder: TransferMergeBuilder { fixture.builder }
  private var baseDate: Date { fixture.baseDate }

  private func date(offsetSeconds: TimeInterval) -> Date {
    fixture.date(offsetSeconds: offsetSeconds)
  }
  private func origin(_ rawDescription: String) -> ImportOrigin {
    fixture.origin(rawDescription)
  }

  @Test("merged transfer takes the earlier of the two dates")
  func mergedUsesEarlierDate() throws {
    let accountA = UUID()
    let accountB = UUID()
    let txA = fixture.cashTx(
      date: date(offsetSeconds: 3_600), accountId: accountA,
      quantity: -500, type: .expense)
    let txB = fixture.cashTx(date: baseDate, accountId: accountB, quantity: 500, type: .income)

    let merged = try builder.merged(from: txA, txB)

    #expect(merged.date == baseDate)
  }

  @Test("merged transfer has exactly two opposite-equal transfer legs")
  func mergedHasTwoTransferLegs() throws {
    let accountA = UUID()
    let accountB = UUID()
    let txA = fixture.cashTx(date: baseDate, accountId: accountA, quantity: -500, type: .expense)
    let txB = fixture.cashTx(date: baseDate, accountId: accountB, quantity: 500, type: .income)

    let merged = try builder.merged(from: txA, txB)

    let transferLegs = merged.legs.filter { $0.type == .transfer }
    #expect(transferLegs.count == 2)
    let outgoing = try #require(transferLegs.first { $0.quantity < 0 })
    let incoming = try #require(transferLegs.first { $0.quantity > 0 })
    #expect(outgoing.accountId == accountA)
    #expect(outgoing.quantity == -500)
    #expect(incoming.accountId == accountB)
    #expect(incoming.quantity == 500)
  }

  @Test("merged origin maps the negative-quantity side to outgoing")
  func mergedOriginNegativeSideIsOutgoing() throws {
    let accountA = UUID()
    let accountB = UUID()
    let outOrigin = origin("withdrawal")
    let txA = fixture.cashTx(
      date: baseDate, accountId: accountA, quantity: -500, type: .expense,
      importOrigin: .single(outOrigin))
    let txB = fixture.cashTx(
      date: baseDate, accountId: accountB, quantity: 500, type: .income,
      importOrigin: .single(origin("deposit")))

    let merged = try builder.merged(from: txA, txB)

    let mergedOrigin = try #require(merged.importOrigin?.mergedOrigin)
    #expect(mergedOrigin.outgoing == outOrigin)
  }

  @Test("merged origin maps the positive-quantity side to incoming")
  func mergedOriginPositiveSideIsIncoming() throws {
    let accountA = UUID()
    let accountB = UUID()
    let inOrigin = origin("deposit")
    let txA = fixture.cashTx(
      date: baseDate, accountId: accountA, quantity: -500, type: .expense,
      importOrigin: .single(origin("withdrawal")))
    let txB = fixture.cashTx(
      date: baseDate, accountId: accountB, quantity: 500, type: .income,
      importOrigin: .single(inOrigin))

    let merged = try builder.merged(from: txA, txB)

    let mergedOrigin = try #require(merged.importOrigin?.mergedOrigin)
    #expect(mergedOrigin.incoming == inOrigin)
  }

  @Test("a side without a single import origin contributes nil to the merged origin")
  func mergedOriginNilForNonSingleSide() throws {
    let accountA = UUID()
    let accountB = UUID()
    let inOrigin = origin("deposit")
    let txA = fixture.cashTx(date: baseDate, accountId: accountA, quantity: -500, type: .expense)
    let txB = fixture.cashTx(
      date: baseDate, accountId: accountB, quantity: 500, type: .income,
      importOrigin: .single(inOrigin))

    let merged = try builder.merged(from: txA, txB)

    let mergedOrigin = try #require(merged.importOrigin?.mergedOrigin)
    #expect(mergedOrigin.outgoing == nil)
    #expect(mergedOrigin.incoming == inOrigin)
  }

  @Test("equal payees collapse to the shared payee")
  func mergedSharedPayee() throws {
    let accountA = UUID()
    let accountB = UUID()
    let txA = fixture.cashTx(
      date: baseDate, accountId: accountA, quantity: -500, type: .expense,
      payee: "Acme")
    let txB = fixture.cashTx(
      date: baseDate, accountId: accountB, quantity: 500, type: .income,
      payee: "Acme")

    let merged = try builder.merged(from: txA, txB)

    #expect(merged.payee == "Acme")
  }

  @Test("distinct payees are dedup-joined outgoing-then-incoming")
  func mergedDistinctPayeesJoined() throws {
    let accountA = UUID()
    let accountB = UUID()
    let txA = fixture.cashTx(
      date: baseDate, accountId: accountA, quantity: -500, type: .expense,
      payee: "Source Bank")
    let txB = fixture.cashTx(
      date: baseDate, accountId: accountB, quantity: 500, type: .income,
      payee: "Dest Bank")

    let merged = try builder.merged(from: txA, txB)

    #expect(merged.payee == "Source Bank / Dest Bank")
  }

  @Test("notes are joined by newline with duplicate lines collapsed")
  func mergedNotesJoinedAndDeduped() throws {
    let accountA = UUID()
    let accountB = UUID()
    let txA = fixture.cashTx(
      date: baseDate, accountId: accountA, quantity: -500, type: .expense,
      notes: "shared\nout-only")
    let txB = fixture.cashTx(
      date: baseDate, accountId: accountB, quantity: 500, type: .income,
      notes: "shared\nin-only")

    let merged = try builder.merged(from: txA, txB)

    #expect(merged.notes == "shared\nout-only\nin-only")
  }

  @Test("fee legs from both sides are preserved unchanged")
  func mergedPreservesFeeLegsFromBothSides() throws {
    let accountA = UUID()
    let accountB = UUID()
    let feeA = fixture.feeLeg(accountId: accountA, quantity: -3)
    let feeB = fixture.feeLeg(accountId: accountB, quantity: -7)
    let txA = fixture.cashTx(
      date: baseDate, accountId: accountA, quantity: -500, type: .expense,
      feeLegs: [feeA])
    let txB = fixture.cashTx(
      date: baseDate, accountId: accountB, quantity: 500, type: .income,
      feeLegs: [feeB])

    let merged = try builder.merged(from: txA, txB)

    let feeLegs = merged.legs.filter { $0.type != .transfer }
    #expect(feeLegs.count == 2)
    #expect(feeLegs.contains { $0.id == feeA.id && $0.accountId == accountA && $0.quantity == -3 })
    #expect(feeLegs.contains { $0.id == feeB.id && $0.accountId == accountB && $0.quantity == -7 })
  }

  @Test("merge assigns a new id distinct from both input ids")
  func mergedAssignsNewId() throws {
    let accountA = UUID()
    let accountB = UUID()
    let txA = fixture.cashTx(date: baseDate, accountId: accountA, quantity: -500, type: .expense)
    let txB = fixture.cashTx(date: baseDate, accountId: accountB, quantity: 500, type: .income)

    let merged = try builder.merged(from: txA, txB)

    #expect(merged.id != txA.id)
    #expect(merged.id != txB.id)
  }

  @Test("merge of two same-account sides throws notMergeable")
  func mergeSameAccountThrows() {
    let accountA = UUID()
    let txA = fixture.cashTx(date: baseDate, accountId: accountA, quantity: -500, type: .expense)
    let txB = fixture.cashTx(date: baseDate, accountId: accountA, quantity: 500, type: .income)

    #expect(throws: TransferMergeError.notMergeable) {
      try builder.merged(from: txA, txB)
    }
  }

  @Test("merge with mismatched instruments throws notMergeable")
  func mergeInstrumentMismatchThrows() {
    let accountA = UUID()
    let accountB = UUID()
    let txA = fixture.cashTx(
      date: baseDate, accountId: accountA,
      instrument: .defaultTestInstrument, quantity: -500, type: .expense)
    let txB = fixture.cashTx(
      date: baseDate, accountId: accountB,
      instrument: .fiat(code: "USD"), quantity: 500, type: .income)

    #expect(throws: TransferMergeError.notMergeable) {
      try builder.merged(from: txA, txB)
    }
  }

  @Test("merge with non-opposite quantities throws notMergeable")
  func mergeNonOppositeThrows() {
    let accountA = UUID()
    let accountB = UUID()
    let txA = fixture.cashTx(date: baseDate, accountId: accountA, quantity: -500, type: .expense)
    let txB = fixture.cashTx(date: baseDate, accountId: accountB, quantity: 400, type: .income)

    #expect(throws: TransferMergeError.notMergeable) {
      try builder.merged(from: txA, txB)
    }
  }

  @Test("merge of a side with no detection value leg throws notMergeable")
  func mergeNoValueLegThrows() {
    let accountA = UUID()
    let accountB = UUID()
    let txA = fixture.ambiguousMultiValueLegTx(accountId: accountA)
    let txB = fixture.cashTx(date: baseDate, accountId: accountB, quantity: 500, type: .income)

    #expect(throws: TransferMergeError.notMergeable) {
      try builder.merged(from: txA, txB)
    }
  }
}
