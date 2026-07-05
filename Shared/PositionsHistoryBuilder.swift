import Foundation
import OSLog

/// Builds the `(value, cost)` time series the chart in `PositionsView` plots.
///
/// **Cost basis line is exact.** Cost only changes on transaction events, so
/// we walk transactions chronologically through `CostBasisEngine` once and
/// emit the resulting `(quantity, remainingCost)` snapshot for *every* day
/// in the visible range. Days between events carry forward the prior
/// snapshot — no interpolation, no approximation.
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
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "PositionsHistoryBuilder")

  @concurrent
  func build(
    transactions: [Transaction],
    accountIds: Set<UUID>,
    hostCurrency: Instrument,
    range: PositionsTimeRange,
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
      hostCurrency: hostCurrency)
    var state = BuildState()
    do {
      try await preFoldHistory(before: start, context: context, state: &state)
    } catch is CancellationError {
      return state.series(hostCurrency: hostCurrency)
    } catch {
      // apply() only re-throws CancellationError; any other error is
      // already swallowed and latched.
    }

    let pending: [PendingDay]
    do {
      pending = try await foldPendingDays(
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
  ) async throws -> [PendingDay] {
    var pending: [PendingDay] = []
    var day = start
    while day <= endDay {
      if Task.isCancelled { throw CancellationError() }
      do {
        try await applyTransactions(on: day, context: context, state: &state)
      } catch is CancellationError {
        throw CancellationError()
      } catch {
        // see preFoldHistory comment
      }
      pending.append(recordDailyPoints(for: day, state: state))
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
    now: Date = Date()
  ) async -> HistoricalValueSeries {
    await build(
      transactions: transactions,
      accountIds: [accountId],
      hostCurrency: hostCurrency,
      range: range,
      now: now)
  }

  /// Pre-fold any transactions strictly before `start` so the snapshot at
  /// `start` already reflects historical buys.
  private func preFoldHistory(
    before start: Date,
    context: BuildContext,
    state: inout BuildState
  ) async throws {
    while state.txnIndex < context.sortedTxns.count
      && Calendar.utc.startOfDay(for: context.sortedTxns[state.txnIndex].date) < start
    {
      try await apply(
        transaction: context.sortedTxns[state.txnIndex],
        accountIds: context.accountIds,
        hostCurrency: context.hostCurrency,
        state: &state
      )
      state.txnIndex += 1
    }
  }

  /// Fold every transaction whose start-of-day is `day` into the running state.
  private func applyTransactions(
    on day: Date,
    context: BuildContext,
    state: inout BuildState
  ) async throws {
    while state.txnIndex < context.sortedTxns.count
      && Calendar.utc.startOfDay(for: context.sortedTxns[state.txnIndex].date) == day
    {
      try await apply(
        transaction: context.sortedTxns[state.txnIndex],
        accountIds: context.accountIds,
        hostCurrency: context.hostCurrency,
        state: &state
      )
      state.txnIndex += 1
    }
  }

  /// Immutable inputs threaded through `build`'s per-day loop.
  private struct BuildContext {
    let sortedTxns: [Transaction]
    let accountIds: Set<UUID>
    let hostCurrency: Instrument
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
    var engine = CostBasisEngine()
    var txnIndex = 0
    var perInstrument: [String: [HistoricalValueSeries.Point]] = [:]
    var total: [HistoricalValueSeries.Point] = []
    /// Running cumulative contributions in `hostCurrency`. `nil`
    /// once any contribution conversion has thrown — sticky latch
    /// never reset within a build (Rule 11 cumulative-sum
    /// semantics). The single-`Decimal?` design (rather than
    /// `Decimal` + `Bool`) lets the type system enforce the
    /// invariant "unavailable contributions have no running value".
    var contributions: Decimal? = 0

    func series(hostCurrency: Instrument) -> HistoricalValueSeries {
      HistoricalValueSeries(
        hostCurrency: hostCurrency, total: total, perInstrument: perInstrument)
    }
  }

  /// Fold one transaction into the running quantity dict, FIFO engine,
  /// and contributions accumulator.
  ///
  /// Quantities update directly from the account's signed leg quantities
  /// (so an ETH→BTC swap subtracts ETH and adds BTC, and a cash deposit
  /// increments the host-currency balance). Cost basis updates via the
  /// shared `TradeEventClassifier`, which handles fiat-paired trades AND
  /// crypto-to-crypto swaps — for a swap, ETH gets a sell event (proceeds =
  /// host-currency value of ETH on this date) and BTC gets a buy event (cost
  /// = host-currency value of BTC on this date).
  ///
  /// Host-currency (cash) legs are included in `quantities` so the value
  /// line reflects the true total account balance — cash holdings plus
  /// non-cash position value. Cost basis is still derived exclusively via
  /// `TradeEventClassifier` (unchanged).
  ///
  /// Contributions are folded via `foldContributions(transaction:accountIds:hostCurrency:state:)`.
  /// Throws `CancellationError` (and only `CancellationError`); general
  /// conversion errors set the sticky latch and stay swallowed.
  private func apply(
    transaction: Transaction,
    accountIds: Set<UUID>,
    hostCurrency: Instrument,
    state: inout BuildState
  ) async throws {
    let accountLegs = transaction.legs.filter {
      $0.accountId.map { accountIds.contains($0) } ?? false
    }
    for leg in accountLegs {
      state.quantities[leg.instrument, default: 0] += leg.quantity
    }

    do {
      let classification = try await TradeEventClassifier.classify(
        legs: accountLegs,
        on: transaction.date,
        hostCurrency: hostCurrency,
        conversionService: conversionService
      )
      for buy in classification.buys {
        state.engine.processBuy(
          instrument: buy.instrument,
          quantity: buy.quantity,
          costPerUnit: buy.costPerUnit,
          date: transaction.date)
      }
      for sell in classification.sells {
        _ = state.engine.processSell(
          instrument: sell.instrument,
          quantity: sell.quantity,
          proceedsPerUnit: sell.proceedsPerUnit,
          date: transaction.date)
      }
    } catch is CancellationError {
      throw CancellationError()
    } catch {
      // A failed conversion when classifying a swap means we cannot derive
      // a cost basis for this leg. Quantities still update so the value
      // line is correct; cost basis on the affected instrument simply
      // stops advancing (the chart will draw a flat dashed line through
      // the gap, which is the honest representation of "we don't know").
      logger.warning(
        "TradeEventClassifier failed for txn \(transaction.id, privacy: .public) on \(transaction.date, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }

    try await foldContributions(
      transaction: transaction,
      accountIds: accountIds,
      hostCurrency: hostCurrency,
      state: &state)
  }

}

// MARK: - Contributions folding

extension PositionsHistoryBuilder {
  /// Fold cash-flow contributions for one transaction into the running total
  /// (sticky latch — see `BuildState` docs).
  ///
  /// A flow counts for the group only if the transaction touches exactly one
  /// member of `accountIds` (single member → external counterpart). Touching
  /// ≥2 members means an internal transfer → excluded. Uses
  /// `AccountCashFlows.flowAmounts(for:)` — the same boundary-crossing
  /// predicate `AccountPerformanceCalculator` uses, so the chart and the tile
  /// cannot disagree on a per-flow basis. Throws `CancellationError` (and
  /// only `CancellationError`); general conversion errors latch
  /// `state.contributions` to `nil` and stay swallowed.
  private func foldContributions(
    transaction: Transaction,
    accountIds: Set<UUID>,
    hostCurrency: Instrument,
    state: inout BuildState
  ) async throws {
    guard let running = state.contributions else { return }
    let membersTouched = Set(transaction.legs.compactMap(\.accountId)).intersection(accountIds)
    guard membersTouched.count == 1, let member = membersTouched.first else {
      return
    }
    do {
      let amounts = try await AccountCashFlows.flowAmounts(
        for: transaction,
        accountId: member,
        hostCurrency: hostCurrency,
        service: conversionService
      )
      if !amounts.isEmpty {
        state.contributions = running + amounts.reduce(0, +)
      }
    } catch is CancellationError {
      // Rule 11: don't let a stale partial total reach an emitted
      // point. Latch first, then propagate.
      state.contributions = nil
      throw CancellationError()
    } catch {
      state.contributions = nil
      logger.warning(
        "AccountCashFlows.flowAmounts failed for txn \(transaction.id, privacy: .public) on \(transaction.date, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
