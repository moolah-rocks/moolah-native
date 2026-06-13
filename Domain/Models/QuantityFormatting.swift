import Foundation

/// Single source of truth for the human-friendly quantity string shown in the
/// holdings surface, shared by `ValuedPosition` and `AssetHolding` so the
/// formatting rules live in exactly one place.
enum QuantityFormatting {
  /// - `.fiatCurrency` → currency-formatted using `currencyCode`.
  /// - `.stock` → decimal up to `decimals` places, no suffix.
  /// - `.cryptoToken` → decimal (capped at 8 places) + `displayLabel`.
  static func formatted(
    kind: Instrument.Kind,
    quantity: Decimal,
    decimals: Int,
    displayLabel: String,
    currencyCode: String?
  ) -> String {
    switch kind {
    case .fiatCurrency:
      // Fiat rows are always single-instrument; `currencyCode` is its ISO code.
      guard let currencyCode else { return "\(quantity)" }
      return InstrumentAmount(
        quantity: quantity,
        instrument: .fiat(code: currencyCode)
      ).formatted
    case .stock:
      return decimalString(quantity, maxFraction: decimals)
    case .cryptoToken:
      return "\(decimalString(quantity, maxFraction: min(decimals, 8))) \(displayLabel)"
    }
  }

  /// Caption-style variant for a row's secondary line: adds "shares" for
  /// stock, identical otherwise. The wide table omits the suffix because the
  /// "Qty" column header already supplies the context; the narrow layout's
  /// secondary line has none, so it needs the explicit "shares" word.
  static func caption(
    kind: Instrument.Kind,
    quantity: Decimal,
    decimals: Int,
    displayLabel: String,
    currencyCode: String?
  ) -> String {
    let base = formatted(
      kind: kind,
      quantity: quantity,
      decimals: decimals,
      displayLabel: displayLabel,
      currencyCode: currencyCode)
    return kind == .stock ? "\(base) shares" : base
  }

  private static func decimalString(_ value: Decimal, maxFraction: Int) -> String {
    value.formatted(.number.precision(.fractionLength(0...maxFraction)))
  }
}
