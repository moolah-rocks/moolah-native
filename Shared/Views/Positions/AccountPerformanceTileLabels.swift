import Foundation

/// View-layer helpers that derive presentation strings from
/// `AccountPerformance`. Lives here (not on the domain model)
/// because the `Domain/` layer is strictly isolated from UI copy
/// and localisation-sensitive formatting (CLAUDE.md "Domain
/// Layer"). Tested directly via `@testable import Moolah` so the
/// SwiftUI tile view does not need a snapshot harness.
///
/// Caseless `enum` (CODE_GUIDE.md §5 — pure namespace).
enum AccountPerformanceTileLabels {
  /// Subtitle text for the Current Value tile, or `nil` to hide
  /// the subtitle row. Hidden when no flows exist; renders the
  /// formatted amount invested when populated; renders an em-dash
  /// label when the amount invested is unavailable but flows exist
  /// (Rule 11 — never silently drop a partial sum).
  ///
  /// The "Amount invested —" form (label kept, value as em-dash) is
  /// intentional and **does not** match the Gain tile's bare `—`:
  /// the subtitle has no adjacent label to supply context, so the
  /// prefix is needed for the row to be intelligible in isolation.
  static func investedSubtitleText(_ performance: AccountPerformance) -> String? {
    guard performance.firstFlowDate != nil else { return nil }
    if let amountInvested = performance.amountInvested {
      return "Amount invested \(amountInvested.formatted)"
    }
    return "Amount invested —"
  }

  /// Accessibility label for the Current Value tile. Speaks the
  /// main value and (when flows exist) the amount invested.
  /// `InstrumentAmount.formatted` uses `.currency(code:)` which
  /// Foundation localises into spoken-currency phrasing under
  /// VoiceOver, so no extra formatter is needed.
  static func currentValueAccessibilityLabel(
    _ performance: AccountPerformance
  ) -> String {
    let main: String
    if let value = performance.currentValue {
      main = "Current Value: \(value.formatted)"
    } else {
      main = "Current Value: Unavailable"
    }
    guard performance.firstFlowDate != nil else { return main }
    if let amountInvested = performance.amountInvested {
      return "\(main), Amount invested: \(amountInvested.formatted)"
    }
    return "\(main), Amount invested: Unavailable"
  }
}
