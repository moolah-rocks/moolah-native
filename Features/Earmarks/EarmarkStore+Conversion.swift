import Foundation

extension EarmarkStore {
  // The members below are module-internal (not `private`) only because
  // `EarmarkStore.swift` calls them across the file boundary. They are
  // not intended as API for any other type — treat them as `private` to
  // the `EarmarkStore` family.

  /// Single pass over every earmark. Returns whether a retry is warranted:
  /// `true` if any conversion failed, *or* if a fresher snapshot superseded
  /// this pass before it could publish — reporting the superseded pass as
  /// "failed" stops the caller from treating a stale success as a reason to
  /// cancel the retry loop the superseding pass may still need. A cancelled
  /// pass returns `false` to short-circuit cleanly during teardown.
  ///
  /// Iterates all earmarks (not just `visibleEarmarks`) so per-earmark
  /// balances populate regardless of `showHidden` — otherwise toggling
  /// "Show Hidden" surfaces a permanent spinner on hidden rows that no
  /// recompute ever filled in. The grand total still sums only visible
  /// earmarks so it matches what the user sees.
  func runConversionAttempt(generation: UInt64) async -> Bool {
    var anyFailed = false
    var balances: [UUID: InstrumentAmount] = [:]
    var saved: [UUID: InstrumentAmount] = [:]
    var spent: [UUID: InstrumentAmount] = [:]
    var grandTotal = InstrumentAmount.zero(instrument: targetInstrument)
    var grandTotalValid = true
    let zeroInTarget = InstrumentAmount.zero(instrument: targetInstrument)

    for earmark in earmarks {
      let isVisible = showHidden || !earmark.isHidden
      do {
        let totals = try await convertEarmarkPositions(earmark)
        guard !Task.isCancelled else { return false }
        balances[earmark.id] = totals.balance
        saved[earmark.id] = totals.saved
        spent[earmark.id] = totals.spent

        // Only visible earmarks contribute to the displayed grand total.
        // Clamp negative balances to zero so they don't reduce the total.
        if isVisible, grandTotalValid {
          let convertedToTarget = try await conversionService.convertAmount(
            totals.balance, to: targetInstrument, on: Date())
          guard !Task.isCancelled else { return false }
          grandTotal += max(convertedToTarget, zeroInTarget)
        }
      } catch {
        anyFailed = true
        // A failure on a hidden earmark shouldn't blank the total — only
        // visible earmarks contribute to it. Hidden-earmark failures still
        // mark `anyFailed` so the retry loop kicks in (and a later toggle
        // doesn't surface a spinner because no retry was scheduled).
        if isVisible { grandTotalValid = false }
        logger.warning(
          "Conversion failed for earmark \(earmark.name): \(error.localizedDescription)")
      }
    }

    guard !Task.isCancelled else { return false }
    // Drop this pass if a fresher authoritative snapshot landed while we were
    // suspended — publishing over stale `earmarks` would clobber the fresher
    // one (see #1209). Return `true` (not `anyFailed`): this stale pass may
    // have "succeeded" over old data, but reporting success would let the
    // caller cancel the retry the superseding pass needs.
    guard snapshotGeneration == generation else { return true }

    let total = grandTotalValid ? grandTotal : nil
    publishConvertedTotals(balances: balances, saved: saved, spent: spent, total: total)
    return anyFailed
  }

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
