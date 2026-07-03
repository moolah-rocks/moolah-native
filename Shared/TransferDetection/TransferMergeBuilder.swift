import Foundation

/// Pure merge/split transforms for cross-account transfers. No I/O.
///
/// `merged(from:_:)` collapses two single-account import sides into one
/// two-`.transfer`-leg transaction, recording each side's import origin
/// on a `MergedImportOrigin` so `split(_:)` can reverse it exactly.
/// Fee legs (cross-instrument `.expense` legs such as gas or broker
/// fees) ride through unchanged, keyed by their originating account so
/// they return to the correct side on split.
struct TransferMergeBuilder: Sendable {
  /// Collapses two single-account import sides into one merged transfer.
  ///
  /// Each side contributes its `transferDetectionValueLeg`. The two
  /// value legs must sit on different accounts, in the same instrument,
  /// with opposite-equal quantities. Every non-value leg from either
  /// side is preserved unchanged as a fee leg.
  func merged(from sideA: Transaction, _ sideB: Transaction) throws -> Transaction {
    guard
      let valueLegA = sideA.transferDetectionValueLeg,
      let valueLegB = sideB.transferDetectionValueLeg,
      let accountA = valueLegA.accountId,
      let accountB = valueLegB.accountId,
      accountA != accountB,
      valueLegA.instrument == valueLegB.instrument,
      valueLegA.quantity == -valueLegB.quantity
    else { throw TransferMergeError.notMergeable }

    let (outgoingSide, incomingSide) =
      valueLegA.quantity < 0 ? (sideA, sideB) : (sideB, sideA)
    let (outgoingValueLeg, incomingValueLeg) =
      valueLegA.quantity < 0 ? (valueLegA, valueLegB) : (valueLegB, valueLegA)

    let outgoingTransferLeg = transferLeg(from: outgoingValueLeg)
    let incomingTransferLeg = transferLeg(from: incomingValueLeg)
    let feeLegs =
      outgoingSide.legs.filter { $0 != outgoingValueLeg }
      + incomingSide.legs.filter { $0 != incomingValueLeg }

    return Transaction(
      date: min(sideA.date, sideB.date),
      payee: mergedPayee(outgoing: outgoingSide.payee, incoming: incomingSide.payee),
      notes: mergedNotes([outgoingSide.notes, incomingSide.notes]),
      legs: [outgoingTransferLeg, incomingTransferLeg] + feeLegs,
      importOrigin: .merged(
        MergedImportOrigin(
          outgoing: outgoingSide.importOrigin?.singleOrigin,
          incoming: incomingSide.importOrigin?.singleOrigin)))
  }

  /// Reverses `merged(from:_:)`. Produces two single-value-leg
  /// transactions, one per `.transfer` leg, each on its original
  /// account. Each split's `.single` import origin is restored from the
  /// matching `MergedImportOrigin` side by sign. Every fee leg returns
  /// to the split whose value leg shares the fee leg's account; an
  /// unresolvable fee leg stays with the outgoing split.
  func split(_ transfer: Transaction) throws -> [Transaction] {
    let transferLegs = transfer.legs.filter { $0.type == .transfer }
    guard
      transferLegs.count == 2,
      let outgoingLeg = transferLegs.first(where: { $0.quantity < 0 }),
      let incomingLeg = transferLegs.first(where: { $0.quantity > 0 }),
      outgoingLeg.instrument == incomingLeg.instrument,
      outgoingLeg.quantity == -incomingLeg.quantity
    else { throw TransferMergeError.notATransfer }

    guard let mergedOrigin = transfer.importOrigin?.mergedOrigin else {
      throw TransferMergeError.missingMergedOrigin
    }

    // A fee leg returns to incoming only when its account matches the
    // incoming value leg's account. Every other fee leg — including one
    // whose account matches neither side or is nil — stays with the
    // outgoing split.
    let feeLegs = transfer.legs.filter { $0.type != .transfer }
    let incomingFees = feeLegs.filter {
      $0.accountId != nil && $0.accountId == incomingLeg.accountId
    }
    let outgoingFees = feeLegs.filter {
      !($0.accountId != nil && $0.accountId == incomingLeg.accountId)
    }

    let outgoingSplit = splitTransaction(
      from: transfer,
      valueLeg: outgoingLeg,
      type: .expense,
      origin: mergedOrigin.outgoing,
      feeLegs: outgoingFees)
    let incomingSplit = splitTransaction(
      from: transfer,
      valueLeg: incomingLeg,
      type: .income,
      origin: mergedOrigin.incoming,
      feeLegs: incomingFees)
    return [outgoingSplit, incomingSplit]
  }

  /// Manual merge tolerates a wider window than auto-detection
  /// (`FuzzyTransferDetector.windowSeconds`) — the user is asserting intent.
  static let manualMergeWindowSeconds: TimeInterval = 14 * 86_400
}

extension TransferMergeBuilder {
  // `externalId` / `counterpartyAddress` are carried through both merge and
  // split unchanged. For sync-owned legs (wallet / exchange imports),
  // `externalId` is the dedup key the apply pass matches on
  // `(accountId, externalId)`; omitting it causes the next sync to re-import
  // the absorbed leg as a duplicate. Hand-entered legs carry `nil` for both
  // fields — this is a no-op for them.
  private func transferLeg(from valueLeg: TransactionLeg) -> TransactionLeg {
    TransactionLeg(
      accountId: valueLeg.accountId,
      instrument: valueLeg.instrument,
      quantity: valueLeg.quantity,
      externalId: valueLeg.externalId,
      counterpartyAddress: valueLeg.counterpartyAddress,
      type: .transfer,
      categoryId: valueLeg.categoryId,
      earmarkId: valueLeg.earmarkId)
  }

  private func splitTransaction(
    from transfer: Transaction,
    valueLeg: TransactionLeg,
    type: TransactionType,
    origin: ImportOrigin?,
    feeLegs: [TransactionLeg]
  ) -> Transaction {
    let cashLeg = TransactionLeg(
      accountId: valueLeg.accountId,
      instrument: valueLeg.instrument,
      quantity: valueLeg.quantity,
      externalId: valueLeg.externalId,
      counterpartyAddress: valueLeg.counterpartyAddress,
      type: type,
      categoryId: valueLeg.categoryId,
      earmarkId: valueLeg.earmarkId)
    return Transaction(
      date: transfer.date,
      payee: transfer.payee,
      notes: transfer.notes,
      legs: [cashLeg] + feeLegs,
      importOrigin: origin.map { .single($0) })
  }

  private func mergedPayee(outgoing: String?, incoming: String?) -> String? {
    let parts = [outgoing, incoming].compactMap { $0 }
    guard let first = parts.first else { return nil }
    if parts.count == 2, outgoing == incoming { return first }
    var seen: Set<String> = []
    let distinct = parts.filter { seen.insert($0).inserted }
    return distinct.joined(separator: " / ")
  }

}
