import SwiftUI

/// Detail view for a `.exchange` account. Composes the shared
/// synced-account header (`SyncedAccountHeaderView`) above the same
/// investment-like positions/transactions body the crypto wallet view
/// uses — `TransactionListView` with `.multiInstrumentPositionsSplit`,
/// which is the established trade-valued (`.calculatedFromTrades`) body
/// (exchange accounts are created `.calculatedFromTrades`, same as
/// crypto). The body is reused, not forked.
///
/// This view must NOT contain its own `NavigationStack` — the enclosing
/// `NavigationStack` is provided by `ContentView.detail`'s
/// `.id(selection)` wrap. A nested `NavigationStack` here fires the
/// duplicate-toolbar assertion. (Same contract as
/// `CryptoWalletAccountView`'s doc comment.)
struct ExchangeAccountView: View {
  let account: Account
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore
  let positions: [Position]
  let conversionService: any InstrumentConversionService
  let session: ProfileSession

  var body: some View {
    VStack(spacing: 0) {
      exchangeHeader
      TransactionListView(
        title: account.name,
        filter: TransactionFilter(accountId: account.id),
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore
      )
      .multiInstrumentPositionsSplit(
        positions: positions,
        hostCurrency: account.instrument,
        title: account.name,
        conversionService: conversionService,
        registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
        accountIds: [account.id])
    }
  }

  @ViewBuilder private var exchangeHeader: some View {
    if let syncStore = session.cryptoSyncStore {
      SyncedAccountHeaderView(
        account: account,
        syncStore: syncStore,
        cryptoTokenStore: session.cryptoTokenStore,
        exchangeTokenStore: ExchangeTokenStore(synchronizable: true))
    }
  }
}

// MARK: - Preview

// Mirrors `CryptoWalletAccountView.swift` preview wiring. The preview
// session's crypto wiring is `nil`, so `exchangeHeader` returns
// `EmptyView` and the preview renders `VStack { EmptyView;
// TransactionListView }` — still useful for verifying the leaf's
// structural shape. The runtime `NavigationStack` comes from
// `ContentView.detail`; the wrapper here is preview-only.
#Preview {
  let account = Account(
    name: "Coinstash",
    type: .exchange,
    instrument: .AUD,
    valuationMode: .calculatedFromTrades,
    exchangeProvider: .coinstash)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  return NavigationStack {
    ExchangeAccountView(
      account: account,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: session.transactionStore,
      positions: [],
      conversionService: session.backend.conversionService,
      session: session)
  }
  .previewProfileEnvironment(session: session)
}
