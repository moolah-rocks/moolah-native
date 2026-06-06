import Foundation

@testable import Moolah

/// Shared construction helpers for the `TransferMergeBuilder` suites.
struct TransferMergeBuilderFixture {
  let builder = TransferMergeBuilder()

  /// Fixed reference date: 2024-01-10 12:00:00 UTC.
  let baseDate = Date(timeIntervalSince1970: 1_704_888_000)

  func date(offsetSeconds: TimeInterval) -> Date {
    baseDate.addingTimeInterval(offsetSeconds)
  }

  func origin(_ rawDescription: String) -> ImportOrigin {
    ImportOrigin(
      rawDescription: rawDescription,
      rawAmount: 0,
      importedAt: baseDate,
      importSessionId: UUID(),
      parserIdentifier: "test")
  }

  func cashTx(
    id: UUID = UUID(),
    date: Date,
    accountId: UUID,
    instrument: Instrument = .defaultTestInstrument,
    quantity: Decimal,
    type: TransactionType,
    payee: String? = nil,
    notes: String? = nil,
    externalId: String? = nil,
    counterpartyAddress: String? = nil,
    importOrigin: TransactionImportOrigin? = nil,
    feeLegs: [TransactionLeg] = []
  ) -> Transaction {
    Transaction(
      id: id,
      date: date,
      payee: payee,
      notes: notes,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: instrument,
          quantity: quantity,
          externalId: externalId,
          counterpartyAddress: counterpartyAddress,
          type: type)
      ] + feeLegs,
      importOrigin: importOrigin)
  }

  func feeLeg(
    accountId: UUID,
    instrument: Instrument = .USD,
    quantity: Decimal
  ) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId,
      instrument: instrument,
      quantity: quantity,
      type: .expense)
  }

  /// A transaction with two same-instrument expense legs on the same account,
  /// so `transferDetectionValueLeg` returns nil (ambiguous).
  func ambiguousMultiValueLegTx(accountId: UUID) -> Transaction {
    Transaction(
      id: UUID(),
      date: baseDate,
      legs: [
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: -500, type: .expense),
        TransactionLeg(
          accountId: accountId, instrument: .defaultTestInstrument,
          quantity: -100, type: .expense),
      ])
  }

  /// A transaction with two opposite-equal `.transfer` legs but no `.merged` import origin,
  /// so `split(_:)` reaches the `missingMergedOrigin` guard.
  func transferShapedTxWithoutMergedOrigin(accountA: UUID, accountB: UUID) -> Transaction {
    Transaction(
      id: UUID(),
      date: baseDate,
      legs: [
        TransactionLeg(
          accountId: accountA, instrument: .defaultTestInstrument,
          quantity: -500, type: .transfer),
        TransactionLeg(
          accountId: accountB, instrument: .defaultTestInstrument,
          quantity: 500, type: .transfer),
      ])
  }
}
