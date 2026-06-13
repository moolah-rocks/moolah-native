import Foundation

extension ValuedPosition {
  /// Human-friendly quantity string per instrument kind. Used by both
  /// `PositionRow` (narrow layout) and `PositionsTable` (wide layout).
  ///
  /// - `.fiatCurrency` → currency-formatted (e.g. "$1,520.00").
  /// - `.stock` → decimal with up to `instrument.decimals` places, no suffix.
  /// - `.cryptoToken` → decimal (capped at 8 places) + display label
  ///   (e.g. "2.45 ETH").
  ///
  /// Note: the wide layout omits "shares" suffix on stock because the
  /// column header is already labelled "Qty"; the narrow layout adds
  /// "shares" because the secondary line has no other context. Callers
  /// pick one — see `quantityCaption` for the suffix-bearing variant.
  var quantityFormatted: String {
    QuantityFormatting.formatted(
      kind: instrument.kind,
      quantity: quantity,
      decimals: instrument.decimals,
      displayLabel: instrument.displayLabel,
      currencyCode: instrument.kind == .fiatCurrency ? instrument.id : nil)
  }

  /// Caption-style quantity suitable for the secondary line of a row in the
  /// narrow `PositionsTable` layout. Adds "shares" suffix for stocks; same
  /// as `quantityFormatted` otherwise.
  var quantityCaption: String {
    QuantityFormatting.caption(
      kind: instrument.kind,
      quantity: quantity,
      decimals: instrument.decimals,
      displayLabel: instrument.displayLabel,
      currencyCode: instrument.kind == .fiatCurrency ? instrument.id : nil)
  }
}

extension InstrumentAmount {
  /// Signed-amount string with explicit `+` prefix for positive values
  /// and a Unicode minus (U+2212) prefix for negative values. Zero shows
  /// no prefix. Used for gain/loss display so the sign character lines
  /// up with `GainLossPercentDisplay.formatted` under
  /// `.monospacedDigit()` — the locale-native `formatted` produces an
  /// ASCII hyphen-minus (U+002D) which renders narrower than digits and
  /// disagrees with the percent text alongside it. See issue #608.
  ///
  /// Locales whose negative-currency form does not start with a leading
  /// hyphen-minus (e.g. accounting paren-wrap `($500)`) are passed
  /// through untouched — substitution only fires when the first
  /// character of `formatted` is U+002D.
  var signedFormatted: String {
    let raw = formatted
    if quantity > 0 { return "+\(raw)" }
    if quantity < 0, raw.first == "-" {
      return "\u{2212}" + raw.dropFirst()
    }
    return raw
  }
}

/// Display helpers for the cost-basis gain/loss percentage on a
/// `ValuedPosition`. Centralised so `PositionsTable.gainCell`,
/// `PositionRow.trailingColumn`, `AccountPerformanceTiles`, and
/// `PositionsHeader.plPill` produce byte-identical strings without
/// duplicating the formatting logic.
///
/// Uses `Decimal.formatted(.number...)` so the decimal separator
/// follows the user's locale (e.g. `+12,3%` in de_DE, `+12.3%` in
/// en_US) — matching the rest of the app's number formatting.
enum GainLossPercentDisplay {
  /// `+12.3%` / `−4.0%` / `0.0%` (en_US) or `+12,3%` / `−4,0%` /
  /// `0,0%` (de_DE / fr_FR / etc). Standard one-decimal-place P/L
  /// convention. Negative values use a Unicode minus (U+2212) for
  /// typographic consistency with the surrounding monospacedDigit
  /// text.
  ///
  /// - Parameter locale: Defaults to `Locale.current`; tests pass
  ///   a fixed locale to assert the separator behaviour.
  static func formatted(_ pct: Decimal, locale: Locale = .current) -> String {
    let body = formatBody(pct, locale: locale)
    if pct > 0 { return "+\(body)%" }
    if pct < 0 { return "−\(body)%" }
    return "\(body)%"
  }

  /// `", up 12.3 percent"` / `", down 5.0 percent"` / `", 0.0 percent"`.
  /// Empty string when `pct` is nil. Direction-neutral for the zero
  /// case — VoiceOver should not read "up 0.0 percent". Per
  /// `guides/UI_GUIDE.md` every gain/loss tile renders an explicit
  /// accessibility suffix so VoiceOver doesn't read "+12%" as
  /// ambiguous.
  ///
  /// - Parameter locale: Defaults to `Locale.current`; tests pass
  ///   a fixed locale to assert the separator behaviour.
  static func accessibilitySuffix(_ pct: Decimal?, locale: Locale = .current) -> String {
    guard let pct else { return "" }
    if pct == 0 { return ", 0.0 percent" }
    let body = formatBody(pct, locale: locale)
    return pct < 0 ? ", down \(body) percent" : ", up \(body) percent"
  }

  /// One-decimal-place absolute value with the locale's decimal
  /// separator, e.g. `12.3` (en_US) / `12,3` (de_DE). No sign, no
  /// percent symbol, no thousands grouping.
  private static func formatBody(_ pct: Decimal, locale: Locale) -> String {
    let absValue = pct < 0 ? -pct : pct
    return absValue.formatted(
      .number
        .precision(.fractionLength(1))
        .grouping(.never)
        .locale(locale)
    )
  }
}

// MARK: - Sortable accessors

extension ValuedPosition {
  /// Non-optional `Decimal` view of `unitPrice` for sortable Table columns.
  /// Missing values sort as zero — paired with the `—` placeholder rendered
  /// in the cell, this groups failed/unknown rows together at one end.
  var unitPriceQuantity: Decimal { unitPrice?.quantity ?? 0 }

  /// Non-optional `Decimal` view of `costBasis` for sortable Table columns.
  /// Missing values sort as zero (see `unitPriceQuantity`).
  var costBasisQuantity: Decimal { costBasis?.quantity ?? 0 }

  /// Non-optional `Decimal` view of `value` for sortable Table columns.
  /// Missing values sort as zero (see `unitPriceQuantity`).
  var valueQuantity: Decimal { value?.quantity ?? 0 }

  /// Non-optional `Decimal` view of `gainLoss` for sortable Table columns.
  /// Missing values sort as zero (see `unitPriceQuantity`).
  var gainQuantity: Decimal { gainLoss?.quantity ?? 0 }
}
