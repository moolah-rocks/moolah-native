import SwiftUI

// MARK: - Account Detail

extension ContentView {
  @ViewBuilder
  func accountDetail(id: UUID) -> some View {
    if let account = accountStore.accounts.by(id: id) {
      switch account.type {
      case .investment:
        investmentAccountDetailView(for: account)
      case .crypto:
        syncedAccountDetailView(for: account, accountChainId: account.chainId)
      case .exchange:
        syncedAccountDetailView(for: account, accountChainId: nil)
      default:
        AccountDetailView(
          title: account.name,
          transactionFilter: TransactionFilter(accountId: account.id),
          positions: accountStore.positions(for: account.id),
          hostCurrency: account.instrument,
          accountIds: [account.id],
          conversionService: session.backend.conversionService,
          registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
          accountChainId: nil,
          alwaysShowsFullSurface: false,
          syncedHeaderAccount: nil,
          accounts: accountStore.accounts,
          categories: categoryStore.categories,
          earmarks: earmarkStore.earmarks,
          transactionStore: transactionStore)
      }
    }
  }

  /// Builds the correct detail view for a `.investment` account, keyed by
  /// `valuationMode` so a live sync-driven flip forces a full subtree remount
  /// before the alternate leaf mounts — prevents the double-`.searchable`
  /// crash (UI_GUIDE §3 / PR #821 / commit 08a99a2d). Extracted to keep
  /// `accountDetail(id:)`'s body under the `function_body_length` limit.
  @ViewBuilder
  private func investmentAccountDetailView(for account: Account) -> some View {
    if account.valuationMode == .recordedValue {
      InvestmentAccountView(
        account: account,
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        investmentStore: investmentStore,
        transactionStore: transactionStore
      )
      .id(ValuationMode.recordedValue)
    } else {
      AccountDetailView(
        title: account.name,
        transactionFilter: TransactionFilter(accountId: account.id),
        positions: accountStore.positions(for: account.id),
        hostCurrency: account.instrument,
        accountIds: [account.id],
        conversionService: session.backend.conversionService,
        registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
        accountChainId: nil,
        alwaysShowsFullSurface: true,
        syncedHeaderAccount: nil,
        accounts: accountStore.accounts,
        categories: categoryStore.categories,
        earmarks: earmarkStore.earmarks,
        transactionStore: transactionStore
      )
      .id(ValuationMode.calculatedFromTrades)
    }
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
