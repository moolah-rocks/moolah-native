import SwiftUI

// MARK: - Account Detail

extension ContentView {
  @ViewBuilder
  func accountDetail(id: UUID) -> some View {
    if let account = accountStore.accounts.by(id: id) {
      switch account.type {
      case .investment:
        InvestmentAccountView(
          account: account,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          investmentStore: investmentStore,
          transactionStore: transactionStore)
      case .crypto:
        AccountDetailView(
          title: account.name,
          transactionFilter: TransactionFilter(accountId: account.id),
          positions: accountStore.positions(for: account.id),
          hostCurrency: account.instrument,
          accountIds: [account.id],
          conversionService: session.backend.conversionService,
          registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
          accountChainId: account.chainId,
          alwaysShowsFullSurface: false,
          syncedHeaderAccount: account,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
      case .exchange:
        ExchangeAccountView(
          account: account,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore,
          positions: accountStore.positions(for: account.id),
          conversionService: session.backend.conversionService,
          session: session)
      default:
        StandardAccountView(
          account: account,
          positions: accountStore.positions(for: account.id),
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore,
          conversionService: session.backend.conversionService)
      }
    }
  }
}
