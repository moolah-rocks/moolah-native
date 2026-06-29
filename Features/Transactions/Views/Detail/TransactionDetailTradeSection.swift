import SwiftUI

// Sign-handling note:
// At the draft-model layer `TransactionDraft.displaysNegated(.trade) ==
// false`, so the stored leg `amountText` matches the leg's signed quantity
// 1:1. Trade reversals legitimately have unconventional signs, so the
// model preserves whatever the user enters — see CLAUDE.md "Monetary Sign
// Convention" and `feedback_no_abs_on_trade_legs.md` (no abs, no sign-by-
// position).
//
// The Paid field is the one exception, applied here in the *view layer*:
// users expect "I paid $10" to decrease their balance, so the Paid binding
// flips the sign for display via
// `TransactionDraft.flipTradePaidDisplaySign(_:)`. Storage still reflects
// the underlying signed leg quantity (a normal buy stores `-300`); the
// flip is bidirectional, so a refund booked against the Paid leg is
// entered as a negative number in the field, which the view-side flip
// turns into a positive stored quantity. The Received field is unaffected:
// positive entry, positive stored quantity.

/// Trade-mode primary section. Mirrors the structure of
/// `TransactionDetailDetailsSection` + `TransactionDetailAccountSection` for
/// transfers, but with a single shared account picker and dual amount
/// rows. See design §3.2.
struct TransactionDetailTradeSection: View {
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  var body: some View {
    Section("Trade") {
      accountPicker
      paidRow
      receivedRow
      if let rateText = derivedRateText {
        Text(rateText)
          .font(.caption)
          .foregroundStyle(.secondary)
          .monospacedDigit()
          .accessibilityLabel(rateText)
      }
    }
  }

  private var accountBinding: Binding<UUID?> {
    Binding(
      get: { draft.legDrafts.first?.accountId },
      set: { newId in
        for index in draft.legDrafts.indices {
          draft.legDrafts[index].accountId = newId
          if let id = newId, let account = accounts.by(id: id),
            draft.legDrafts[index].type == .expense
          {
            // Default new fee instruments to the account's currency.
            draft.legDrafts[index].instrument =
              draft.legDrafts[index].instrument ?? account.instrument
          }
        }
      }
    )
  }

  private var accountPicker: some View {
    Picker("Account", selection: accountBinding) {
      Text("None").tag(UUID?.none)
      AccountPickerOptions(
        accounts: accounts,
        exclude: nil,
        currentSelection: accountBinding.wrappedValue
      )
    }
    .accessibilityIdentifier(UITestIdentifiers.Detail.tradeAccount)
    #if os(macOS)
      .pickerStyle(.menu)
    #endif
  }

  private var paidRow: some View {
    legAmountRow(.paid)
  }

  private var receivedRow: some View {
    legAmountRow(.received)
  }

  private func defaultInstrument(forLegAt idx: Int) -> Instrument {
    draft.legDrafts[idx].resolvedInstrument(accounts: accounts)
  }

  @ViewBuilder
  private func legAmountRow(_ side: TradeLegSide) -> some View {
    if let idx = side.legIndex(in: draft) {
      let amountBinding = Binding(
        get: {
          let stored = draft.legDrafts[idx].amountText
          return side.negateForDisplay
            ? TransactionDraft.flipTradePaidDisplaySign(stored) : stored
        },
        set: { newValue in
          draft.legDrafts[idx].amountText =
            side.negateForDisplay
            ? TransactionDraft.flipTradePaidDisplaySign(newValue) : newValue
        })
      let instrumentBinding = Binding<Instrument>(
        get: { draft.legDrafts[idx].instrument ?? defaultInstrument(forLegAt: idx) },
        set: { draft.legDrafts[idx].instrument = $0 })

      LabeledContent {
        HStack(spacing: 8) {
          AmountField(
            text: amountBinding,
            focus: $focusedField,
            equals: side.focus,
            titleKey: side.label,
            accessibilityIdentifier: side.identifier
          )
          CompactInstrumentPickerButton(selection: instrumentBinding)
            .accessibilityIdentifier(side.instrumentIdentifier)
        }
      } label: {
        Text(side.label)
      }
    }
  }

  /// Derived rate caption: `≈ 1 {received} = X.XX {paid}`. Hidden when
  /// either side is unparseable or zero.
  private var derivedRateText: String? {
    guard let paidIdx = draft.paidLegIndex,
      let receivedIdx = draft.receivedLegIndex
    else { return nil }
    let paid = draft.legDrafts[paidIdx]
    let received = draft.legDrafts[receivedIdx]
    let paidInst = paid.instrument ?? defaultInstrument(forLegAt: paidIdx)
    let receivedInst = received.instrument ?? defaultInstrument(forLegAt: receivedIdx)
    guard
      let paidQty = InstrumentAmount.parseQuantity(
        from: paid.amountText, decimals: paidInst.decimals),
      let receivedQty = InstrumentAmount.parseQuantity(
        from: received.amountText, decimals: receivedInst.decimals),
      paidQty != 0, receivedQty != 0
    else { return nil }
    // `abs()` here applies to the derived display ratio only; stored leg
    // quantities keep their signs untouched per the project sign convention.
    // The Paid quantity is normally negative for a buy (and positive for a
    // refund-shaped reversal), so the magnitude must be used either way to
    // produce a positive exchange-rate caption.
    let rate = abs(paidQty / receivedQty)
    let rateFormatted = rate.formatted(
      .number.precision(.significantDigits(2...4)).grouping(.never))
    return "≈ 1 \(receivedInst.shortCode) = \(rateFormatted) \(paidInst.shortCode)"
  }
}

// MARK: - TradeLegSide

/// Identifies which leg of a trade a row is rendering, bundling the per-side
/// configuration (label, focus identity, accessibility ids, leg-index lookup,
/// and the display-sign convention) that
/// `TransactionDetailTradeSection.legAmountRow(_:)` consumes. File-private so
/// the section's call sites stay readable (`legAmountRow(.paid)`) without
/// nesting the enum inside the `View` (which would trigger SwiftLint's
/// `nesting` rule for types declared one level deep in another type).
private enum TradeLegSide {
  case paid, received

  var label: LocalizedStringKey {
    switch self {
    case .paid: "Paid"
    case .received: "Received"
    }
  }

  var focus: TransactionDetailFocus {
    switch self {
    case .paid: .tradePaidAmount
    case .received: .tradeReceivedAmount
    }
  }

  var identifier: String {
    switch self {
    case .paid: UITestIdentifiers.Detail.tradePaidAmount
    case .received: UITestIdentifiers.Detail.tradeReceivedAmount
    }
  }

  var instrumentIdentifier: String {
    switch self {
    case .paid: UITestIdentifiers.Detail.tradePaidInstrument
    case .received: UITestIdentifiers.Detail.tradeReceivedInstrument
    }
  }

  /// `true` when the field should display the user's natural-sign value
  /// while storage keeps the leg's signed quantity. Only the Paid leg
  /// negates; see the file-header sign-handling note.
  var negateForDisplay: Bool {
    switch self {
    case .paid: true
    case .received: false
    }
  }

  func legIndex(in draft: TransactionDraft) -> Int? {
    switch self {
    case .paid: draft.paidLegIndex
    case .received: draft.receivedLegIndex
    }
  }
}
