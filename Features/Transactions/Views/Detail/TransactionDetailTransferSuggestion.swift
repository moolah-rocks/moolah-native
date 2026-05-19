import SwiftUI

/// Transfer-suggestion banner in the transaction detail. Shown when a
/// `TransferSuggestion` record touches the transaction (fuzzy detection
/// paired it with a likely counterpart on another account). Mirrors the
/// conditional self-hiding pattern of `TransactionDetailBlockExplorerSection`:
/// renders nothing until the store confirms a suggestion exists. The
/// presence check is resolved by `TransactionStore.hasSuggestion(for:)`
/// (a synced-record read) in a `.task` — the view never touches the
/// repository or a denormalised model field, staying a thin renderer.
///
/// Two sections per UI_GUIDE §6/§14: a banner with the affirmative
/// "Merge as Transfer" action, and a separate trailing section carrying
/// the destructive "Not a Transfer" action. The destructive action only
/// arms a confirmation flag; the `.confirmationDialog` itself lives in
/// `TransactionDetailView`'s body (the house pattern — a section button
/// sets a parent `@State` flag, the dialog is attached once at the body
/// level).
///
/// Coordinator access: the merge / dismiss orchestration lives on
/// `TransactionStore` (`mergeSuggestedTransfer` / `dismissSuggestedTransfer`,
/// which resolve the counterpart and delegate to
/// `TransferDetectionCoordinator`). `TransactionStore` is passed into
/// `TransactionDetailView` and on into this section, so the section
/// stays a thin renderer with one-line `Task { … }` dispatches and no
/// `@Environment(ImportStore.self)` dependency (`ImportStore` is
/// import-flow-scoped and is not in the detail view's environment).
struct TransactionDetailTransferSuggestion: View {
  let transaction: Transaction
  let transactionStore: TransactionStore
  /// Bound to the parent's confirmation flag. The destructive button
  /// flips this; `TransactionDetailView` owns the matching dialog.
  @Binding var showDismissConfirmation: Bool

  /// Resolved from the synced `TransferSuggestion` record via the
  /// store. `false` until the `.task` completes, so the section stays
  /// hidden during the lookup and on every transaction with no
  /// suggestion (the common case).
  @State private var hasSuggestion = false

  var body: some View {
    Group {
      if hasSuggestion {
        suggestionSections
      }
    }
    .task(id: transaction.id) {
      hasSuggestion = await transactionStore.hasSuggestion(for: transaction)
    }
  }

  @ViewBuilder private var suggestionSections: some View {
    Section {
      // Note: if a monetary amount is ever added to this banner, apply
      // .monospacedDigit() (UI_GUIDE §4).
      Label {
        Text("This looks like a transfer to another account.")
          .foregroundStyle(.secondary)
      } icon: {
        Image(systemName: "arrow.left.arrow.right")
          .foregroundStyle(.blue)
      }
      .accessibilityElement(children: .combine)
      .accessibilityLabel(
        "Transfer suggestion: This looks like a transfer to another account."
      )
      .accessibilityIdentifier(
        UITestIdentifiers.TransferDetection.detailBanner(transaction.id))

      Button("Merge as Transfer") {
        Task { await transactionStore.mergeSuggestedTransfer(transaction) }
      }
      .accessibilityIdentifier(
        UITestIdentifiers.TransferDetection.merge(transaction.id))
    }

    Section {
      Button("Not a Transfer", role: .destructive) {
        showDismissConfirmation = true
      }
      .accessibilityIdentifier(
        UITestIdentifiers.TransferDetection.dismiss(transaction.id))
    }
  }
}

/// Preview host: builds a `PreviewBackend`-backed store, optionally
/// seeds a `TransferSuggestion` record over the transaction and a
/// counterpart, then renders the section once seeding completes. The
/// section resolves the banner via `store.hasSuggestion(for:)` — the
/// same synced-record read production uses — so the preview exercises
/// the real path rather than a denormalised model field.
private struct TransferSuggestionPreviewHost: View {
  let transaction: Transaction
  let seedSuggestion: Bool
  @State private var store: TransactionStore?
  @State private var showDismissConfirmation = false

  var body: some View {
    Form {
      if let store {
        TransactionDetailTransferSuggestion(
          transaction: transaction,
          transactionStore: store,
          showDismissConfirmation: $showDismissConfirmation)
      }
    }
    .formStyle(.grouped)
    .task {
      let backend = PreviewBackend.create()
      if seedSuggestion {
        _ = try? await backend.transferSuggestions.create(
          TransferSuggestion(
            transactionIds: [transaction.id, UUID()],
            suggestedAt: Date()))
      }
      store = TransactionStore(
        repository: backend.transactions,
        conversionService: backend.conversionService,
        targetInstrument: .AUD,
        transferSuggestions: backend.transferSuggestions)
    }
  }
}

#Preview {
  TransferSuggestionPreviewHost(
    transaction: Transaction(
      date: Date(),
      payee: "Transfer to Savings",
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .AUD, quantity: -500, type: .expense)
      ]),
    seedSuggestion: true)
}

#Preview("No suggestion (hidden)") {
  TransferSuggestionPreviewHost(
    transaction: Transaction(
      date: Date(),
      payee: "Groceries",
      legs: [
        TransactionLeg(
          accountId: UUID(), instrument: .AUD, quantity: -42, type: .expense)
      ]),
    seedSuggestion: false)
}
