// Features/Accounts/Views/AllTransactionsView.swift
//
// Thin wrapper around `TransactionListView` for the All Transactions
// sidebar selection. See `guides/UI_GUIDE.md` §3 for the per-leaf-view
// pattern this implements.

import SwiftUI

/// Detail view for the All Transactions sidebar selection. The sidebar opens
/// it with an empty filter; observation drill-downs can preset the evidence
/// filter used to compute their result.
struct AllTransactionsView: View {
  let filter: TransactionFilter
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  var body: some View {
    TransactionListView(
      title: "All Transactions",
      filter: TransactionFilter(),
      initialFilter: filter,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore
    )
    .id(filter)
  }
}

#Preview("All Transactions") {
  let backend = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  NavigationStack {
    AllTransactionsView(
      filter: TransactionFilter(),
      accounts: Accounts(from: []),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: store)
  }
  .previewProfileEnvironment()
}

#Preview("Observation Filter") {
  let backend = PreviewBackend.create()
  let store = TransactionStore(
    repository: backend.transactions,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let fees = Category(name: "Fees")
  NavigationStack {
    AllTransactionsView(
      filter: TransactionFilter(
        scheduled: .nonScheduledOnly,
        dateRange: Date().addingTimeInterval(-31_536_000)...Date(),
        categoryIds: [fees.id]),
      accounts: Accounts(from: []),
      categories: Categories(from: [fees]),
      earmarks: Earmarks(from: []),
      transactionStore: store)
  }
  .previewProfileEnvironment()
}
