import Foundation

/// The fixed "who / where / how" inputs to `MultiInstrumentPositionsAssembler
/// .assemble(context:valuedRows:transactions:range:now:)`. Grouping them lets the
/// call site stay below SwiftLint's five-parameter limit while keeping
/// every field named and documented.
struct PositionsAssemblyContext: Sendable {
  /// Display label passed through to `PositionsViewInput.title`.
  let title: String
  /// The host (reporting) currency for all monetary outputs.
  let hostCurrency: Instrument
  /// The account UUIDs whose legs drive cost-basis classification and
  /// history-builder netting.
  let accountIds: Set<UUID>
  /// Maps instrument id → canonical asset key for cross-chain rollup.
  /// Empty (the default) means no rollup — each position stands alone.
  let assetKeysByInstrumentId: [String: String]
  /// Account-level performance numbers, if available. Non-nil triggers the
  /// three-tile performance strip in the positions pane.
  let performance: AccountPerformance?
  /// `true` for investment-account hosts, where the full surface renders
  /// even with no open positions. Other callers pass `false` (the default).
  let alwaysShowsFullSurface: Bool

  /// Custom init retained so callers can omit optional fields via default
  /// arguments — the synthesised memberwise init cannot supply defaults.
  init(
    title: String,
    hostCurrency: Instrument,
    accountIds: Set<UUID>,
    assetKeysByInstrumentId: [String: String] = [:],
    performance: AccountPerformance? = nil,
    alwaysShowsFullSurface: Bool = false
  ) {
    self.title = title
    self.hostCurrency = hostCurrency
    self.accountIds = accountIds
    self.assetKeysByInstrumentId = assetKeysByInstrumentId
    self.performance = performance
    self.alwaysShowsFullSurface = alwaysShowsFullSurface
  }
}
