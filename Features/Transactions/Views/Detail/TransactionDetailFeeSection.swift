import SwiftUI

/// One fee section in the trade-mode editor. Renders amount + instrument,
/// category, earmark, and a destructive Remove button.
struct TransactionDetailFeeSection: View {
  let legIndex: Int
  let displayNumber: Int
  @Binding var draft: TransactionDraft
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  @Binding var categoryState: CategoryAutocompleteState
  @FocusState.Binding var focusedField: TransactionDetailFocus?
  let onRequestRemove: () -> Void

  @FocusState private var categoryFieldFocused: Bool

  /// True when `legIndex` still refers to an `.expense` leg in `legDrafts`.
  /// SwiftUI re-evaluates this view's body once after `removeFee(at:)` has
  /// shrunk `legDrafts` but before the surrounding `ForEach` finishes
  /// removing the row, so a naive subscript would trap.
  private var isLive: Bool {
    draft.legDrafts.indices.contains(legIndex)
      && draft.legDrafts[legIndex].type == .expense
  }

  private var visibleSuggestions: [CategorySuggestion] {
    guard isLive else { return [] }
    return categoryState.visibleSuggestions(
      for: draft.legDrafts[legIndex].categoryText, in: categories)
  }

  var body: some View {
    if isLive {
      Section("Fee \(displayNumber)") {
        amountRow
        categoryField
        earmarkPicker
        Button(role: .destructive, action: onRequestRemove) {
          Text("Remove Fee").frame(maxWidth: .infinity)
        }
        .accessibilityIdentifier(UITestIdentifiers.Detail.tradeFeeRemove(displayNumber - 1))
      }
    }
  }

  private var amountRow: some View {
    let amountBinding = Binding(
      get: { draft.legDrafts[legIndex].amountText },
      set: { draft.legDrafts[legIndex].amountText = $0 })
    let instrumentBinding = Binding<Instrument>(
      get: {
        draft.legDrafts[legIndex].instrument
          ?? draft.legDrafts[legIndex].resolvedInstrument(
            accounts: accounts, earmarks: earmarks)
      },
      set: { draft.legDrafts[legIndex].instrument = $0 })

    return LabeledContent {
      HStack(spacing: 8) {
        AmountField(
          text: amountBinding,
          focus: $focusedField,
          equals: .tradeFeeAmount(legIndex),
          accessibilityLabel: "Amount for fee \(displayNumber)",
          accessibilityIdentifier: UITestIdentifiers.Detail.tradeFeeAmount(displayNumber - 1)
        )
        CompactInstrumentPickerButton(selection: instrumentBinding)
      }
    } label: {
      Text("Amount")
    }
  }

  // Mirrors `TransactionDetailLegRow`'s leg-category field — same dropdown,
  // same overlay anchor key, same blur/Enter handlers.
  @ViewBuilder private var categoryField: some View {
    LegCategoryAutocompleteField(
      legIndex: legIndex,
      text: Binding(
        get: { draft.legDrafts[legIndex].categoryText },
        set: { draft.legDrafts[legIndex].categoryText = $0 }),
      highlightedIndex: $categoryState.highlightedIndex,
      suggestionCount: visibleSuggestions.count,
      onTextChange: { _ in openDropdownIfFocused() },
      onAcceptHighlighted: acceptHighlighted,
      onCancel: { categoryState.cancel() }
    )
    .focused($categoryFieldFocused)
    .accessibilityIdentifier(UITestIdentifiers.Detail.legCategory(legIndex))
    .onChange(of: categoryFieldFocused) { _, focused in
      if !focused { handleBlur() }
    }
  }

  private func openDropdownIfFocused() {
    guard categoryFieldFocused else { return }
    if categoryState.justSelected {
      categoryState.justSelected = false
    } else {
      categoryState.showSuggestions = true
    }
  }

  private func handleBlur() {
    let highlighted = categoryState.highlightedSuggestion(
      for: draft.legDrafts[legIndex].categoryText, in: categories)
    categoryState.dismiss()
    draft.commitHighlightedLegCategoryOrNormalise(
      at: legIndex, highlighted: highlighted, using: categories)
  }

  private func acceptHighlighted() {
    guard let highlighted = categoryState.highlightedIndex,
      highlighted < visibleSuggestions.count
    else { return }
    let selected = visibleSuggestions[highlighted]
    categoryState.dismiss()
    draft.commitLegCategorySelection(at: legIndex, id: selected.id, path: selected.path)
  }

  private var earmarkPicker: some View {
    Picker(
      "Earmark",
      selection: Binding(
        get: { draft.legDrafts[legIndex].earmarkId },
        set: { draft.legDrafts[legIndex].earmarkId = $0 })
    ) {
      Text("None").tag(UUID?.none)
      ForEach(earmarks.ordered.filter { !$0.isHidden }) { earmark in
        Text(earmark.name).tag(UUID?.some(earmark.id))
      }
    }
    #if os(macOS)
      .pickerStyle(.menu)
    #endif
  }
}
