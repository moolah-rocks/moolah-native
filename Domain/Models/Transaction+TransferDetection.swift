import Foundation

// Eligibility lets multi-leg crypto transactions (transfer leg + cross-
// instrument fee leg) participate in the standard amount/instrument/date
// suggestion pass without false-pairing trades or already-merged
// transfers. Detection's amount/instrument matching always operates on
// the value-bearing leg.
extension Transaction {
  /// `true` iff this transaction can participate in the transfer-
  /// detection suggestion pass. Detection always operates on the value-
  /// bearing leg.
  ///
  /// Eligible shapes:
  /// - Exactly one `.transfer` leg (the value-bearing leg). Any number
  ///   of additional `.expense` legs in a different instrument from the
  ///   value-bearing leg are permitted (fees: gas, broker fees, …).
  /// - Exactly one `.income` or `.expense` leg (single-leg cash).
  ///   Any number of additional `.expense` legs in a different instrument
  ///   from the value-bearing leg are permitted.
  ///
  /// Ineligible shapes:
  /// - Trades (two `.trade` legs).
  /// - Already-merged transfers (two `.transfer` legs).
  /// - Opening balances (`.openingBalance`).
  /// - Anything else with multiple value-bearing legs or with extra legs
  ///   in the same instrument as the value-bearing leg.
  var isTransferDetectionEligible: Bool { transferDetectionValueLeg != nil }

  /// The leg that detection should pair on, or `nil` when this
  /// transaction is ineligible.
  var transferDetectionValueLeg: TransactionLeg? {
    let transferLegs = legs.filter { $0.type == .transfer }
    if transferLegs.count == 1 {
      return Self.valueLegIfFeesAreCrossInstrument(
        valueLeg: transferLegs[0],
        otherLegs: legs.filter { $0.type != .transfer })
    }

    if transferLegs.isEmpty {
      let cashLegs = legs.filter { $0.type == .income || $0.type == .expense }
      // Pick the single value-bearing leg as the largest-magnitude one
      // so a value `.expense` paired with smaller `.expense` fee legs
      // resolves correctly. If two or more cash legs share the same
      // instrument, none of them is a fee — the transaction has
      // multiple value-bearing legs and is ineligible.
      if let valueLeg = Self.cashValueLeg(amongCashLegs: cashLegs) {
        return Self.valueLegIfFeesAreCrossInstrument(
          valueLeg: valueLeg,
          otherLegs: legs.filter { $0 != valueLeg })
      }
    }
    return nil
  }

  /// `true` iff this transaction is a transfer that detection produced
  /// by merging two single-account sides: exactly two `.transfer` legs
  /// and a `.merged` import origin. A hand-entered two-leg transfer has
  /// no merged origin and is *not* unmergeable — splitting it has no
  /// original sides to restore. Drives the "Split Back into Separate
  /// Transactions…" gate across the menu bar, detail, and context menu.
  var isMergedTransfer: Bool {
    legs.count == 2
      && legs.allSatisfy { $0.type == .transfer }
      && importOrigin?.mergedOrigin != nil
  }

  /// `true` iff the two transactions form a candidate manual-merge pair:
  /// both detection-eligible (a single value-bearing leg) and on
  /// disjoint accounts. This is the cheap selection-shape gate the menu
  /// bar / toolbar / context menu share; the coordinator still performs
  /// the full opposite-amount / same-instrument / ±14-day validation and
  /// surfaces a `ManualMergeError` for anything this gate lets through.
  static func canManualMerge(_ first: Transaction, with second: Transaction) -> Bool {
    first.isTransferDetectionEligible
      && second.isTransferDetectionEligible
      && first.accountIds.isDisjoint(with: second.accountIds)
  }
}

extension Transaction {
  /// Selects the single value-bearing cash leg. Eligible cash shapes
  /// are: one `.income`/`.expense` leg by itself, or one such leg
  /// plus zero or more `.expense` fee legs in different instruments.
  /// When two or more legs sit in the same instrument the value-leg is
  /// ambiguous — caller treats the whole transaction as ineligible.
  private static func cashValueLeg(amongCashLegs cashLegs: [TransactionLeg]) -> TransactionLeg? {
    guard !cashLegs.isEmpty else { return nil }
    if cashLegs.count == 1 { return cashLegs[0] }
    // With ≥2 cash legs, the value leg is the unique-instrument one
    // (every other cash leg sits in its own distinct instrument and
    // is `.expense`-typed = a fee). If multiple cash legs share an
    // instrument the value leg is ambiguous.
    var byInstrument: [Instrument: [TransactionLeg]] = [:]
    for leg in cashLegs {
      byInstrument[leg.instrument, default: []].append(leg)
    }
    let dominant = byInstrument.values.filter { $0.count >= 2 }
    guard dominant.isEmpty else { return nil }
    // The value-bearing leg is the largest-magnitude cash leg; remaining
    // cash legs must be `.expense` fee legs in a different instrument
    // (validated by the cross-instrument predicate at the call site).
    let sorted = cashLegs.sorted { abs($0.quantity) > abs($1.quantity) }
    return sorted.first
  }

  /// Returns `valueLeg` when every other leg either is `.expense` and
  /// sits in a different instrument from `valueLeg` (a fee leg), or
  /// the leg list is empty. Returns `nil` otherwise — that shape isn't
  /// detection-eligible.
  private static func valueLegIfFeesAreCrossInstrument(
    valueLeg: TransactionLeg,
    otherLegs: [TransactionLeg]
  ) -> TransactionLeg? {
    let allFeeLegs = otherLegs.allSatisfy { leg in
      leg.type == .expense && leg.instrument != valueLeg.instrument
    }
    return allFeeLegs ? valueLeg : nil
  }
}
