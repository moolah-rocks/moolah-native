import Foundation

/// A selected holdings row, shared by the table (sets it) and the chart
/// (reads it to filter). A plain data carrier — carries enough to render the
/// filter chip and to sum the contributing instruments' historical series,
/// without re-deriving from the registry. Construct via
/// `AssetHolding.positionSelection`.
struct PositionSelection: Sendable, Hashable, Identifiable {
  /// The row id — an `assetKey` for a crypto rollup, otherwise an instrument id.
  let id: String
  let kind: Instrument.Kind
  let displayLabel: String
  /// The per-chain instrument ids this selection covers (1+).
  let instrumentIds: [String]
}

/// Bridge from a display row to its selection value (defined here, alongside
/// `PositionSelection`, so `AssetHolding` compiles without depending on it).
extension AssetHolding {
  var positionSelection: PositionSelection {
    PositionSelection(
      id: id,
      kind: kind,
      displayLabel: displayLabel,
      instrumentIds: contributingInstrumentIds)
  }
}
