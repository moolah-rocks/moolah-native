import Foundation
import OSLog

/// Pure orchestrator that turns transactions and valued positions into an
/// `AccountPerformance` for a position-tracked investment account.
///
/// Cash flows are extracted from the transaction history using the
/// boundary-crossing rule: a leg in the account contributes a flow only
/// if it is an opening balance or the transaction also touches a
/// different account. Intra-account activity (trades, dividends, fees)
/// is reflected via the terminal value, not as flows.
///
/// Throws when any cash-flow conversion fails so the caller can mark the
/// performance unavailable; a partial result is never returned.
enum AccountPerformanceCalculator {
  private static let logger = Logger(
    subsystem: "com.moolah.app", category: "AccountPerformanceCalculator")

  // MARK: - Position-tracked

  /// Computes account-level performance for a position-tracked investment
  /// account. Throws when any cash-flow currency conversion fails — per
  /// Rule 11 the caller should treat the entire performance as
  /// unavailable, not partially populated.
  static func compute(
    accountId: UUID,
    transactions: [Transaction],
    valuedPositions: [ValuedPosition],
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService,
    now: Date = Date()
  ) async throws -> AccountPerformance {
    let flows: [CashFlow]
    do {
      flows = try await extractFlows(
        from: transactions,
        accountId: accountId,
        profileCurrency: profileCurrency,
        conversionService: conversionService)
    } catch {
      logger.warning(
        "Cash-flow conversion failed for account \(accountId, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      throw error
    }

    let currentValue = aggregatedValue(of: valuedPositions, in: profileCurrency)

    return assemble(
      flows: flows,
      currentValue: currentValue,
      profileCurrency: profileCurrency,
      now: now)
  }

  // MARK: - Multi-instrument (unified account-detail path)

  /// Computes account-level performance for the unified multi-instrument
  /// account-detail path (crypto / exchange / standard / group hosts), which
  /// carries a *set* of account ids rather than a single account.
  ///
  /// **Group boundary rule.** A transaction contributes external cash flows
  /// only when it touches exactly one member of `accountIds` (one member ⇒
  /// external counterparty; ≥2 members ⇒ an internal transfer between group
  /// members, excluded). This mirrors
  /// `PositionsHistoryBuilder.foldContributions`, so the tile's
  /// `totalContributions` and the chart's contribution baseline never
  /// disagree. For a single-account host (`accountIds.count == 1`) the rule
  /// reduces to the single-account boundary-crossing predicate.
  ///
  /// **Graceful degradation (Rule 11).** `currentValue` is aggregated from the
  /// already-valued `valuedPositions` (no further conversion), so it survives
  /// even when the flow history cannot be converted. Two degraded shapes both
  /// return `currentValue` with every other field `nil` — so the P&L and
  /// annualised-return tiles hide rather than mislead:
  ///   1. **No external flows** — a wallet funded solely by on-chain receives
  ///      / airdrops has no known cost basis. Unlike the single-account
  ///      `compute`, this path does NOT treat the whole balance as profit
  ///      (that would paint an airdrop wallet's entire value as gain).
  ///   2. **Flow conversion failed** — a rate lookup for a historical flow
  ///      threw; contributions are unavailable, but the current value is not.
  ///   3. **Row value in wrong instrument** — a `ValuedPosition` whose `value`
  ///      is not in `profileCurrency` (aggregate would trap on `+=`); routes
  ///      through `assemble` with `currentValue: nil`, yielding
  ///      `totalContributions` with `profitLoss`/`annualisedReturn` nil.
  ///
  /// Throws only `CancellationError` (propagated so a superseded valuator pass
  /// abandons cleanly); every other failure degrades in place.
  static func computeMultiInstrument(
    accountIds: Set<UUID>,
    transactions: [Transaction],
    valuedPositions: [ValuedPosition],
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService,
    now: Date = Date()
  ) async throws -> AccountPerformance {
    let currentValue = aggregatedValue(of: valuedPositions, in: profileCurrency)
    let flows: [CashFlow]
    do {
      flows = try await extractGroupFlows(
        from: transactions,
        accountIds: accountIds,
        profileCurrency: profileCurrency,
        conversionService: conversionService)
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      logger.warning(
        "Multi-instrument cash-flow conversion failed; showing current value only: \(error.localizedDescription, privacy: .public)"
      )
      return .currentValueOnly(currentValue, in: profileCurrency)
    }
    guard !flows.isEmpty else {
      return .currentValueOnly(currentValue, in: profileCurrency)
    }
    return assemble(
      flows: flows,
      currentValue: currentValue,
      profileCurrency: profileCurrency,
      now: now)
  }

  /// Group-aware cash-flow extraction: applies the single-member-touch rule
  /// (see `computeMultiInstrument`) then delegates the per-leg amount to the
  /// shared `AccountCashFlows.flowAmounts(for:)` so the boundary-crossing +
  /// on-date conversion logic lives in exactly one place. Per-leg `CashFlow`
  /// granularity is preserved; all legs of a transaction date at
  /// `transaction.date`.
  private static func extractGroupFlows(
    from transactions: [Transaction],
    accountIds: Set<UUID>,
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CashFlow] {
    var flows: [CashFlow] = []
    let sorted = transactions.sorted { $0.date < $1.date }
    for transaction in sorted {
      let membersTouched = Set(transaction.legs.compactMap(\.accountId))
        .intersection(accountIds)
      guard membersTouched.count == 1, let member = membersTouched.first else { continue }
      let amounts = try await AccountCashFlows.flowAmounts(
        for: transaction,
        accountId: member,
        hostCurrency: profileCurrency,
        service: conversionService)
      for amount in amounts {
        flows.append(CashFlow(date: transaction.date, amount: amount))
      }
    }
    return flows
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

  /// Cash-flow extraction. Delegates the per-leg "is this a flow"
  /// classification (opening balance OR boundary-crossing) and the
  /// on-date conversion to `AccountCashFlows.flowAmounts(for:)` so
  /// the boundary-crossing rule lives in exactly one place — see
  /// `Shared/AccountCashFlows.swift`. Per-leg `CashFlow` granularity
  /// is preserved by flat-mapping each transaction's returned
  /// amounts into one `CashFlow` per qualifying leg, all dated at
  /// `transaction.date` (the IRR / Modified-Dietz weighting code
  /// keys on date, not leg index).
  private static func extractFlows(
    from transactions: [Transaction],
    accountId: UUID,
    profileCurrency: Instrument,
    conversionService: any InstrumentConversionService
  ) async throws -> [CashFlow] {
    var flows: [CashFlow] = []
    let sorted = transactions.sorted { $0.date < $1.date }
    for transaction in sorted {
      let amounts = try await AccountCashFlows.flowAmounts(
        for: transaction,
        accountId: accountId,
        hostCurrency: profileCurrency,
        service: conversionService
      )
      for amount in amounts {
        flows.append(CashFlow(date: transaction.date, amount: amount))
      }
    }
    return flows
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

  /// Assembles the final `AccountPerformance` from extracted flows and
  /// the aggregated terminal value.
  private static func assemble(
    flows: [CashFlow],
    currentValue: InstrumentAmount?,
    profileCurrency: Instrument,
    now: Date
  ) -> AccountPerformance {
    guard let currentValue else {
      // Row 6: V failed but flows were extracted successfully. Surface
      // totalContributions and firstFlowDate so the caller can show
      // partial information (e.g. the "since Mar 2023" subtitle on the
      // p.a. tile remains useful even when the rate itself is
      // unavailable). profitLoss / profitLossPercent / annualisedReturn
      // all require V and stay nil.
      let totalContributions = flows.reduce(Decimal(0)) { $0 + $1.amount }
      return AccountPerformance(
        instrument: profileCurrency,
        currentValue: nil,
        totalContributions: InstrumentAmount(
          quantity: totalContributions, instrument: profileCurrency),
        profitLoss: nil,
        profitLossPercent: nil,
        annualisedReturn: nil,
        firstFlowDate: flows.first?.date)
    }
    guard let firstFlow = flows.first else {
      // No external flows: the entire current value is treated as gain.
      // Accounts funded only via intra-account trades or standalone income
      // have no external contribution baseline.
      // Same formula gives P/L = 0 when currentValue is also zero (empty
      // account).
      return AccountPerformance(
        instrument: profileCurrency,
        currentValue: currentValue,
        totalContributions: .zero(instrument: profileCurrency),
        profitLoss: currentValue,
        profitLossPercent: nil,
        annualisedReturn: nil,
        firstFlowDate: nil)
    }

    let totalContributions = flows.reduce(Decimal(0)) { $0 + $1.amount }
    // Decimal has no fractional `pow`; convert to Double at the IRR/Modified
    // Dietz boundary.
    let terminal = Double(truncating: currentValue.quantity as NSDecimalNumber)
    let totalDays = max(now.timeIntervalSince(firstFlow.date) / 86_400, 0)

    let plQuantity = currentValue.quantity - totalContributions
    let plPercent = modifiedDietzPercent(
      flows: flows, terminal: terminal, totalDays: totalDays)
    let annualised = IRRSolver.annualisedReturn(
      flows: flows, terminalValue: currentValue.quantity, terminalDate: now)

    return AccountPerformance(
      instrument: profileCurrency,
      currentValue: currentValue,
      totalContributions: InstrumentAmount(
        quantity: totalContributions, instrument: profileCurrency),
      profitLoss: InstrumentAmount(quantity: plQuantity, instrument: profileCurrency),
      profitLossPercent: plPercent,
      annualisedReturn: annualised,
      firstFlowDate: firstFlow.date)
  }

  /// `(V − ΣCᵢ) / Σ(wᵢ · Cᵢ)` with `wᵢ = (T − tᵢ) / T`. Same formula
  /// `IRRSolver` uses internally as its Newton-Raphson seed; we expose it
  /// here so the result is shown directly as the period return without
  /// re-deriving it from `IRRSolver`'s annualised output.
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
