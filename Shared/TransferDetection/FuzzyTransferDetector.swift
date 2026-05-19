import Foundation

/// Pure fuzzy candidate finder. No I/O.
///
/// Eligibility is determined by `Transaction.transferDetectionValueLeg`.
/// Transactions already collapsed by `CrossAccountTransferMerger`
/// (two `.transfer`-leg transactions) have a nil value leg and are
/// silently skipped.
struct FuzzyTransferDetector: Sendable {
  /// Maximum absolute date gap for a candidate pair, inclusive on both edges.
  static let windowSeconds: TimeInterval = 3 * 86_400

  func detect(
    newlyImported: [Transaction],
    existingNearby: [Transaction]
  ) -> [TransferCandidatePair] {
    let pool = newlyImported + existingNearby
    var consumed: Set<UUID> = []
    var result: [TransferCandidatePair] = []

    for imported in newlyImported {
      guard !consumed.contains(imported.id),
        let leg = imported.transferDetectionValueLeg,
        let accountId = leg.accountId
      else { continue }

      let matches = pool.compactMap { other -> (Transaction, TimeInterval)? in
        guard other.id != imported.id, !consumed.contains(other.id),
          let oleg = other.transferDetectionValueLeg,
          let oAccount = oleg.accountId, oAccount != accountId,
          oleg.instrument == leg.instrument,
          oleg.quantity == -leg.quantity
        else { return nil }
        let gap = abs(other.date.timeIntervalSince(imported.date))
        guard gap <= Self.windowSeconds else { return nil }
        return (other, gap)
      }

      guard
        let best = matches.min(by: { lhs, rhs in
          lhs.1 != rhs.1
            ? lhs.1 < rhs.1
            : lhs.0.id.uuidString < rhs.0.id.uuidString
        })?.0
      else { continue }

      consumed.insert(imported.id)
      consumed.insert(best.id)
      result.append(TransferCandidatePair(newlyImported: imported, existingCounterpart: best))
    }
    return result
  }
}
