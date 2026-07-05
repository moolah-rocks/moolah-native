import Testing

@testable import Moolah

/// Build/compile guard for the exchange routing: an `.exchange` account
/// composes the unified `AccountDetailView` with the shared synced-account
/// header. `ContentView.accountDetail(id:)`'s switch is private and SwiftUI
/// views aren't unit-testable, so this pins the construction + the header
/// routing rule; end-to-end routing is covered by
/// `AccountDetailUnifiedLayoutTests` (Task 7).
@Suite("Exchange account routing — AccountDetailView")
@MainActor
struct ExchangeAccountViewRoutingTests {
  @Test
  func exchangeAccountRoutesToUnifiedViewWithHeader() throws {
    let account = Account(
      name: "Coinstash", type: .exchange,
      instrument: .AUD, valuationMode: .calculatedFromTrades,
      exchangeProvider: .coinstash)
    #expect(AccountDetailView.showsSyncedHeader(for: account))
    let session = try ProfileSession.preview()
    _ = AccountDetailView(
      title: account.name,
      transactionFilter: TransactionFilter(accountId: account.id),
      positions: [],
      hostCurrency: account.instrument,
      accountIds: [account.id],
      conversionService: session.backend.conversionService,
      registrationsVersion: 0,
      accountChainId: nil,
      alwaysShowsFullSurface: false,
      syncedHeaderAccount: account,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: session.transactionStore)
  }
}
