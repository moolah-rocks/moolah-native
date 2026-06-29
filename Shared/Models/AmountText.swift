import Foundation

/// Pure string helpers for the amount-entry field's display text.
enum AmountText {

  /// Toggles the sign of an amount field's display text for the iOS `±`
  /// keyboard-toolbar button: strips a single leading `-` if present,
  /// otherwise prepends one.
  ///
  /// This is a *user-initiated* toggle, distinct from
  /// `TransactionDraft.flipTradePaidDisplaySign(_:)`, which is a *render*
  /// bijection that intentionally leaves `"0"`, `"-0"`, and `""` unchanged so
  /// no phantom minus appears while a value is rendered. Tapping `±`, by
  /// contrast, always flips — including turning `"0"` into `"-0"` and `""`
  /// into `"-"` — so the user can set the sign before typing any digits. The
  /// downstream parser (`InstrumentAmount.parseQuantity(from:decimals:)`)
  /// treats `"-0"` and a lone `"-"` harmlessly.
  static func toggledSign(_ text: String) -> String {
    if text.hasPrefix("-") {
      return String(text.dropFirst())
    }
    return "-" + text
  }
}
