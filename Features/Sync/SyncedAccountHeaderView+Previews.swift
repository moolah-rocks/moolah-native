import SwiftUI

// MARK: - Previews
//
// The parent `CryptoWalletAccountView` / `ExchangeAccountView` previews
// render this header as `EmptyView` (their `ProfileSession.preview()`
// leaves crypto wiring `nil`), so this standalone `#Preview` is the only
// canvas path that exercises the layout. The header reads only
// `SyncedAccountStore`'s observable `statePerAccount` /
// `inProgressAccountIds`, so a minimal store over the in-memory preview
// backend (no sync sources) covers the full layout. No checkpoint is
// seeded, so both rows read "Never synced" — sufficient to verify the
// single-line layout (the timestamp string does not affect the row's
// line count). `hasCredential` resolves `false` in canvas (no
// keychain), so the inline-caption slot shows the missing-credential hint
// on the single-line `ViewThatFits` branch or as its own row on the
// stacked branch. A separate `#Preview("...error caption inline")`
// variant seeds a local keychain entry + a sync error so the
// inline-error-caption path has canvas coverage.

#Preview("Synced account header") {
  syncedAccountHeaderPreview()
}

// Accessibility-size variants prove #932's acceptance: the address
// wraps (never truncates) and the status row never clips, from
// `.xSmall` through `.accessibility5`.

#Preview("Synced account header (xSmall)") {
  syncedAccountHeaderPreview()
    .dynamicTypeSize(.xSmall)
}

#Preview("Synced account header (Accessibility5)") {
  syncedAccountHeaderPreview()
    .dynamicTypeSize(.accessibility5)
}

// Narrow iPhone-class width at the largest accessibility size forces
// `statusRow`'s `ViewThatFits` onto its two-row fallback, giving that
// branch canvas coverage (a 720pt column still fits the single line).

#Preview("Synced account header (iPhone, Accessibility5)") {
  syncedAccountHeaderPreview(width: 390)
    .dynamicTypeSize(.accessibility5)
}

// Builds the standalone-preview content. Extracted from the `#Preview`
// closure so the (unavoidably verbose) store wiring is governed by
// `function_body_length` rather than the stricter `closure_body_length`.
@MainActor
private func syncedAccountHeaderPreview(width: CGFloat = 720) -> some View {
  // `ProfileSession.preview()` throws only if the in-memory SwiftData
  // container can't be created — a programmer error; crashing is correct.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  let store = SyncedAccountStore(
    sources: [],
    walletApplyEngine: WalletApplyEngine(
      transactions: session.backend.transactions,
      walletSyncState: session.backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine()),
    walletSyncState: session.backend.walletSyncState,
    accounts: session.backend.accounts,
    transferDetection: TransferDetectionCoordinator(
      transactions: session.backend.transactions,
      suggestions: session.backend.transferSuggestions))
  let exchangeTokenStore = ExchangeTokenStore()
  let cryptoAccount = Account(
    name: "Preview Wallet",
    type: .crypto,
    instrument: .AUD,
    valuationMode: .calculatedFromTrades,
    walletAddress: "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60",
    chainId: 10)
  let exchangeAccount = Account(
    name: "Coinstash",
    type: .exchange,
    instrument: .AUD,
    valuationMode: .calculatedFromTrades,
    exchangeProvider: .coinstash)
  return VStack(spacing: 24) {
    SyncedAccountHeaderView(
      account: cryptoAccount,
      syncStore: store,
      cryptoTokenStore: nil,
      exchangeTokenStore: exchangeTokenStore)
    SyncedAccountHeaderView(
      account: exchangeAccount,
      syncStore: store,
      cryptoTokenStore: nil,
      exchangeTokenStore: exchangeTokenStore)
  }
  .frame(width: width)
  .padding()
}

// Error-caption-inline variant: a crypto wallet with `hasCredential == true`
// (via a local preview-only keychain entry) and a seeded `WalletSyncState`
// carrying a network error, so the inline `errorCaptionView` renders in the
// caption slot rather than the missing-credential hint. This preview gives
// the error-caption path canvas coverage complementing the missing-credential
// hint coverage from `syncedAccountHeaderPreview`.
//
// The keychain write uses a distinct preview-only service name so it does not
// touch the production iCloud-synced keychain. The entry persists across
// preview renders (idempotent re-write) but is never read by shipping code.

#Preview("Synced account header (error caption inline)") {
  syncedAccountHeaderErrorCaptionPreview()
}

@MainActor
private func syncedAccountHeaderErrorCaptionPreview(width: CGFloat = 720) -> some View {
  // `ProfileSession.preview()` throws only if the in-memory container can't
  // be created — a programmer error; crashing is correct.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()
  let store = SyncedAccountStore(
    sources: [],
    walletApplyEngine: WalletApplyEngine(
      transactions: session.backend.transactions,
      walletSyncState: session.backend.walletSyncState,
      importRules: NoOpWalletImportRulesEngine()),
    walletSyncState: session.backend.walletSyncState,
    accounts: session.backend.accounts,
    transferDetection: TransferDetectionCoordinator(
      transactions: session.backend.transactions,
      suggestions: session.backend.transferSuggestions))

  let cryptoAccount = Account(
    name: "Preview Wallet (error)",
    type: .crypto,
    instrument: .AUD,
    valuationMode: .calculatedFromTrades,
    walletAddress: "0xa4b572ea1b6f734fc88a0a004c5301f8dad54d60",
    chainId: 10)

  // Seed a sync error so `SyncedAccountHeaderLogic.errorCaption` is non-nil.
  let syncState = WalletSyncState(
    id: cryptoAccount.id,
    lastSyncedBlockNumber: 0,
    lastSyncedAt: .distantPast,
    lastError: .network(underlyingDescription: "Preview seeded error"))
  store.replaceStatePerAccount([cryptoAccount.id: syncState])

  // Write a dummy Alchemy key to a preview-only local keychain entry so
  // `hasCredential` stays `true` after the view's `.task` fires.
  // `synchronizable: false` + a preview-specific service name ensures this
  // write is device-local and never touches the iCloud-synced production key.
  let previewAlchemyStore = KeychainStore(
    service: "com.moolah.preview.api-keys",
    account: "alchemy",
    synchronizable: false)
  try? previewAlchemyStore.saveString("preview-alchemy-key")

  // Build a `CryptoTokenStore` whose `alchemyKeyStore` reads from the
  // pre-seeded local entry above so `hasAlchemyApiKey` returns `true`.
  // `session.instrumentRegistry` is always non-nil after `ProfileSession.init`
  // (set synchronously in `finishInit`).
  // swiftlint:disable force_unwrapping
  let cryptoTokenStore = CryptoTokenStore(
    registry: session.instrumentRegistry!,
    cryptoPriceService: session.cryptoPriceService,
    conversionService: session.backend.conversionService,
    apiKeyStore: KeychainStore(
      service: "com.moolah.preview.api-keys", account: "coingecko", synchronizable: false),
    alchemyKeyStore: previewAlchemyStore,
    cryptocompareKeyStore: KeychainStore(
      service: "com.moolah.preview.api-keys", account: "cryptocompare", synchronizable: false))
  // swiftlint:enable force_unwrapping

  return SyncedAccountHeaderView(
    account: cryptoAccount,
    syncStore: store,
    cryptoTokenStore: cryptoTokenStore,
    exchangeTokenStore: ExchangeTokenStore()
  )
  .frame(width: width)
  .padding()
}
