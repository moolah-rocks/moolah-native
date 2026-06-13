import Foundation

/// A selected holdings row, shared by the table (sets it) and the chart
/// (reads it to filter). A plain data carrier — carries enough to render the
/// filter chip and to sum the contributing instruments' historical series,
/// without re-deriving from the registry. Construct via
/// `AssetHolding.positionSelection`.
struct PositionSelection: Sendable, Hashable, Identifiable {
  /// The row id — an `assetKey` for a crypto rollup, otherwise an instrument id.
  let id: String
  /// The instrument kind of the selected row; drives the filter-chip badge.
  let kind: Instrument.Kind
  /// Short label shown in the filter chip (e.g. "ETH").
  let displayLabel: String
  /// The per-chain instrument ids this selection covers (1+).
  let instrumentIds: [String]
}
