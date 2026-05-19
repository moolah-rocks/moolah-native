import Foundation
import Testing

@testable import Moolah

@Suite("FuzzyTransferDetector")
struct FuzzyTransferDetectorTests {
  private let detector = FuzzyTransferDetector()

  // Fixed reference date: 2024-01-10 12:00:00 UTC
  private let baseDate = Date(timeIntervalSince1970: 1_704_888_000)

  private func date(offsetSeconds: TimeInterval) -> Date {
    baseDate.addingTimeInterval(offsetSeconds)
  }

  private func makeTx(
    id: UUID = UUID(),
    date: Date,
    accountId: UUID,
    instrument: Instrument = .defaultTestInstrument,
    quantity: Decimal,
    type: TransactionType = .expense
  ) -> Transaction {
    Transaction(
      id: id,
      date: date,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: instrument,
          quantity: quantity,
          type: type)
      ]
    )
  }

  // MARK: - Happy path

  @Test("cross-account opposite-equal amounts within ±3 days produces a candidate pair")
  func crossAccountOppositeEqualWithinWindow() throws {
    let accountA = UUID()
    let accountB = UUID()
    let tx1 = makeTx(date: baseDate, accountId: accountA, quantity: -500)
    let tx2 = makeTx(date: date(offsetSeconds: 3600), accountId: accountB, quantity: 500)

    let pairs = detector.detect(
      newlyImported: [tx1],
      existingNearby: [tx2]
    )

    #expect(pairs.count == 1)
    let pair = try #require(pairs.first)
    #expect(pair.newlyImported.id == tx1.id)
    #expect(pair.existingCounterpart.id == tx2.id)
  }

  // MARK: - Rejection cases

  @Test("same-account pair is rejected")
  func sameAccountRejected() {
    let accountA = UUID()
    let tx1 = makeTx(date: baseDate, accountId: accountA, quantity: -500)
    let tx2 = makeTx(date: baseDate, accountId: accountA, quantity: 500)

    let pairs = detector.detect(
      newlyImported: [tx1],
      existingNearby: [tx2]
    )

    #expect(pairs.isEmpty)
  }

  @Test("instrument mismatch is rejected")
  func instrumentMismatchRejected() {
    let accountA = UUID()
    let accountB = UUID()
    let tx1 = makeTx(
      date: baseDate, accountId: accountA,
      instrument: .defaultTestInstrument, quantity: -500)
    let tx2 = makeTx(
      date: baseDate, accountId: accountB,
      instrument: .fiat(code: "USD"), quantity: 500)

    let pairs = detector.detect(
      newlyImported: [tx1],
      existingNearby: [tx2]
    )

    #expect(pairs.isEmpty)
  }

  @Test("non-opposite quantity is rejected")
  func nonOppositeQuantityRejected() {
    let accountA = UUID()
    let accountB = UUID()
    let tx1 = makeTx(date: baseDate, accountId: accountA, quantity: -500)
    let tx2 = makeTx(date: baseDate, accountId: accountB, quantity: 400)

    let pairs = detector.detect(
      newlyImported: [tx1],
      existingNearby: [tx2]
    )

    #expect(pairs.isEmpty)
  }

  // MARK: - Window boundary

  @Test("exactly ±3 days apart is accepted")
  func exactlyThreeDaysAccepted() {
    let accountA = UUID()
    let accountB = UUID()
    let windowEdge = FuzzyTransferDetector.windowSeconds
    let tx1 = makeTx(date: baseDate, accountId: accountA, quantity: -500)
    let tx2 = makeTx(date: date(offsetSeconds: windowEdge), accountId: accountB, quantity: 500)

    let pairs = detector.detect(
      newlyImported: [tx1],
      existingNearby: [tx2]
    )

    #expect(pairs.count == 1)
  }

  @Test("just outside ±3 days is rejected")
  func justOutsideWindowRejected() {
    let accountA = UUID()
    let accountB = UUID()
    let justOutside = FuzzyTransferDetector.windowSeconds + 1
    let tx1 = makeTx(date: baseDate, accountId: accountA, quantity: -500)
    let tx2 = makeTx(date: date(offsetSeconds: justOutside), accountId: accountB, quantity: 500)

    let pairs = detector.detect(
      newlyImported: [tx1],
      existingNearby: [tx2]
    )

    #expect(pairs.isEmpty)
  }

  // MARK: - Transfer leg eligibility

  @Test("already-merged two-transfer-leg transaction is not a candidate")
  func twoTransferLegMergedTransactionIsIneligible() {
    let accountA = UUID()
    let accountB = UUID()
    let accountC = UUID()
    // Two-transfer-leg = already-merged; transferDetectionValueLeg returns nil
    let merged = Transaction(
      id: UUID(),
      date: baseDate,
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: .defaultTestInstrument,
          quantity: -500, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: .defaultTestInstrument,
          quantity: 500, type: .transfer),
      ]
    )
    let counterpart = makeTx(date: baseDate, accountId: accountC, quantity: 500)

    let pairs = detector.detect(
      newlyImported: [merged],
      existingNearby: [counterpart]
    )

    #expect(pairs.isEmpty)
  }

  @Test("single-transfer-leg on-chain transaction is eligible and pairs with opposing cash leg")
  func singleTransferLegCryptoTransactionIsEligible() throws {
    let walletAccountId = UUID()
    let exchangeAccountId = UUID()
    // Coinstash↔wallet shape: on-chain transfer leg
    let onChainSend = Transaction(
      id: UUID(),
      date: baseDate,
      legs: [
        TransactionLeg(
          accountId: walletAccountId,
          instrument: .defaultTestInstrument,
          quantity: -1_000,
          type: .transfer)
      ]
    )
    // Exchange cash receipt: income/expense leg (value leg for detection)
    let exchangeReceipt = makeTx(
      date: date(offsetSeconds: 3600),
      accountId: exchangeAccountId,
      quantity: 1_000,
      type: .income
    )

    let pairs = detector.detect(
      newlyImported: [onChainSend],
      existingNearby: [exchangeReceipt]
    )

    #expect(pairs.count == 1)
    let pair = try #require(pairs.first)
    #expect(pair.newlyImported.id == onChainSend.id)
    #expect(pair.existingCounterpart.id == exchangeReceipt.id)
  }

  // MARK: - Ambiguous / tie-break

  @Test("ambiguous matches resolve to closest date")
  func ambiguousResolvesToClosestDate() throws {
    let accountA = UUID()
    let accountB = UUID()
    let accountC = UUID()
    let source = makeTx(date: baseDate, accountId: accountA, quantity: -500)
    let near = makeTx(
      date: date(offsetSeconds: 3_600), accountId: accountB, quantity: 500)
    let far = makeTx(
      date: date(offsetSeconds: 86_400), accountId: accountC, quantity: 500)

    let pairs = detector.detect(
      newlyImported: [source],
      existingNearby: [near, far]
    )

    #expect(pairs.count == 1)
    let pair = try #require(pairs.first)
    #expect(pair.existingCounterpart.id == near.id)
  }

  @Test("tie in date resolves to lower counterpart UUID string")
  func tieDateResolvesToLowerUUID() throws {
    let accountA = UUID()
    let accountB = UUID()
    let accountC = UUID()

    // Deterministic UUIDs so we know which is lexicographically lower
    let lowerUUID = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
    let higherUUID = try #require(UUID(uuidString: "ffffffff-ffff-ffff-ffff-ffffffffffff"))

    let source = makeTx(date: baseDate, accountId: accountA, quantity: -500)
    let sourceLower = makeTx(id: lowerUUID, date: baseDate, accountId: accountB, quantity: 500)
    let sourceHigher = makeTx(id: higherUUID, date: baseDate, accountId: accountC, quantity: 500)

    let pairs = detector.detect(
      newlyImported: [source],
      existingNearby: [sourceHigher, sourceLower]
    )

    #expect(pairs.count == 1)
    let pair = try #require(pairs.first)
    #expect(pair.existingCounterpart.id == lowerUUID)
  }
}
