import Foundation

/// The universal scaling factor for storage: all quantities are stored as Int64 × 10^8.
private let storageScale: Decimal = 100_000_000

struct InstrumentAmount: Codable, Sendable, Hashable, Comparable {
  let quantity: Decimal
  let instrument: Instrument

  static func zero(instrument: Instrument) -> InstrumentAmount {
    InstrumentAmount(quantity: 0, instrument: instrument)
  }

  var decimalValue: Decimal { quantity }
  var doubleValue: Double { Double(truncating: quantity as NSDecimalNumber) }

  var isPositive: Bool { quantity > 0 }
  var isNegative: Bool { quantity < 0 }
  var isZero: Bool { quantity == 0 }

  // MARK: - Formatting

  var formatted: String {
    switch instrument.kind {
    case .fiatCurrency:
      return quantity.formatted(.currency(code: instrument.id))
    case .stock, .cryptoToken:
      let number = quantity.formatted(.number.precision(.fractionLength(0...instrument.decimals)))
      return "\(number) \(instrument.displayLabel)"
    }
  }

  /// A deliberately imprecise rendering for "ballpark" figures (e.g. a month-end
  /// forecast): rounds the magnitude to ~3 significant figures and drops the
  /// fractional currency unit, so a wide-confidence projection reads as
  /// "$225,000", not "$225,460.22". Sign is preserved (never abs()-ed).
  /// Non-fiat instruments fall back to `formatted`.
  var formattedApproximate: String {
    guard case .fiatCurrency = instrument.kind else { return formatted }
    let rounded = Self.roundedToSignificantFigures(quantity, figures: 3)
    return rounded.formatted(.currency(code: instrument.id).precision(.fractionLength(0)))
  }

  var formatNoSymbol: String {
    quantity.formatted(.number.precision(.fractionLength(instrument.decimals)))
  }

  /// Quantity-only formatting matching the variable-precision rule used
  /// by `formatted` for stocks and crypto (no trailing zeros). Used by
  /// the spam-token row indicator where the symbol is replaced by a
  /// SwiftUI `Text` segment instead of being concatenated into the
  /// number string.
  var formatNoSymbolVariablePrecision: String {
    quantity.formatted(.number.precision(.fractionLength(0...instrument.decimals)))
  }

  /// VoiceOver-safe rendering for this amount. When `isSpam` is true,
  /// substitutes `"<magnitude> spam token"` so the SF Symbol
  /// `exclamationmark.triangle.fill` used in the row's spam display is
  /// never announced as punctuation by VoiceOver. When false, returns
  /// `formatted` unchanged.
  func accessibilityString(isSpam: Bool) -> String {
    if isSpam {
      return "\(formatNoSymbolVariablePrecision) spam token"
    }
    return formatted
  }

  // MARK: - Rounding helpers

  /// Rounds `value` to `figures` significant figures using NSDecimalRound.
  /// Zero is returned unchanged. Preserves sign.
  private static func roundedToSignificantFigures(_ value: Decimal, figures: Int) -> Decimal {
    guard value != 0 else { return 0 }
    let magnitude = abs((value as NSDecimalNumber).doubleValue)
    let exponent = Int(floor(log10(magnitude))) - (figures - 1)
    var result = Decimal()
    var input = value
    NSDecimalRound(&result, &input, -exponent, .plain)
    return result
  }

  // MARK: - Storage (Int64 scaled by 10^8)

  var storageValue: Int64 {
    var scaled = quantity * storageScale
    // `NSDecimalNumber.int64Value` (what `Int64(truncating:)` calls)
    // wraps mod 2^64 for a non-integer Decimal whose significand exceeds
    // 64 bits, flipping the sign. Round to an integer Decimal first; the
    // conversion is then exact. RoundingMode: `.down` = toward -∞,
    // `.up` = toward +∞ — so this truncates toward zero (positive →
    // floor, negative → ceiling; zero is already integral).
    var rounded = Decimal()
    NSDecimalRound(&rounded, &scaled, 0, scaled < 0 ? .up : .down)
    return Int64(truncating: rounded as NSDecimalNumber)
  }

  init(quantity: Decimal, instrument: Instrument) {
    self.quantity = quantity
    self.instrument = instrument
  }

  init(storageValue: Int64, instrument: Instrument) {
    self.quantity = Decimal(storageValue) / storageScale
    self.instrument = instrument
  }

  // MARK: - Arithmetic

  static func + (lhs: InstrumentAmount, rhs: InstrumentAmount) -> InstrumentAmount {
    precondition(
      lhs.instrument == rhs.instrument,
      "Cannot add amounts with different instruments: \(lhs.instrument.id) + \(rhs.instrument.id)"
    )
    return InstrumentAmount(quantity: lhs.quantity + rhs.quantity, instrument: lhs.instrument)
  }

  static func - (lhs: InstrumentAmount, rhs: InstrumentAmount) -> InstrumentAmount {
    precondition(
      lhs.instrument == rhs.instrument,
      "Cannot subtract amounts with different instruments: \(lhs.instrument.id) - \(rhs.instrument.id)"
    )
    return InstrumentAmount(quantity: lhs.quantity - rhs.quantity, instrument: lhs.instrument)
  }

  static prefix func - (amount: InstrumentAmount) -> InstrumentAmount {
    InstrumentAmount(quantity: -amount.quantity, instrument: amount.instrument)
  }

  static func += (lhs: inout InstrumentAmount, rhs: InstrumentAmount) {
    lhs = lhs + rhs
  }

  static func -= (lhs: inout InstrumentAmount, rhs: InstrumentAmount) {
    lhs = lhs - rhs
  }

  static func < (lhs: InstrumentAmount, rhs: InstrumentAmount) -> Bool {
    lhs.quantity < rhs.quantity
  }

  // MARK: - Parsing

  static func parseQuantity(from text: String, decimals: Int) -> Decimal? {
    let cleaned = text.replacingOccurrences(of: "[^0-9.\\-]", with: "", options: .regularExpression)
    guard !cleaned.isEmpty,
      cleaned.filter({ $0 == "." }).count <= 1,
      // Allow at most one minus sign, and only at the start
      cleaned.filter({ $0 == "-" }).count <= 1,
      !cleaned.dropFirst().contains("-"),
      let decimal = Decimal(string: cleaned)
    else { return nil }
    return decimal
  }
}
