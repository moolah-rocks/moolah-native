import SwiftUI

/// Displays an InstrumentAmount with color coding:
/// green when positive, red when negative, primary when zero.
/// Use `colorOverride` to force a specific color (e.g. `.secondary` for running balances).
///
/// When the amount's instrument is in the env-injected `\.spamInstruments`
/// set, the symbol portion (the trailing ticker for stocks / crypto) is
/// rendered with strikethrough to discourage trusting the claimed name —
/// spam tokens routinely impersonate legitimate tickers (e.g. a fake "USDC"
/// at a different contract address). The magnitude itself is left
/// unchanged so the user can still tell how much arrived. Fiat amounts are
/// never spam-flagged and fall through to the locale-aware currency form.
struct InstrumentAmountView: View {
  let amount: InstrumentAmount
  var font: Font?
  var colorOverride: Color?

  @Environment(\.spamInstruments) private var spamInstruments

  var body: some View {
    text
      .foregroundStyle(effectiveColor)
      .monospacedDigit()
      .font(font)
      .accessibilityValue(amount.accessibilityString(isSpam: isSpamInstrument))
  }

  private var text: Text {
    switch amount.instrument.kind {
    case .fiatCurrency:
      return Text(amount.quantity, format: .currency(code: amount.instrument.id))
    case .stock, .cryptoToken:
      if isSpamInstrument {
        let magnitude = Text(verbatim: amount.formatNoSymbolVariablePrecision)
        let symbol = Text(verbatim: amount.instrument.displayLabel).strikethrough()
        return Text("\(magnitude) \(symbol)")
      }
      return Text(amount.formatted)
    }
  }

  private var isSpamInstrument: Bool {
    spamInstruments.contains(amount.instrument)
  }

  private var effectiveColor: Color {
    colorOverride ?? amount.magnitudeColor
  }
}
