import SwiftUI

@MainActor
private func seedTransactionListPreview(
  backend: any BackendProvider,
  accountId: UUID,
  savingsId: UUID,
  store: TransactionStore
) async {
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date(),
      payee: "Woolworths",
      legs: [
        TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -50.23, type: .expense)
      ]))
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-86400),
      payee: "Employer",
      legs: [
        TransactionLeg(accountId: accountId, instrument: .AUD, quantity: 3500, type: .income)
      ]))
  _ = try? await backend.transactions.create(
    Transaction(
      date: Date().addingTimeInterval(-172800),
      legs: [
        TransactionLeg(accountId: accountId, instrument: .AUD, quantity: -1000, type: .transfer),
        TransactionLeg(accountId: savingsId, instrument: .AUD, quantity: 1000, type: .transfer),
      ]))
  await store.load(filter: TransactionFilter(accountId: accountId))
}

private func previewAccounts(checkingId: UUID, savingsId: UUID) -> Accounts {
  Accounts(from: [
    Account(
      id: checkingId,
      name: "Checking",
      type: .bank,
      instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 2449.77)]),
    Account(
      id: savingsId,
      name: "Savings",
      type: .bank,
      instrument: .AUD,
      positions: [Position(instrument: .AUD, quantity: 5000)]),
  ])
}

#Preview {
  let accountId = UUID()
  let savingsId = UUID()
  let accounts = previewAccounts(checkingId: accountId, savingsId: savingsId)
  let backend = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  return NavigationStack {
    TransactionListView(
      title: "Checking",
      filter: TransactionFilter(accountId: accountId),
      accounts: accounts,
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: store)
  }
  .previewProfileEnvironment()
  .task {
    await seedTransactionListPreview(
      backend: backend,
      accountId: accountId,
      savingsId: savingsId,
      store: store)
  }
}
