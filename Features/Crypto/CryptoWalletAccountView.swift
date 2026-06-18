// Features/Crypto/CryptoWalletAccountView.swift
import SwiftUI

/// Detail view for a crypto wallet account. Composes the wallet header
/// (full address, chain, last-synced state, Sync now button) above the
/// transaction list as siblings in a `VStack(spacing: 0)`.
///
/// The leaf is its own `NavigationStack` (provided by
/// `ContentView.detail`'s `.id(selection)` wrap), so the wallet header
/// and the transaction list are structurally local to this leaf and
/// cannot race against another leaf's `.toolbar` / `.searchable`
/// registrations.
///
/// The header renders only when `chainId`, the chain config, AND a
/// `cryptoSyncStore` all resolve; otherwise the `@ViewBuilder` returns
/// `EmptyView`. Within this leaf's `NavigationStack` a
/// `VStack(spacing: 0) { EmptyView; TransactionListView }` is safe: the
/// `safeAreaInset+EmptyView+NSHostingView` zero-size collapse fires only
/// when the EmptyView-bearing layout crosses an `NSHostingView` column
/// boundary (the `ResizableVSplit`'s arranged subviews used by
/// `InvestmentAccountView.calculatedFromTrades`). Inside a SwiftUI-
/// owned `NavigationStack` column there is no NSHostingView wrapping
/// at this level, so the bug does not apply.
struct CryptoWalletAccountView: View {
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
      walletHeader
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
        // Drives a re-fire of the per-row valuator when the user marks
        // a token as `.spam` from preferences — issue #790.
        registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
        accountIds: [account.id])
    }
  }

  @ViewBuilder private var walletHeader: some View {
    // The header only renders for a crypto account whose chain is known
    // (and a sync store is available). It derives the chain name from
    // `chainId` via `SyncableAccountPresentation`, so the chain is not
    // passed in.
    if let chainId = account.chainId,
      ChainConfig.config(for: chainId) != nil,
      let cryptoSyncStore = session.cryptoSyncStore
    {
      SyncedAccountHeaderView(
        account: account,
        syncStore: cryptoSyncStore,
        cryptoTokenStore: session.cryptoTokenStore,
        exchangeTokenStore: ExchangeTokenStore(synchronizable: true))
    }
  }
}

// MARK: - Preview

// Minimal preview: the leaf takes a `ProfileSession` as a `let` and
// reaches into `session.cryptoSyncStore` / `session.cryptoTokenStore`
// from `walletHeader`. `ProfileSession.preview()` builds an in-memory
// session whose crypto wiring is `nil`, so `walletHeader` returns
// `EmptyView` and the preview renders `VStack { EmptyView;
// TransactionListView }` — still useful for verifying the leaf's
// structural shape without launching the app.
#Preview {
  let account = Account(
    id: UUID(),
    name: "Preview Wallet",
    type: .crypto,
    // Crypto accounts are denominated in the profile currency, not the
    // chain's native token — match production so the preview exercises
    // the real `multiInstrumentPositionsSplit` branch.
    instrument: .AUD,
    valuationMode: .calculatedFromTrades,
    walletAddress: "0x0000000000000000000000000000000000000000",
    chainId: 1)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  return NavigationStack {
    CryptoWalletAccountView(
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
