import Foundation

extension AssetHolding {
  /// The chart-filter selection value for this row — carries the contributing
  /// per-chain instrument ids so the chart can sum their historical series.
  var positionSelection: PositionSelection {
    PositionSelection(
      id: id,
      kind: kind,
      displayLabel: displayLabel,
      instrumentIds: contributingInstrumentIds)
  }
}
