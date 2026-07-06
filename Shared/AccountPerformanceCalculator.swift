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
/// entry points now run the same ledger read; they differ only in whether the
/// caller supplies one account id or a set. `computeLegacy` (manual-valuation
/// accounts, which have no ledger) keeps its own net-deposit / Modified-Dietz
/// derivation and is unchanged.
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

  // MARK: - Manual valuation

  /// Manual-valuation accounts (the legacy path): cash flows are derived
  /// from consecutive `dailyBalance` deltas; the terminal value is the
  /// most recent `InvestmentValue`. Synchronous — no instrument conversion
  /// is performed. This method assumes every `AccountDailyBalance.balance`
  /// is denominated in `instrument`; callers must ensure this invariant
  /// holds (legacy accounts are mono-instrument by construction). Passing
  /// mixed-instrument balances produces arithmetically meaningless flows
  /// without trapping.
  ///
  /// `now` is injected so tests can pin the reference date. Production
  /// callers pass `Date()`.
  static func computeLegacy(
    dailyBalances: [AccountDailyBalance],
    values: [InvestmentValue],
    instrument: Instrument,
    now: Date = Date()
  ) -> AccountPerformance {
    guard let latest = values.max(by: { $0.date < $1.date }) else {
      return .unavailable(in: instrument)
    }

    let sortedBalances = dailyBalances.sorted { $0.date < $1.date }
    var flows: [CashFlow] = []
    var prior = Decimal(0)
    for entry in sortedBalances {
      let delta = entry.balance.quantity - prior
      if delta != 0 {
        flows.append(CashFlow(date: entry.date, amount: delta))
      }
      prior = entry.balance.quantity
    }

    return assemble(
      flows: flows,
      currentValue: latest.value,
      profileCurrency: instrument,
      now: now)
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

  /// Assembles the legacy (manual-valuation) `AccountPerformance` from
  /// net-deposit flows and the terminal value. Here `amountInvested` carries
  /// the net-deposit sum and the percentage is Modified Dietz — the correct
  /// derivation for accounts with no cost-basis lots. The ledger path uses
  /// `assembleFromLedger` (remaining cost basis + IRR) instead.
  private static func assemble(
    flows: [CashFlow],
    currentValue: InstrumentAmount?,
    profileCurrency: Instrument,
    now: Date
  ) -> AccountPerformance {
    guard let currentValue else {
      // Row 6: V failed but flows were extracted successfully. Surface
      // the invested amount and firstFlowDate so the caller can show
      // partial information (e.g. the "since Mar 2023" subtitle on the
      // Return tile remains useful even when the rate itself is
      // unavailable). profitLoss / profitLossPercent / annualisedReturn
      // all require V and stay nil.
      let netDeposits = flows.reduce(Decimal(0)) { $0 + $1.amount }
      return AccountPerformance(
        instrument: profileCurrency,
        currentValue: nil,
        amountInvested: InstrumentAmount(
          quantity: netDeposits, instrument: profileCurrency),
        profitLoss: nil,
        profitLossPercent: nil,
        annualisedReturn: nil,
        firstFlowDate: flows.first?.date)
    }
    guard let firstFlow = flows.first else {
      // No flows: the entire current value is treated as gain. A manual
      // account with a value but no recorded deposits has no baseline against
      // which to subtract. Same formula gives P/L = 0 when currentValue is
      // also zero (empty account).
      return AccountPerformance(
        instrument: profileCurrency,
        currentValue: currentValue,
        amountInvested: .zero(instrument: profileCurrency),
        profitLoss: currentValue,
        profitLossPercent: nil,
        annualisedReturn: nil,
        firstFlowDate: nil)
    }

    let netDeposits = flows.reduce(Decimal(0)) { $0 + $1.amount }
    // Decimal has no fractional `pow`; convert to Double at the IRR/Modified
    // Dietz boundary.
    let terminal = Double(truncating: currentValue.quantity as NSDecimalNumber)
    let totalDays = max(now.timeIntervalSince(firstFlow.date) / 86_400, 0)

    let plQuantity = currentValue.quantity - netDeposits
    let plPercent = modifiedDietzPercent(
      flows: flows, terminal: terminal, totalDays: totalDays)
    let annualised = IRRSolver.annualisedReturn(
      flows: flows, terminalValue: currentValue.quantity, terminalDate: now)

    return AccountPerformance(
      instrument: profileCurrency,
      currentValue: currentValue,
      amountInvested: InstrumentAmount(
        quantity: netDeposits, instrument: profileCurrency),
      profitLoss: InstrumentAmount(quantity: plQuantity, instrument: profileCurrency),
      profitLossPercent: plPercent,
      annualisedReturn: annualised,
      firstFlowDate: firstFlow.date)
  }

  /// `(V − ΣCᵢ) / Σ(wᵢ · Cᵢ)` with `wᵢ = (T − tᵢ) / T`. Same formula
  /// `IRRSolver` uses internally as its Newton-Raphson seed; we expose it
  /// here so the result is shown directly as the period return without
  /// re-deriving it from `IRRSolver`'s annualised output. Used by the legacy
  /// manual-valuation path only.
  ///
  /// Returns `nil` for spans < 1 day or zero weighted-capital.
  private static func modifiedDietzPercent(
    flows: [CashFlow], terminal: Double, totalDays: Double
  ) -> Decimal? {
    guard totalDays >= 1, let firstFlow = flows.first else { return nil }
    // Decimal has no fractional `pow`; convert to Double at the Modified
    // Dietz boundary.
    let firstDate = firstFlow.date
    var contributionSum = 0.0
    var weightedSum = 0.0
    for flow in flows {
      let days = flow.date.timeIntervalSince(firstDate) / 86_400
      let weight = (totalDays - days) / totalDays
      let amount = Double(truncating: flow.amount as NSDecimalNumber)
      contributionSum += amount
      weightedSum += weight * amount
    }
    guard weightedSum != 0 else { return nil }
    return Decimal((terminal - contributionSum) / weightedSum)
  }
}
