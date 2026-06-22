import Foundation

extension EarmarkStore {
  // The members below are module-internal (not `private`) only because
  // `EarmarkStore.swift` calls them across the file boundary. They are
  // not intended as API for any other type — treat them as `private` to
  // the `EarmarkStore` family.

  /// Per-earmark conversion result: the three position-list totals,
  /// each expressed in the earmark's own instrument.
  struct ConvertedEarmarkTotals {
    let balance: InstrumentAmount
    let saved: InstrumentAmount
    let spent: InstrumentAmount
  }

  /// Sums an earmark's three position lists, each converted to the
  /// earmark's own instrument. `.knownZero` positions (an `.unpriced`
  /// / `.spam` crypto registration) contribute zero rather than
  /// failing the earmark — issue #790. A real provider failure still
  /// throws so the caller treats the whole earmark as failed (we never
  /// display a partial earmark balance under transient outage).
  func convertEarmarkPositions(_ earmark: Earmark) async throws
    -> ConvertedEarmarkTotals
  {
    let date = Date()
    let target = earmark.instrument
    // Same-instrument fast path (Rule 8): positions already in `target` are
    // summed inline and never enter the batch. Each list keeps its inline
    // total plus the count of cross-instrument requests it contributed, so
    // its outcome slice sums back in the order Phase 1 appended them. A
    // single `convertResultBatch` resolves all cross-instrument positions.
    var requests: [BatchConversionRequest] = []
    let (balanceInline, balanceCount) = accumulate(
      earmark.positions, target: target, date: date, into: &requests)
    let (savedInline, savedCount) = accumulate(
      earmark.savedPositions, target: target, date: date, into: &requests)
    let (spentInline, spentCount) = accumulate(
      earmark.spentPositions, target: target, date: date, into: &requests)
    let outcomes = try await conversionService.convertResultBatch(requests)

    var cursor = 0
    let balance = try sumOutcomes(
      outcomes, range: &cursor, count: balanceCount, into: balanceInline)
    let saved = try sumOutcomes(
      outcomes, range: &cursor, count: savedCount, into: savedInline)
    let spent = try sumOutcomes(
      outcomes, range: &cursor, count: spentCount, into: spentInline)
    return ConvertedEarmarkTotals(balance: balance, saved: saved, spent: spent)
  }

  /// Split one position list into its same-instrument inline subtotal and the
  /// cross-instrument requests appended to `requests`. Returns the inline
  /// total (already in `target`) and the number of requests contributed, so
  /// the caller can slice the matching outcomes back out in order.
  private func accumulate(
    _ positions: [Position],
    target: Instrument,
    date: Date,
    into requests: inout [BatchConversionRequest]
  ) -> (inline: InstrumentAmount, count: Int) {
    var inline = InstrumentAmount.zero(instrument: target)
    var count = 0
    for position in positions {
      if position.amount.instrument == target {
        inline += position.amount
      } else {
        requests.append(
          BatchConversionRequest(amount: position.amount, target: target, date: date))
        count += 1
      }
    }
    return (inline, count)
  }

  /// Fold `count` outcomes starting at `cursor` (advanced in place) into
  /// `inline` (the list's same-instrument subtotal, already in the target
  /// instrument). Folds `.knownZero` (an `.unpriced` / `.spam` crypto source)
  /// to zero (issue #790); rethrows the first `.failure` so a real provider
  /// outage fails the whole earmark — we never display a partial earmark
  /// balance under transient outage.
  private func sumOutcomes(
    _ outcomes: [BatchConversionOutcome],
    range cursor: inout Int,
    count: Int,
    into inline: InstrumentAmount
  ) throws -> InstrumentAmount {
    var total = inline
    for outcome in outcomes[cursor..<cursor + count] {
      switch outcome {
      case .value(let converted): total += converted
      case .knownZero: break
      case .failure(let error): throw error
      }
    }
    cursor += count
    return total
  }
}
