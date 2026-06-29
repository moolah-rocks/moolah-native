import SwiftUI

/// Counterpart-amount input + derived-rate display shown for cross-currency
/// transfers. The label flips between "Sent" and "Received" so the field
/// always describes the *other* leg from the user's viewing perspective.
///
/// Stored amounts preserve their signs; only the display rate strips signs
/// so the printed ratio is always positive.
struct TransactionDetailCrossCurrencyRow: View {
  @Binding var draft: TransactionDraft
  let relevantInstrument: Instrument?
  let counterpartInstrument: Instrument?
  let counterpartAmountBinding: Binding<String>
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  /// Display + accessibility text for the implied exchange rate. `nil`
  /// when either side is unparseable or zero.
  private var derivedRate: (displayText: String, accessibilityText: String)? {
    guard let relevantInst = relevantInstrument,
      let counterpartInst = counterpartInstrument,
      let primaryQty = InstrumentAmount.parseQuantity(
        from: draft.amountText, decimals: relevantInst.decimals),
      let counterQty = InstrumentAmount.parseQuantity(
        from: draft.counterpartLeg?.amountText ?? "", decimals: counterpartInst.decimals),
      primaryQty != .zero && counterQty != .zero
    else { return nil }
    // abs() used only for display rate computation — stored amounts preserve their signs
    let absPrimary = abs(primaryQty)
    let absCounter = abs(counterQty)
    let rate = absCounter / absPrimary
    let rateFormatted = rate.formatted(
      .number.precision(.significantDigits(2...4)).grouping(.never))
    return (
      displayText: "≈ 1 \(relevantInst.id) = \(rateFormatted) \(counterpartInst.id)",
      accessibilityText:
        "Approximate exchange rate: 1 \(relevantInst.id) equals \(rateFormatted) \(counterpartInst.id)"
    )
  }

  /// Bridges the counterpart leg's `Instrument?` to the picker's
  /// non-optional binding. Reads fall back to the account-derived
  /// counterpart instrument; writes update the leg directly.
  private var counterpartInstrumentBinding: Binding<Instrument> {
    Binding(
      get: {
        if let idx = draft.counterpartLegIndex {
          return draft.legDrafts[idx].instrument
            ?? counterpartInstrument ?? .AUD
        }
        return counterpartInstrument ?? .AUD
      },
      set: { newValue in
        guard let idx = draft.counterpartLegIndex else { return }
        draft.legDrafts[idx].instrument = newValue
      }
    )
  }

  var body: some View {
    let fieldLabel: LocalizedStringKey = draft.showFromAccount ? "Sent" : "Received"
    LabeledContent {
      HStack(spacing: 8) {
        AmountField(
          text: counterpartAmountBinding,
          focus: $focusedField,
          equals: .counterpartAmount,
          titleKey: fieldLabel,
          accessibilityLabel: draft.showFromAccount ? "Sent amount" : "Received amount",
          accessibilityIdentifier: UITestIdentifiers.Detail.counterpartAmount,
          onSubmit: { focusedField = nil }
        )
        CompactInstrumentPickerButton(selection: counterpartInstrumentBinding)
          .accessibilityIdentifier(UITestIdentifiers.Detail.counterpartAmountInstrument)
      }
    } label: {
      Text(fieldLabel)
    }

    if let rate = derivedRate {
      Text(rate.displayText)
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
        .accessibilityLabel(rate.accessibilityText)
    }
  }
}
