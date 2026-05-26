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
        CryptoWalletAccountView(
          account: account,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore,
          positions: accountStore.positions(for: account.id),
          conversionService: session.backend.conversionService,
          session: session)
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
