import SwiftUI

// MARK: - Form Content & Section Composition

// The form body and its mode-aware section composition for
// `TransactionDetailView`. Split out of the main view file (which keeps
// the type declaration, `body`, and the confirmation dialogs) along the
// natural seam: this is the section-assembly concern, parallel to the
// `+Actions` / `+Helpers` extensions. `formContent` is module-internal
// (not `private`) so `body` in the main file can compose it across the
// file boundary; the per-mode builders stay `private` to this file.
extension TransactionDetailView {
  var formContent: some View {
    Form {
      modeAwareSections
      // Banner offering to collapse this transaction and its detected
      // counterpart into one merged transfer. Hides itself when the
      // transaction carries no transfer suggestion.
      TransactionDetailTransferSuggestion(
        transaction: transaction,
        transactionStore: transactionStore,
        showDismissConfirmation: $showTransferDismissConfirmation
      )
      // Per-leg block-explorer links for any leg with an externalId
      // (on-chain tx hash). Skipped when no leg qualifies — the section
      // hides itself rather than rendering an empty header.
      TransactionDetailBlockExplorerSection(transaction: transaction, accounts: accounts)
      // Per-leg on-chain counterparty rows for any leg with a non-nil
      // `counterpartyAddress`. Skipped when no leg qualifies. Renders
      // truncated addresses with copy-to-clipboard buttons; deliberately
      // not a clickable link (an arbitrary on-chain address shouldn't
      // look authoritative).
      TransactionDetailCounterpartySection(transaction: transaction)
      if isScheduled {
        TransactionDetailPaySection(
          transaction: transaction,
          transactionStore: transactionStore,
          onUpdate: onUpdate,
          onDelete: onDelete
        )
      }
      unmergeSection
      // "Synced from …" row for a transaction that background sync created.
      // Custom mode marks each leg's header instead (see `customModeContent`),
      // so this footer is limited to the non-custom views. Self-hides when no
      // leg came from background sync.
      if !draft.isCustom {
        TransactionDetailSyncSection(sources: Set(syncedLegSources.values))
      }
      TransactionDetailDeleteSection(onRequestDelete: { showDeleteConfirmation = true })
    }
  }

  /// Leg id → background-sync source for the transaction being edited, keyed
  /// by the original `transaction_leg.id`. Manually-added legs (nil `legId`)
  /// are absent. Derived from the domain transaction so it reflects the true
  /// origin regardless of in-progress edits.
  var syncedLegSources: [UUID: BackgroundSyncSource] {
    transaction.backgroundSyncedLegSources()
  }

  @ViewBuilder private var modeAwareSections: some View {
    if isSimpleEarmarkOnly {
      earmarkOnlyContent
    } else if isTradeMode {
      tradeModeContent
    } else if draft.isCustom {
      customModeContent
    } else {
      simpleModeContent
    }
  }

  @ViewBuilder private var earmarkOnlyContent: some View {
    TransactionDetailEarmarkOnlySection(
      draft: $draft, earmarks: earmarks, amountBinding: amountBinding)
    if showRecurrence {
      TransactionDetailRecurrenceSection(draft: $draft)
    }
    TransactionDetailNotesSection(notes: $draft.notes)
  }

  /// True when the draft is not in custom mode and has at least one `.trade` leg.
  private var isTradeMode: Bool {
    !draft.isCustom && draft.legDrafts.contains { $0.type == .trade }
  }

  @ViewBuilder private var tradeModeContent: some View {
    modeSection.disabled(!isEditable)
    // Payee + date sit at the top alongside the type picker, mirroring the
    // simple income / expense / transfer layout so the form reads
    // consistently across modes.
    TransactionDetailCustomDetailsSection(
      draft: $draft,
      suggestionSource: transactionStore.payeeSuggestionSource,
      editingTransactionId: transaction.id,
      payeeState: $payeeState,
      onAutofill: autofillFromPayee,
      focusedField: $focusedField
    )
    .disabled(!isEditable)

    TransactionDetailTradeSection(
      draft: $draft,
      accounts: accounts,
      focusedField: $focusedField
    )
    .disabled(!isEditable)

    ForEach(Array(draft.feeIndices.enumerated()), id: \.element) { ordinal, legIndex in
      TransactionDetailFeeSection(
        legIndex: legIndex,
        displayNumber: ordinal + 1,
        draft: $draft,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        categoryState: legCategoryStateBinding(for: legIndex),
        focusedField: $focusedField,
        onRequestRemove: { draft.removeFee(at: legIndex) }
      )
    }

    Section {
      Button {
        let defaultInstrument =
          draft.legDrafts.first?.accountId
          .flatMap { accounts.by(id: $0) }?.instrument ?? Instrument.AUD
        draft.appendFee(defaultInstrument: defaultInstrument)
      } label: {
        Label("Add Fee", systemImage: "plus")
          .frame(maxWidth: .infinity)
      }
      .accessibilityIdentifier(UITestIdentifiers.Detail.tradeAddFeeButton)
    }

    if showRecurrence {
      TransactionDetailRecurrenceSection(draft: $draft).disabled(!isEditable)
    }
    TransactionDetailNotesSection(notes: $draft.notes)
  }

  @ViewBuilder private var simpleModeContent: some View {
    modeSection.disabled(!isEditable)
    TransactionDetailDetailsSection(
      draft: $draft,
      amountBinding: amountBinding,
      relevantInstrument: relevantInstrument,
      isCrossCurrency: isCrossCurrency,
      suggestionSource: transactionStore.payeeSuggestionSource,
      editingTransactionId: transaction.id,
      payeeState: $payeeState,
      onAutofill: autofillFromPayee,
      focusedField: $focusedField
    )
    .disabled(!isEditable)
    TransactionDetailAccountSection(
      draft: $draft,
      accounts: accounts,
      relevantInstrument: relevantInstrument,
      counterpartInstrument: counterpartInstrument,
      counterpartAmountBinding: counterpartAmountBinding,
      isCrossCurrency: isCrossCurrency,
      focusedField: $focusedField
    )
    .disabled(!isEditable)
    TransactionDetailCategorySection(
      draft: $draft, categories: categories, earmarks: earmarks, state: $categoryState
    )
    .disabled(!isEditable)
    if showRecurrence {
      TransactionDetailRecurrenceSection(draft: $draft).disabled(!isEditable)
    }
    TransactionDetailNotesSection(notes: $draft.notes)
  }

  @ViewBuilder private var customModeContent: some View {
    modeSection.disabled(!isEditable)
    TransactionDetailCustomDetailsSection(
      draft: $draft,
      suggestionSource: transactionStore.payeeSuggestionSource,
      editingTransactionId: transaction.id,
      payeeState: $payeeState,
      onAutofill: autofillFromPayee,
      focusedField: $focusedField
    )
    ForEach(draft.legDrafts.indices, id: \.self) { index in
      TransactionDetailLegRow(
        index: index,
        totalLegCount: draft.legDrafts.count,
        draft: $draft,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        categoryState: legCategoryStateBinding(for: index),
        focusedField: $focusedField,
        syncSource: draft.legDrafts[index].legId.flatMap { syncedLegSources[$0] },
        onRequestDelete: { legPendingDeletion = index }
      )
    }
    TransactionDetailAddLegSection(draft: $draft, accounts: accounts)
    if showRecurrence {
      TransactionDetailRecurrenceSection(draft: $draft)
    }
    TransactionDetailNotesSection(notes: $draft.notes)
  }

  private var modeSection: some View {
    TransactionDetailModeSection(
      transaction: transaction,
      draft: $draft,
      accounts: accounts,
      focusedField: $focusedField
    )
  }

  private func legCategoryStateBinding(
    for index: Int
  ) -> Binding<CategoryAutocompleteState> {
    Binding(
      get: { legCategoryStates[index] ?? CategoryAutocompleteState() },
      set: { legCategoryStates[index] = $0 }
    )
  }

  /// Re-key the per-leg dropdown state dict after the leg at `removedIndex`
  /// is removed. Without this, an open dropdown on a higher-indexed leg
  /// would re-bind to the *new* leg at that shifted index — e.g.
  /// deleting leg 0 with three legs would leak leg 1's open-dropdown
  /// flag onto the new leg 0.
  func shiftLegCategoryStates(after removedIndex: Int) {
    var shifted: [Int: CategoryAutocompleteState] = [:]
    for (key, state) in legCategoryStates where key != removedIndex {
      shifted[key < removedIndex ? key : key - 1] = state
    }
    legCategoryStates = shifted
  }
}
