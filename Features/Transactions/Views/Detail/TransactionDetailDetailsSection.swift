import SwiftUI

/// Simple-mode details section: payee autocomplete, amount + instrument,
/// date. The payee field shares `PayeeAutocompleteState` with the form-
/// level `PayeeAutocompleteOverlay`. The amount field hops focus to the
/// counterpart amount on submit when the draft is a cross-currency
/// transfer, keeping keyboard navigation linear.
struct TransactionDetailDetailsSection: View {
  @Binding var draft: TransactionDraft
  let amountBinding: Binding<String>
  let relevantInstrument: Instrument?
  let isCrossCurrency: Bool
  let suggestionSource: PayeeSuggestionSource
  let editingTransactionId: UUID?
  @Binding var payeeState: PayeeAutocompleteState
  let onAutofill: (String) -> Void
  @FocusState.Binding var focusedField: TransactionDetailFocus?

  /// Bridges `LegDraft.instrument` (`Instrument?`) to the picker's
  /// non-optional binding. Reads fall back to the account-derived
  /// instrument (and finally `.AUD`) so the picker always has something
  /// to display; writes materialise the leg-level override.
  private var relevantInstrumentBinding: Binding<Instrument> {
    Binding(
      get: {
        draft.legDrafts[draft.relevantLegIndex].instrument
          ?? relevantInstrument ?? .AUD
      },
      set: { draft.legDrafts[draft.relevantLegIndex].instrument = $0 }
    )
  }

  var body: some View {
    Section {
      PayeeAutocompleteRow(
        payee: $draft.payee,
        state: $payeeState,
        suggestionSource: suggestionSource,
        editingTransactionId: editingTransactionId,
        onAutofill: onAutofill
      )
      .focused($focusedField, equals: .payee)

      LabeledContent {
        HStack(spacing: 8) {
          AmountField(
            text: amountBinding,
            focus: $focusedField,
            equals: .amount,
            onSubmit: {
              if isCrossCurrency {
                focusedField = .counterpartAmount
              }
            }
          )
          CompactInstrumentPickerButton(selection: relevantInstrumentBinding)
        }
      } label: {
        Text("Amount")
      }

      DatePicker("Date", selection: $draft.date, displayedComponents: .date)
    }
  }
}
