import SwiftUI

extension TransactionListView {
  var exportableTransactionsList: some View {
    transactionsList
      .modifier(
        TransactionListCSVExportAddons(
          context: csvExportContext,
          exportStore: transactionStore.csvExportStore)
      )
  }

  var csvExportContext: TransactionCSVExportContext {
    TransactionCSVExportContext(
      filter: activeFilter,
      searchText: searchText,
      includesSpam: !allowsSpamFiltering || showSpamTransactions,
      spamInstruments: spamInstruments,
      timeZone: .current,
      accounts: accounts,
      categories: categories,
      earmarks: earmarks)
  }
}
