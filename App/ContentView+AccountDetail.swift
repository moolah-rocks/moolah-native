import SwiftUI

// MARK: - Account Detail

extension ContentView {
  @ViewBuilder
  func accountDetail(id: UUID) -> some View {
    if let account = accountStore.accounts.by(id: id) {
      switch account.type {
      case .investment:
        accountDetailView(for: account, alwaysShowsFullSurface: true)
      case .crypto:
        syncedAccountDetailView(for: account, accountChainId: account.chainId)
      case .exchange:
        syncedAccountDetailView(for: account, accountChainId: nil)
      default:
        accountDetailView(for: account, alwaysShowsFullSurface: false)
      }
    }
  }

  private func accountDetailView(
    for account: Account,
    alwaysShowsFullSurface: Bool
  ) -> some View {
    AccountDetailView(
      title: account.name,
      transactionFilter: TransactionFilter(accountId: account.id),
      positions: accountStore.positions(for: account.id),
      hostCurrency: account.instrument,
      accountIds: [account.id],
      conversionService: session.backend.conversionService,
      registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
      accountChainId: nil,
      alwaysShowsFullSurface: alwaysShowsFullSurface,
      syncedHeaderAccount: nil,
      accounts: accountStore.accounts,
      categories: categoryStore.categories,
      earmarks: earmarkStore.earmarks,
      transactionStore: transactionStore)
  }

  /// Builds an `AccountDetailView` for a synced account (`.crypto` or
  /// `.exchange`). Extracted to keep `accountDetail(id:)`'s body under the
  /// 50-line function_body_length limit.
  private func syncedAccountDetailView(
    for account: Account,
    accountChainId: Int?
  ) -> some View {
    AccountDetailView(
      title: account.name,
      transactionFilter: TransactionFilter(accountId: account.id),
      positions: accountStore.positions(for: account.id),
      hostCurrency: account.instrument,
      accountIds: [account.id],
      conversionService: session.backend.conversionService,
      registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
      accountChainId: accountChainId,
      alwaysShowsFullSurface: false,
      syncedHeaderAccount: account,
      accounts: accountStore.accounts,
      categories: categoryStore.categories,
      earmarks: earmarkStore.earmarks,
      transactionStore: transactionStore)
  }
}
