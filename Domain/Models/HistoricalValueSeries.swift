import Foundation

/// Daily (or sampled) `(value, cost)` time series in a single host currency,
/// driving the chart in `PositionsView`.
///
/// `total` is the account-wide aggregate: at each sample date `value` is the
/// sum of converted per-instrument values and `cost` is the sum of remaining
/// cost bases. `perInstrument` carries the same series per instrument id, used
/// when a single row is selected and the chart filters to that instrument.
///
/// The series excludes any sample date whose conversion failed for the
/// relevant instrument (or for any instrument, in the case of `total`); the
/// project rule "never display a partial aggregate" means an aggregate point
/// is only emitted if every contributing per-instrument conversion succeeded
/// on that date. Callers can therefore plot what is here without further
/// guards.
struct HistoricalValueSeries: Sendable, Hashable {
  struct Point: Sendable, Hashable {
    let date: Date
    /// Market value in the enclosing series' `hostCurrency`.
    let value: Decimal
    /// Remaining cost basis of currently-held lots in `hostCurrency`.
    /// Meaningful for both aggregate and per-instrument series.
    let cost: Decimal
    /// Cumulative net external contributions to the account in
    /// `hostCurrency`, evaluated at this date. Populated only for
    /// the aggregate (account-level) series; per-instrument series
    /// leave this `nil`. `nil` does not mean zero — it means
    /// "not applicable at this granularity" (per-instrument) or
    /// "conversion failure for some flow on or before this date"
    /// (Rule 11 — see `PositionsHistoryBuilder`).
    let contributions: Decimal?
  }

  let hostCurrency: Instrument
  /// Aggregate series. May be empty when every sample failed.
  let total: [Point]
  /// Per-instrument series keyed by `Instrument.id`.
  let perInstrument: [String: [Point]]

  /// All instrument ids represented in the per-instrument map.
  var instruments: [String] { perInstrument.keys.sorted() }

  /// The aggregate points; convenience for symmetry with `series(for:)`.
  var totalSeries: [Point] { total }

  /// Per-instrument points; empty array when the instrument has no slice.
  func series(for instrument: Instrument) -> [Point] {
    perInstrument[instrument.id] ?? []
  }

  /// Sums the per-instrument series for a set of instrument ids by date —
  /// used when an aggregated asset row (e.g. ETH across chains) is selected.
  /// A date is emitted only if it is present in *every* contributing series
  /// (anchored on the first series, which is correct because a date missing
  /// from the first is by definition not in all). This preserves the "never
  /// display a partial aggregate" rule. `value` and `cost` sum; `contributions`
  /// is left `nil` (per-instrument series carry none).
  func series(forInstrumentIds ids: [String]) -> [Point] {
    let seriesList = ids.compactMap { perInstrument[$0] }
    guard let firstSeries = seriesList.first else { return [] }
    if seriesList.count == 1 { return firstSeries }

    let byDate: [[Date: Point]] = seriesList.map { series in
      Dictionary(series.map { ($0.date, $0) }, uniquingKeysWith: { first, _ in first })
    }
    return firstSeries.compactMap { anchor -> Point? in
      var value = Decimal(0)
      var cost = Decimal(0)
      for table in byDate {
        guard let matched = table[anchor.date] else { return nil }  // partial coverage → drop
        value += matched.value
        cost += matched.cost
      }
      return Point(date: anchor.date, value: value, cost: cost, contributions: nil)
    }
  }
}
