import SwiftUI

extension RecentlyAddedView {
  /// Module-internal (not `private`) because the type's body in the main
  /// `.swift` file references this directly, and `private` scope is
  /// unavailable across files even within the same type's extensions.
  func sessionList(_ viewModel: RecentlyAddedViewModel) -> some View {
    List {
      ForEach(visibleSessions(viewModel)) { session in
        Section(header: sessionHeader(session)) {
          ForEach(session.transactions, id: \.id) { transaction in
            row(for: transaction, in: viewModel)
          }
        }
      }
    }
  }

  /// One imported-transaction row plus its secondary actions. macOS HIG:
  /// secondary actions live in the context menu; iOS adds the same two
  /// transfer actions as a leading swipe. The pill itself is passive.
  @ViewBuilder
  func row(
    for transaction: Transaction,
    in viewModel: RecentlyAddedViewModel
  ) -> some View {
    let counterpart = viewModel.counterpart(of: transaction)
    let accountName = viewModel.counterpartAccountName(
      of: transaction, accounts: accountStore.accounts)
    let pillTitle = viewModel.pillTitle(counterpartAccountName: accountName)
    RecentlyAddedRow(
      transaction: transaction,
      hasSuggestion: viewModel.hasSuggestion(transaction),
      pillTitle: pillTitle,
      accessibilityLabel: viewModel.rowAccessibilityLabel(
        for: transaction, counterpartAccountName: accountName)
    )
    .accessibilityIdentifier(UITestIdentifiers.RecentlyAdded.row(transaction.id))
    .contextMenu { rowContextMenu(for: transaction, counterpart: counterpart) }
    .modifier(
      TransferSwipeActions(
        counterpart: counterpart,
        onMerge: {
          if let counterpart {
            Task {
              await importStore.mergeTransfer(transaction, counterpart: counterpart)
              await reload()
            }
          }
        },
        onDismiss: {
          if let counterpart {
            transferPendingDismiss = RecentlyAddedTransferPair(
              transaction: transaction, counterpart: counterpart)
          }
        },
        mergeIdentifier: UITestIdentifiers.TransferDetection.merge(transaction.id),
        dismissIdentifier: UITestIdentifiers.TransferDetection.dismiss(transaction.id)
      ))
  }

  /// The row's secondary actions. Open / create-rule / delete are always
  /// present; the two transfer actions appear only when a counterpart is
  /// loaded. iOS mirrors the transfer pair as a leading swipe.
  @ViewBuilder
  func rowContextMenu(
    for transaction: Transaction,
    counterpart: Transaction?
  ) -> some View {
    Button("Open", systemImage: "arrow.up.right.square") {
      transactionForDetail = transaction
    }
    Button("Create rule from this\u{2026}", systemImage: "plus.rectangle.on.folder") {
      createRuleFromTransaction = transaction
    }
    if let counterpart {
      Button("Merge as Transfer", systemImage: "arrow.left.arrow.right") {
        Task {
          await importStore.mergeTransfer(transaction, counterpart: counterpart)
          await reload()
        }
      }
      .accessibilityIdentifier(UITestIdentifiers.TransferDetection.merge(transaction.id))
      Button("Not a Transfer", systemImage: "xmark", role: .destructive) {
        transferPendingDismiss = RecentlyAddedTransferPair(
          transaction: transaction, counterpart: counterpart)
      }
      .accessibilityIdentifier(UITestIdentifiers.TransferDetection.dismiss(transaction.id))
    }
    Button("Delete", systemImage: "trash", role: .destructive) {
      transactionPendingDelete = transaction
    }
  }
}
