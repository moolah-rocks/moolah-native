// Features/Accounts/Views/AllTransactionsView.swift
//
// Thin wrapper around `TransactionListView` for the All Transactions
// sidebar selection. See `guides/UI_GUIDE.md` §3 for the per-leaf-view
// pattern this implements.

import SwiftUI

/// Detail view for the All Transactions sidebar selection. A bare
/// `TransactionListView` with an empty filter.
struct AllTransactionsView: View {
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  var body: some View {
    TransactionListView(
      title: "All Transactions",
      filter: TransactionFilter(),
      accounts: accounts,
      categories: categories,
      earmarks: earmarks,
      transactionStore: transactionStore)
  }
}
