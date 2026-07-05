import SwiftUI

/// The single unified account-detail view for every account type except
/// `.recordedValue` investment accounts (deprecated; they keep
/// `InvestmentAccountView.legacyValuationsLayout`). Composes an optional
/// synced-account header above the shared
/// `TransactionListView(...).multiInstrumentPositionsSplit(...)` container —
/// which itself renders the data-driven `[Transactions | Positions | Chart]`
/// surface (chart + transactions always; positions + performance tiles
/// gated, or forced on for investment via `alwaysShowsFullSurface`).
///
/// Takes the *resolved* split inputs rather than an `Account` or an
/// `AccountViewContext`, so a single-account host and a group host share one
/// code path (the group dispatch supplies plural `accountIds` +
/// `aggregatedGroupPositions`). The synced header is derived from
/// `syncedHeaderAccount` + `ProfileSession`; group / standard / investment
/// hosts pass `syncedHeaderAccount: nil`.
///
/// This view must NOT contain its own `NavigationStack` — the enclosing
/// stack is provided by `ContentView.detail`'s `.id(selection)` wrap.
struct AccountDetailView: View {
  let title: String
  let transactionFilter: TransactionFilter
  let positions: [Position]
  let hostCurrency: Instrument
  let accountIds: [UUID]
  let conversionService: any InstrumentConversionService
  let registrationsVersion: Int
  let accountChainId: Int?
  let alwaysShowsFullSurface: Bool
  /// The account whose synced header rides above the split, when the type
  /// warrants one (`showsSyncedHeader`). `nil` for group / standard /
  /// investment hosts.
  let syncedHeaderAccount: Account?
  let accounts: Accounts
  let categories: Categories
  let earmarks: Earmarks
  let transactionStore: TransactionStore

  @Environment(ProfileSession.self) private var session: ProfileSession?

  var body: some View {
    VStack(spacing: 0) {
      header
      TransactionListView(
        title: title,
        filter: transactionFilter,
        accounts: accounts,
        categories: categories,
        earmarks: earmarks,
        transactionStore: transactionStore
      )
      .multiInstrumentPositionsSplit(
        positions: positions,
        hostCurrency: hostCurrency,
        title: title,
        conversionService: conversionService,
        registrationsVersion: registrationsVersion,
        accountIds: accountIds,
        accountChainId: accountChainId,
        alwaysShowsFullSurface: alwaysShowsFullSurface)
    }
  }

  /// The type-specific synced-account header slot. Renders
  /// `SyncedAccountHeaderView` for a synced account (crypto with a known
  /// chain, or exchange) when a `cryptoSyncStore` is available; otherwise an
  /// empty slot. Derives the chain name from `chainId` internally, so the
  /// chain is not passed in.
  @ViewBuilder private var header: some View {
    if let account = syncedHeaderAccount,
      Self.showsSyncedHeader(for: account),
      let session,
      let syncStore = session.cryptoSyncStore
    {
      SyncedAccountHeaderView(
        account: account,
        syncStore: syncStore,
        cryptoTokenStore: session.cryptoTokenStore,
        exchangeTokenStore: ExchangeTokenStore(synchronizable: true))
    }
  }

  /// Whether `account` warrants a synced-account header. Pure so the routing
  /// rule is unit-testable without instantiating the view. Crypto shows a
  /// header only when its chain resolves to a `ChainConfig`; exchange always
  /// shows one; every other type shows none. `nonisolated` because the method
  /// is pure (no `@MainActor` state) and tests call it from a non-`@MainActor`
  /// context.
  nonisolated static func showsSyncedHeader(for account: Account) -> Bool {
    switch account.type {
    case .crypto:
      guard let chainId = account.chainId else { return false }
      return ChainConfig.config(for: chainId) != nil
    case .exchange:
      return true
    default:
      return false
    }
  }
}

// MARK: - Preview

// Minimal preview: the leaf reaches into `session.cryptoSyncStore` /
// `session.cryptoTokenStore` from `header`. `ProfileSession.preview()` builds
// an in-memory session whose crypto wiring is `nil`, so `header` returns
// `EmptyView` and the preview renders `VStack { EmptyView;
// TransactionListView }` — still useful for verifying the leaf's structural
// shape without launching the app.
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
    AccountDetailView(
      title: account.name,
      transactionFilter: TransactionFilter(accountId: account.id),
      positions: [],
      hostCurrency: account.instrument,
      accountIds: [account.id],
      conversionService: session.backend.conversionService,
      registrationsVersion: session.cryptoTokenStore?.registrationsVersion ?? 0,
      accountChainId: account.chainId,
      alwaysShowsFullSurface: false,
      syncedHeaderAccount: account,
      accounts: Accounts(from: [account]),
      categories: Categories(from: []),
      earmarks: Earmarks(from: []),
      transactionStore: session.transactionStore)
  }
  .previewProfileEnvironment(session: session)
}
