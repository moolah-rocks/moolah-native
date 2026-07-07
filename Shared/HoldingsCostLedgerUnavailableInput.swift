import Foundation

struct HoldingsCostLedgerUnavailableInput: Sendable, Hashable {
  let date: Date
  let keys: Set<HoldingsCostLedger.TouchKey>
  let mayAffectRealisedGains: Bool
}

extension Set where Element == HoldingsCostLedgerUnavailableInput {
  func realisedGainInstruments(
    in interval: Range<Date>,
    disposalCandidates: Set<HoldingsCostLedgerDisposalCandidate>,
    moveCandidates: Set<HoldingsCostLedgerMoveCandidate>
  ) -> Set<Instrument> {
    reduce(into: Set<Instrument>()) { result, input in
      if input.mayAffectRealisedGains, interval.contains(input.date) {
        result.formUnion(input.keys.map(\.instrument))
      }
      let affectedKeys = reachableKeys(from: input.keys, after: input.date, through: moveCandidates)
      let affectedDisposalInstruments =
        disposalCandidates
        .filter { candidate in
          interval.contains(candidate.date)
            && candidate.date >= input.date
            && affectedKeys.contains(candidate.key)
        }
        .map(\.key.instrument)
      result.formUnion(affectedDisposalInstruments)
    }
  }

  private func reachableKeys(
    from keys: Set<HoldingsCostLedger.TouchKey>,
    after date: Date,
    through moveCandidates: Set<HoldingsCostLedgerMoveCandidate>
  ) -> Set<HoldingsCostLedger.TouchKey> {
    var reachable = keys
    let relevantMoves = moveCandidates.filter { $0.date >= date }
    var changed = true
    while changed {
      changed = false
      for move in relevantMoves
      where reachable.contains(move.source)
        && !reachable.contains(move.destination)
      {
        reachable.insert(move.destination)
        changed = true
      }
    }
    return reachable
  }
}
