import SwiftUI

struct UpcomingView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  /// The embedded init of `TransactionListView` is used here so this leaf
  /// can apply `.transactionInspector(showRecurrence: true)` at the leaf
  /// body level — the standard TransactionListView-owned inspector defaults
  /// to `showRecurrence: false`, which would hide the recurrence editor that
  /// users need on scheduled transactions.
  @State private var selectedTransaction: Transaction?
  @State private var pendingPayId: Transaction.ID?

  var body: some View {
    TransactionListView(
      title: "Upcoming",
      filter: TransactionFilter(scheduled: .scheduledOnly),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      grouping: .scheduledStatus(today: Date(), pendingPayId: $pendingPayId),
      selectedTransaction: $selectedTransaction
    )
    .transactionInspector(
      selectedTransaction: $selectedTransaction,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore,
      showRecurrence: true
    )
    .onChange(of: pendingPayId) { _, newId in
      guard let id = newId,
        let match = transactionStore.transactions.first(where: { $0.transaction.id == id })
      else { return }
      Task {
        await payTransaction(match.transaction)
        pendingPayId = nil
      }
    }
    // Routing the menu Pay command through `pendingPayId` keeps the
    // in-progress visual firing regardless of trigger source (toolbar,
    // row swipe, or menu). Published only when a recurring transaction
    // is selected so the menu item disables otherwise.
    .focusedSceneValue(
      \.payTransactionAction,
      selectedTransaction?.recurPeriod != nil
        ? { pendingPayId = selectedTransaction?.id }
        : nil
    )
  }

  private func payTransaction(_ scheduledTransaction: Transaction) async {
    let result = await transactionStore.payScheduledTransaction(scheduledTransaction)
    switch result {
    case .paid(let updated):
      selectedTransaction = updated
    case .deleted:
      selectedTransaction = nil
    case .failed:
      break
    }
  }
}

@MainActor
private func previewSeedTransactions(
  backend: any BackendProvider,
  accountId: UUID,
  categoryId: UUID,
  store: TransactionStore
) async {
  let today = Date()
  let calendar = Calendar.current
  let overdue = calendar.date(byAdding: .day, value: -5, to: today) ?? today
  let upcoming = calendar.date(byAdding: .day, value: 5, to: today) ?? today

  _ = try? await backend.transactions.create(
    Transaction(
      date: overdue,
      payee: "Rent",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: -2000,
          type: .expense,
          categoryId: categoryId)
      ]))
  _ = try? await backend.transactions.create(
    Transaction(
      date: upcoming,
      payee: "Internet",
      recurPeriod: .month,
      recurEvery: 1,
      legs: [
        TransactionLeg(
          accountId: accountId,
          instrument: .AUD,
          quantity: -150,
          type: .expense,
          categoryId: categoryId)
      ]))
  await store.load(filter: TransactionFilter(scheduled: .scheduledOnly))
}

#Preview {
  let accountId = UUID()
  let categoryId = UUID()
  let accounts = Accounts(from: [
    Account(
      id: accountId,
      name: "Checking",
      type: .bank,
      instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 2449.77)])
  ])
  let categories = Categories(from: [
    Category(id: categoryId, name: "Rent", parentId: nil)
  ])
  let backend = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  return NavigationStack {
    UpcomingView(
      accounts: accounts,
      categories: categories,
      earmarks: Earmarks(from: []),
      transactionStore: store)
  }
  .previewProfileEnvironment()
  .task {
    await previewSeedTransactions(
      backend: backend, accountId: accountId, categoryId: categoryId, store: store)
  }
}
