import Foundation

/// Builds the `(value, cost)` time series the chart in `PositionsChartPane` plots.
///
/// **Amount-invested / cost line is exact.** Remaining amount invested only
/// changes on cost-basis events, so we read each day's remaining invested
/// (aggregate) and per-instrument remaining cost from the profile-wide
/// `HoldingsCostLedger` change-points — carrying forward the latest
/// change-point at-or-before the day. No interpolation, no approximation.
/// The quantity fold (driving the value line) still runs over the **viewed**
/// account's transactions; the `ledger` is **profile-wide** (so a
/// tracked→tracked transfer's source lots are visible), queried per viewed
/// account. A `nil` ledger (a genuine build failure at the call site)
/// suppresses every baseline — the value line still renders (Rule 11).
///
/// **Value line is queried daily.** For each day `d` in
/// `[startOfRange ... today]` and each instrument with a non-zero holding
/// on `d`, we ask the conversion service for `convert(qty, instrument,
/// hostCurrency, on: d)`. The conversion service is backed by
/// `StockPriceCache` / `ExchangeRateCache` / `CryptoPriceCache`, so the
/// only network calls are for prices not yet in cache; subsequent loads of
/// the same chart (and overlapping ranges across users of the same
/// instrument) are O(1) per day. There is no sampling, no smoothing — the
/// chart shows the actual portfolio value on every day.
///
/// Aggregate points are emitted only when *every* contributing
/// per-instrument conversion succeeds on that date — partial sums are
/// forbidden by `guides/INSTRUMENT_CONVERSION_GUIDE.md` Rule 11. A
/// per-instrument series whose conversion fails for some days simply
/// omits those days; sibling instruments still chart.
///
/// Cancellation: callers should run this from a `.task { ... }` so it is
/// torn down when the view goes away. We check `Task.isCancelled` once per
/// day to bail out quickly on dismissal.
struct PositionsHistoryBuilder: Sendable {
  let conversionService: any InstrumentConversionService

  @concurrent
  func build(
    transactions: [Transaction],
    accountIds: Set<UUID>,
    hostCurrency: Instrument,
    range: PositionsTimeRange,
    ledger: HoldingsCostLedger?,
    now: Date = Date()
  ) async -> HistoricalValueSeries {
    let sortedTxns =
      transactions
      .filter { $0.legs.contains(where: { $0.accountId.map { accountIds.contains($0) } ?? false }) }
      .sorted { $0.date < $1.date }

    guard let firstTxnDate = sortedTxns.first?.date else {
      return HistoricalValueSeries(
        hostCurrency: hostCurrency, total: [], perInstrument: [:])
    }

    let cutoff = range.cutoff(from: now) ?? firstTxnDate
    let start = Calendar.utc.startOfDay(for: max(cutoff, firstTxnDate))
    let endDay = Calendar.utc.startOfDay(for: now)
    guard endDay >= start else {
      return HistoricalValueSeries(
        hostCurrency: hostCurrency, total: [], perInstrument: [:])
    }

    let context = BuildContext(
      sortedTxns: sortedTxns,
      accountIds: accountIds,
      hostCurrency: hostCurrency,
      ledger: ledger)
    var state = BuildState()
    preFoldHistory(before: start, context: context, state: &state)

    let pending: [PendingDay]
    do {
      pending = try foldPendingDays(
        start: start, endDay: endDay, context: context, state: &state)
    } catch {
      // Cancellation during the fold: view is being torn down; return what we have.
      return state.series(hostCurrency: hostCurrency)
    }

    // One flat batch of value conversions across every (instrument, day).
    let outcomes: [BatchConversionOutcome]
    do {
      outcomes = try await convertPending(pending, hostCurrency: hostCurrency)
    } catch {
      // CancellationError (or any thrown batch error): the view is being
      // torn down; return whatever the fold produced (no value points).
      return state.series(hostCurrency: hostCurrency)
    }

    if Task.isCancelled { return state.series(hostCurrency: hostCurrency) }

    assemble(pending: pending, outcomes: outcomes, into: &state)
    return state.series(hostCurrency: hostCurrency)
  }

  /// Walk `start...endDay`, folding each day's transactions and recording
  /// (not yet converting) that day's held-instrument points. Throws
  /// `CancellationError` if cancellation was observed, so the caller can
  /// bail without batching.
  private func foldPendingDays(
    start: Date, endDay: Date, context: BuildContext, state: inout BuildState
  ) throws -> [PendingDay] {
    var pending: [PendingDay] = []
    var day = start
    while day <= endDay {
      if Task.isCancelled { throw CancellationError() }
      applyTransactions(on: day, context: context, state: &state)
      pending.append(
        recordDailyPoints(
          for: day, state: state, accountIds: context.accountIds, ledger: context.ledger))
      guard let next = Calendar.utc.date(byAdding: .day, value: 1, to: day) else { break }
      day = next
    }
    return pending
  }

  /// Single-account convenience overload. Forwards to the `Set<UUID>` version.
  func build(
    transactions: [Transaction],
    accountId: UUID,
    hostCurrency: Instrument,
    range: PositionsTimeRange,
    ledger: HoldingsCostLedger?,
    now: Date = Date()
  ) async -> HistoricalValueSeries {
    await build(
      transactions: transactions,
      accountIds: [accountId],
      hostCurrency: hostCurrency,
      range: range,
      ledger: ledger,
      now: now)
  }

  /// Pre-fold any transactions strictly before `start` so the snapshot at
  /// `start` already reflects historical holdings quantities.
  private func preFoldHistory(
    before start: Date,
    context: BuildContext,
    state: inout BuildState
  ) {
    while state.txnIndex < context.sortedTxns.count
      && Calendar.utc.startOfDay(for: context.sortedTxns[state.txnIndex].date) < start
    {
      apply(
        transaction: context.sortedTxns[state.txnIndex],
        accountIds: context.accountIds,
        state: &state)
      state.txnIndex += 1
    }
  }

  /// Fold every transaction whose start-of-day is `day` into the running state.
  private func applyTransactions(
    on day: Date,
    context: BuildContext,
    state: inout BuildState
  ) {
    while state.txnIndex < context.sortedTxns.count
      && Calendar.utc.startOfDay(for: context.sortedTxns[state.txnIndex].date) == day
    {
      apply(
        transaction: context.sortedTxns[state.txnIndex],
        accountIds: context.accountIds,
        state: &state)
      state.txnIndex += 1
    }
  }

  /// Immutable inputs threaded through `build`'s per-day loop.
  private struct BuildContext {
    let sortedTxns: [Transaction]
    let accountIds: Set<UUID>
    let hostCurrency: Instrument
    /// Profile-wide cost ledger driving `invested`/`cost`; `nil` when the
    /// ledger is unavailable (a genuine build failure at the call site) —
    /// every baseline is then suppressed (Rule 11), the value line still
    /// renders.
    let ledger: HoldingsCostLedger?
  }

  /// Mutable running state threaded through `build`'s per-day loop.
  /// Exclusively owned by the single `@concurrent` build task; no
  /// other task ever holds a reference. The `inout`-across-`await`
  /// usage in `apply` is therefore safe — there is no concurrent
  /// reader or writer.
  ///
  /// Not `private`: shared with the batch-conversion assembly pass in
  /// `PositionsHistoryBuilder+Batch.swift`.
  struct BuildState {
    var quantities: [Instrument: Decimal] = [:]
    var txnIndex = 0
    var perInstrument: [String: [HistoricalValueSeries.Point]] = [:]
    var total: [HistoricalValueSeries.Point] = []

    func series(hostCurrency: Instrument) -> HistoricalValueSeries {
      HistoricalValueSeries(
        hostCurrency: hostCurrency, total: total, perInstrument: perInstrument)
    }
  }

  /// Fold one transaction's held quantities into the running quantity dict.
  ///
  /// Quantities update directly from the account's signed leg quantities
  /// (so an ETH→BTC swap subtracts ETH and adds BTC, and a cash deposit
  /// increments the host-currency balance). Host-currency (cash) legs are
  /// included so the value line reflects the true total account balance —
  /// cash holdings plus non-cash position value.
  ///
  /// Cost basis / amount invested are no longer folded here — they are read
  /// per day from the profile-wide `HoldingsCostLedger` in the batch pass
  /// (`recordDailyPoints`), so this fold is pure and non-throwing.
  private func apply(
    transaction: Transaction,
    accountIds: Set<UUID>,
    state: inout BuildState
  ) {
    let accountLegs = transaction.legs.filter {
      $0.accountId.map { accountIds.contains($0) } ?? false
    }
    for leg in accountLegs {
      state.quantities[leg.instrument, default: 0] += leg.quantity
    }
  }

}
