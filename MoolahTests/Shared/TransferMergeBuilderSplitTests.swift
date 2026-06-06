import Foundation
import Testing

@testable import Moolah

@Suite("TransferMergeBuilder split and round-trip")
struct TransferMergeBuilderSplitTests {
  private let fixture = TransferMergeBuilderFixture()

  private var builder: TransferMergeBuilder { fixture.builder }
  private var baseDate: Date { fixture.baseDate }

  private func date(offsetSeconds: TimeInterval) -> Date {
    fixture.date(offsetSeconds: offsetSeconds)
  }
  private func origin(_ rawDescription: String) -> ImportOrigin {
    fixture.origin(rawDescription)
  }

  @Test("split of a non-transfer transaction throws notATransfer")
  func splitNonTransferThrows() {
    let accountA = UUID()
    let transaction = fixture.cashTx(
      date: baseDate, accountId: accountA, quantity: -500, type: .expense)

    #expect(throws: TransferMergeError.notATransfer) {
      _ = try builder.split(transaction)
    }
  }

  @Test(
    "split of a two-transfer-leg transaction without a merged origin throws missingMergedOrigin")
  func splitMissingMergedOriginThrows() {
    let accountA = UUID()
    let accountB = UUID()
    let transaction = fixture.transferShapedTxWithoutMergedOrigin(
      accountA: accountA, accountB: accountB)

    #expect(throws: TransferMergeError.missingMergedOrigin) {
      _ = try builder.split(transaction)
    }
  }

  @Test("round-trip split of a merged pair restores both value legs and single origins")
  func roundTripRestoresValueLegsAndOrigins() throws {
    let accountA = UUID()
    let accountB = UUID()
    let outOrigin = origin("withdrawal")
    let inOrigin = origin("deposit")
    let txA = fixture.cashTx(
      date: baseDate, accountId: accountA, quantity: -500, type: .expense,
      importOrigin: .single(outOrigin))
    let txB = fixture.cashTx(
      date: date(offsetSeconds: 3_600), accountId: accountB, quantity: 500,
      type: .income, importOrigin: .single(inOrigin))

    let merged = try builder.merged(from: txA, txB)
    let splits = try builder.split(merged)

    #expect(splits.count == 2)
    let outSplit = try #require(
      splits.first { ($0.legs.first?.quantity ?? 0) < 0 })
    let inSplit = try #require(
      splits.first { ($0.legs.first?.quantity ?? 0) > 0 })

    let outLeg = try #require(outSplit.legs.first)
    #expect(outLeg.accountId == accountA)
    #expect(outLeg.instrument == .defaultTestInstrument)
    #expect(outLeg.quantity == -500)
    #expect(outLeg.type == .expense)
    #expect(outSplit.importOrigin?.singleOrigin == outOrigin)

    let inLeg = try #require(inSplit.legs.first)
    #expect(inLeg.accountId == accountB)
    #expect(inLeg.instrument == .defaultTestInstrument)
    #expect(inLeg.quantity == 500)
    #expect(inLeg.type == .income)
    #expect(inSplit.importOrigin?.singleOrigin == inOrigin)
  }

  @Test("round-trip restores each value leg's externalId and counterpartyAddress")
  func roundTripRestoresExternalIdAndCounterpartyAddress() throws {
    let accountA = UUID()
    let accountB = UUID()
    let txA = fixture.cashTx(
      date: baseDate, accountId: accountA, quantity: -500, type: .expense,
      externalId: "coinstash:withdraw-1", counterpartyAddress: "0xsource",
      importOrigin: .single(origin("withdrawal")))
    let txB = fixture.cashTx(
      date: baseDate, accountId: accountB, quantity: 500, type: .income,
      externalId: "alchemy:deposit-1", counterpartyAddress: "0xdest",
      importOrigin: .single(origin("deposit")))

    let merged = try builder.merged(from: txA, txB)
    let splits = try builder.split(merged)

    let outLeg = try #require(splits.first { ($0.legs.first?.quantity ?? 0) < 0 }?.legs.first)
    let inLeg = try #require(splits.first { ($0.legs.first?.quantity ?? 0) > 0 }?.legs.first)
    #expect(outLeg.externalId == "coinstash:withdraw-1")
    #expect(outLeg.counterpartyAddress == "0xsource")
    #expect(inLeg.externalId == "alchemy:deposit-1")
    #expect(inLeg.counterpartyAddress == "0xdest")
  }

  @Test("round-trip returns each cross-instrument fee leg to its originating account split")
  func roundTripReattachesFeeLegsByAccount() throws {
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
    let splits = try builder.split(merged)

    let outSplit = try #require(
      splits.first { $0.legs.contains { $0.type == .expense && $0.accountId == accountA } })
    let inSplit = try #require(
      splits.first { $0.legs.contains { $0.type == .income && $0.accountId == accountB } })

    #expect(outSplit.legs.contains { $0.id == feeA.id && $0.accountId == accountA })
    #expect(inSplit.legs.contains { $0.id == feeB.id && $0.accountId == accountB })
    #expect(!outSplit.legs.contains { $0.id == feeB.id })
    #expect(!inSplit.legs.contains { $0.id == feeA.id })
  }

  @Test("a fee leg with no resolvable side stays with the outgoing split")
  func roundTripUnresolvableFeeStaysWithOutgoing() throws {
    let accountA = UUID()
    let accountB = UUID()
    let orphanAccount = UUID()
    let orphanFee = fixture.feeLeg(accountId: orphanAccount, quantity: -2)
    let txA = fixture.cashTx(
      date: baseDate, accountId: accountA, quantity: -500, type: .expense,
      feeLegs: [orphanFee])
    let txB = fixture.cashTx(date: baseDate, accountId: accountB, quantity: 500, type: .income)

    let merged = try builder.merged(from: txA, txB)
    let splits = try builder.split(merged)

    let outSplit = try #require(
      splits.first { $0.legs.contains { $0.type == .expense && $0.accountId == accountA } })
    #expect(outSplit.legs.contains { $0.id == orphanFee.id })
  }

  @Test("manual merge window is wider than the auto-detection window")
  func manualMergeWindowIsWider() {
    #expect(TransferMergeBuilder.manualMergeWindowSeconds > FuzzyTransferDetector.windowSeconds)
    #expect(TransferMergeBuilder.manualMergeWindowSeconds == 14 * 86_400)
  }
}
