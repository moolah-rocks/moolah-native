import Foundation

/// Pure orchestrator that turns the shared `HoldingsCostLedger` and valued
/// positions into an `AccountPerformance` for an account (or account set).
///
/// The three account-detail tiles are three distinct reads of the shared
/// ledger — a *stock* and a *rate*, deliberately decoupled:
///
///   - **Amount invested** = `ledger.remainingInvested(accountIds:onOrBefore:)`
///     — the remaining cost basis of currently-held lots (≥ 0 by construction;
///     `nil` if any in-scope instrument failed conversion, Rule 11). Carried by
///     `AccountPerformance.amountInvested`.
///   - **Gain** = `currentValue − amountInvested` (unrealised).
///   - **Return** = money-weighted IRR over `ledger.cashFlows(accountIds:)`.
///     Received tokens are positive inflows at market value, so a self-custody
///     wallet funded purely by on-chain receives gets a finite return (the
///     regression the old negative-`contributions` path could not produce).
///
/// The single-account (`compute`) and multi-instrument (`computeMultiInstrument`)
/// entry points run the same ledger read; they differ only in whether the
/// caller supplies one account id or a set.
enum AccountPerformanceCalculator {

  // MARK: - Position-tracked (single account, ledger-sourced)

  /// Computes account-level performance for a position-tracked investment
  /// account from the shared profile-wide `ledger`. Throws only
  /// `CancellationError` (a superseded pass abandons cleanly); the ledger is
  /// pre-built, so no conversion happens here.
  static func compute(
    accountId: UUID,
    valuedPositions: [ValuedPosition],
    profileCurrency: Instrument,
    ledger: HoldingsCostLedger,
    now: Date = Date()
  ) async throws -> AccountPerformance {
    try await performance(
      accountIds: [accountId],
      valuedPositions: valuedPositions,
      profileCurrency: profileCurrency,
      ledger: ledger,
      now: now)
  }

  // MARK: - Multi-instrument (unified account-detail path, ledger-sourced)

  /// Computes account-level performance for the unified multi-instrument
  /// account-detail path (crypto / exchange / standard / group hosts), which
  /// carries a *set* of account ids rather than a single account.
  ///
  /// **Group boundary rule.** `ledger.cashFlows(accountIds:)` keeps only flows
  /// whose account is in the set and whose counterparty is outside it, so a
  /// transfer between two members of the set nets to zero (internal) while a
  /// transfer to a sibling outside the set is an external flow — matching the
  /// chart baseline, which reads the same ledger.
  ///
  /// Throws only `CancellationError`; every field degrades in place otherwise
  /// (unavailable amount-invested → invested/gain nil while current value
  /// survives, per Rule 11 — no phantom zeros).
  static func computeMultiInstrument(
    accountIds: Set<UUID>,
    valuedPositions: [ValuedPosition],
    profileCurrency: Instrument,
    ledger: HoldingsCostLedger,
    now: Date = Date()
  ) async throws -> AccountPerformance {
    try await performance(
      accountIds: accountIds,
      valuedPositions: valuedPositions,
      profileCurrency: profileCurrency,
      ledger: ledger,
      now: now)
  }

  /// Shared ledger-sourced core for both entry points. Reads the three
  /// surfaces off the shared ledger — amount invested (a stock) and cash
  /// flows (a rate's inputs) come from *different* queries — then assembles.
  /// `try Task.checkCancellation()` lets a superseded valuator/refresh pass
  /// abandon before publishing.
  private static func performance(
    accountIds: Set<UUID>,
    valuedPositions: [ValuedPosition],
    profileCurrency: Instrument,
    ledger: HoldingsCostLedger,
    now: Date
  ) async throws -> AccountPerformance {
    try Task.checkCancellation()
    let currentValue = aggregatedValue(of: valuedPositions, in: profileCurrency)
    let amountInvested = ledger.remainingInvested(accountIds: accountIds, onOrBefore: now)
    // Rule 11: `remainingInvested` returns nil under the SAME scope condition
    // that drops in-scope entries from `cashFlows` — a genuine conversion
    // failure on a held instrument. So a nil here means BOTH the invested
    // figure (partial lots) AND the flow series (dropped entries) are
    // incomplete; an IRR / first-flow date over the truncated `cashFlows` would
    // look complete while being understated. Degrade every derived figure to
    // current-value-only — the already-valued current value still shows.
    guard let amountInvested else {
      return .currentValueOnly(currentValue, in: profileCurrency)
    }
    let flows = ledger.cashFlows(accountIds: accountIds)
    return assembleFromLedger(
      flows: flows,
      amountInvested: amountInvested,
      currentValue: currentValue,
      profileCurrency: profileCurrency,
      now: now)
  }

  /// Assembles the ledger-sourced `AccountPerformance` from an available
  /// `amountInvested` (the remaining cost basis — the "Amount invested" tile).
  /// Gain is `currentValue − amountInvested`; the annualised return is the IRR
  /// over the market-valued `flows`. When the current value is unavailable the
  /// gain / percentage / annualised figures degrade to `nil` while the amount
  /// invested and first-flow date survive (Rule 11 — the partial shape).
  private static func assembleFromLedger(
    flows: [CashFlow],
    amountInvested: Decimal,
    currentValue: InstrumentAmount?,
    profileCurrency: Instrument,
    now: Date
  ) -> AccountPerformance {
    AccountPerformance(
      instrument: profileCurrency,
      currentValue: currentValue,
      amountInvested: InstrumentAmount(quantity: amountInvested, instrument: profileCurrency),
      profitLoss: gain(
        currentValue: currentValue, amountInvested: amountInvested, in: profileCurrency),
      profitLossPercent: gainPercent(currentValue: currentValue, amountInvested: amountInvested),
      annualisedReturn: annualisedReturn(flows: flows, currentValue: currentValue, now: now),
      firstFlowDate: flows.first?.date)
  }

  /// Unrealised gain `currentValue − amountInvested`, or `nil` when the current
  /// value is unavailable (Rule 11 — no partial figure).
  private static func gain(
    currentValue: InstrumentAmount?, amountInvested: Decimal, in profileCurrency: Instrument
  ) -> InstrumentAmount? {
    guard let currentValue else { return nil }
    return InstrumentAmount(
      quantity: currentValue.quantity - amountInvested, instrument: profileCurrency)
  }

  /// Total return on the remaining invested capital: `gain / amountInvested`.
  /// `nil` when amount invested is zero (no baseline to measure against) or the
  /// current value is unavailable. Distinct from the annualised return: this is
  /// a simple (not time-weighted) ratio shown beside the gain figure.
  private static func gainPercent(
    currentValue: InstrumentAmount?, amountInvested: Decimal
  ) -> Decimal? {
    guard let currentValue, amountInvested != 0 else { return nil }
    return (currentValue.quantity - amountInvested) / amountInvested
  }

  /// Money-weighted annualised return (IRR) over the ledger's market-valued
  /// flows, terminal = `currentValue`. `nil` when the current value is
  /// unavailable or `IRRSolver` cannot annualise (empty flows, span < 1 day,
  /// pathological multi-root).
  private static func annualisedReturn(
    flows: [CashFlow], currentValue: InstrumentAmount?, now: Date
  ) -> Decimal? {
    guard let currentValue else { return nil }
    return IRRSolver.annualisedReturn(
      flows: flows, terminalValue: currentValue.quantity, terminalDate: now)
  }

  /// Sum of valued positions in `profileCurrency`, or `nil` if any row's
  /// `value` is missing — Rule 11 forbids partial sums.
  private static func aggregatedValue(
    of valued: [ValuedPosition], in profileCurrency: Instrument
  ) -> InstrumentAmount? {
    var total = InstrumentAmount.zero(instrument: profileCurrency)
    for row in valued {
      guard let value = row.value else { return nil }
      // Rule 11: a row valued in a different instrument cannot be safely added
      // to `total` (InstrumentAmount.+ traps on instrument mismatch). Treat
      // the mismatched row as unavailable so the aggregate degrades cleanly.
      guard value.instrument == profileCurrency else { return nil }
      total += value
    }
    return total
  }

}
