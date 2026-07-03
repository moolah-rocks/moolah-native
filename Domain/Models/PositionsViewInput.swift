import Foundation

/// Immutable input passed to `PositionsView`. Computed properties on this type
/// are the single place where header / chart visibility rules live, so the
/// view itself stays a thin renderer with no policy.
///
/// All monetary fields on the rows are expressed in `hostCurrency`. Per the
/// project's sign convention (CLAUDE.md), value, cost basis, and gain/loss
/// preserve their sign — callers must never `abs()` them.
struct PositionsViewInput: Sendable, Hashable {
  let title: String
  let hostCurrency: Instrument
  let positions: [ValuedPosition]
  let historicalValue: HistoricalValueSeries?

  /// `[instrumentId: assetKey]` used to roll same-asset-across-chains crypto
  /// positions into a single holdings row. Empty (the default) means no
  /// rollup — every position stands alone, preserving pre-aggregation
  /// behaviour at call sites that don't supply it.
  let assetKeysByInstrumentId: [String: String]

  /// Account-level performance numbers for the host. Non-nil triggers
  /// the three-tile `AccountPerformanceTiles` strip in place of the
  /// single-row `PositionsHeader`. Non-investment-account hosts leave
  /// this `nil` and keep the existing header layout.
  let performance: AccountPerformance?

  /// `true` iff the account has ever held a non-host-currency position
  /// — i.e. the user's transactions include at least one trade leg in
  /// an instrument other than `hostCurrency`. Range-independent: derived
  /// from the full transaction set, not the current chart range.
  ///
  /// The view layer reads this to decide whether to render the chart-only
  /// surface when `shouldHide` is `true`. `hasHistoricalSeries` only
  /// answers "does the active range carry points right now"; that flips
  /// to `false` when the user opens an account whose last trade
  /// pre-dates the default range, so the chart never gets a chance to
  /// render. `hasAnyHistoricalActivity` survives that.
  let hasAnyHistoricalActivity: Bool

  /// `true` for position-tracked investment-account hosts, where the full
  /// surface (performance tiles, chart, positions table) is always shown
  /// for layout consistency — even with no open positions — rather than
  /// collapsing to a chart-only or transaction-only fallback. Other hosts
  /// (the transaction-list embedding, previews) leave this `false` and
  /// keep the `shouldHide` collapse.
  let alwaysShowsFullSurface: Bool

  /// `true` while the historical series is still being built asynchronously
  /// (progressive render). The positions table renders immediately; the
  /// chart area shows a loading placeholder until `historicalValue` arrives.
  /// Independent of `hasAnyHistoricalActivity` (which answers "does history
  /// exist at all", not "is it loading right now").
  let isHistoryLoading: Bool

  /// Single designated init with defaults so non-investment callers
  /// (the transaction list, all previews) only have to fill in the
  /// fields they care about. The investment-account path opts in to
  /// `performance`, `hasAnyHistoricalActivity`, and
  /// `alwaysShowsFullSurface` explicitly. Declared inside the struct
  /// body so it replaces Swift's synthesised memberwise init rather
  /// than co-existing with it (which would make every call ambiguous).
  init(
    title: String,
    hostCurrency: Instrument,
    positions: [ValuedPosition],
    historicalValue: HistoricalValueSeries?,
    assetKeysByInstrumentId: [String: String] = [:],
    performance: AccountPerformance? = nil,
    hasAnyHistoricalActivity: Bool = false,
    alwaysShowsFullSurface: Bool = false,
    isHistoryLoading: Bool = false
  ) {
    self.title = title
    self.hostCurrency = hostCurrency
    self.positions = positions
    self.historicalValue = historicalValue
    self.assetKeysByInstrumentId = assetKeysByInstrumentId
    self.performance = performance
    self.hasAnyHistoricalActivity = hasAnyHistoricalActivity
    self.alwaysShowsFullSurface = alwaysShowsFullSurface
    self.isHistoryLoading = isHistoryLoading
  }

  /// Sum of per-row values. `nil` if any row's `value` is `nil` — per the
  /// project rule "never display a partial aggregate", a single conversion
  /// failure marks the whole total unavailable.
  var totalValue: InstrumentAmount? {
    var total = InstrumentAmount.zero(instrument: hostCurrency)
    for row in positions {
      guard let value = row.value else { return nil }
      total += value
    }
    return total
  }

  /// Sum of per-row gains. Rows without a cost basis contribute zero (their
  /// gain/loss is undefined). `nil` if `totalValue` is unavailable.
  var totalGainLoss: InstrumentAmount? {
    guard totalValue != nil else { return nil }
    var total = InstrumentAmount.zero(instrument: hostCurrency)
    for row in positions {
      if let gain = row.gainLoss {
        total += gain
      }
    }
    return total
  }

  /// `true` iff at least one row has a cost basis AND the total is available.
  var showsPLPill: Bool {
    guard totalValue != nil else { return false }
    return positions.contains(where: { $0.hasCostBasis })
  }

  /// `true` iff the chart container is rendered at all. A non-empty
  /// aggregate historical series is sufficient — the chart shows at minimum
  /// a value line (the cost/gain-loss overlay is separately gated by the
  /// data-driven `PositionsChartBaselineResolver.showsBaseline(points:mode:)`).
  ///
  /// This is intentionally more permissive than `showsPLPill`, which
  /// additionally requires `totalValue` to be non-nil and at least one
  /// cost-bearing position.
  var showsChart: Bool {
    guard let series = historicalValue else { return false }
    return !series.total.isEmpty
  }

  /// Show a chart-area loading placeholder when the series is still being
  /// built and there is a table worth rendering beneath it.
  var showsChartLoadingPlaceholder: Bool {
    isHistoryLoading && !showsChart && !rendersNothing
  }

  /// `true` iff the all-positions chart line should render. False when any
  /// row's current value is unavailable — partial historical totals would be
  /// misleading.
  var showsAggregateChart: Bool { showsChart && totalValue != nil }

  /// `true` iff `historicalValue` exists and its aggregate `total` series
  /// has at least one point. The view layer reads this to decide whether
  /// a chart-only surface is worth rendering when `shouldHide` is `true` —
  /// e.g. a position-tracked investment account where every holding has
  /// been sold but the historical performance is still meaningful.
  var hasHistoricalSeries: Bool {
    guard let series = historicalValue else { return false }
    return !series.total.isEmpty
  }

  /// `true` iff more than one `Instrument.Kind` is represented. Drives whether
  /// the table renders per-group subtotals.
  var showsGroupSubtotals: Bool {
    let kinds = Set(positions.map(\.instrument.kind))
    return kinds.count > 1
  }

  /// `true` when `PositionsView` should render nothing. Two cases:
  /// 1. There are no positions at all (nothing to show).
  /// 2. Every non-zero-quantity position is in `hostCurrency` — the host
  ///    surface's balance already surfaces this, so a second "100 AUD" row
  ///    would be redundant noise.
  ///
  /// When `hostCurrency` differs from the underlying holdings' instrument
  /// (e.g. a BTC-denominated investment account reporting in AUD), the rule
  /// does not fire — the conversion columns still add information.
  var shouldHide: Bool {
    if positions.isEmpty { return true }
    let nonZeroInstruments = Set(
      positions.lazy.filter { $0.quantity != 0 }.map(\.instrument)
    )
    return nonZeroInstruments == [hostCurrency]
  }

  /// `true` when `PositionsView` collapses to `EmptyView`. `shouldHide`
  /// marks the positions list redundant with the host surface's balance,
  /// but position-tracked investment-account hosts
  /// (`alwaysShowsFullSurface`) override that and always render the full
  /// tiles/chart/table surface for layout consistency.
  var rendersNothing: Bool {
    shouldHide && !alwaysShowsFullSurface
  }

  /// The positions folded into asset rows for display. Crypto positions
  /// sharing an `assetKey` (per `assetKeysByInstrumentId`) merge into one row;
  /// stocks, fiat, and unmapped crypto stand alone.
  ///
  /// Computed, not stored: it folds on each access, consistent with this
  /// type's other computed aggregates (`totalValue`, `totalGainLoss`). Safe to
  /// memoize later only if profiling shows a hot path.
  var assetHoldings: [AssetHolding] {
    AssetHolding.fold(positions, assetKeys: assetKeysByInstrumentId, hostCurrency: hostCurrency)
  }
}
