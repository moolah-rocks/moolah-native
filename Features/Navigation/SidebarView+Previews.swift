// SidebarView previews. Both previews reference internal SidebarView
// APIs and seed an in-memory PreviewBackend; nothing here is referenced
// from production code.

import SwiftUI

/// Builds an in-memory `SyncCoordinator` for `#Preview` use. `SidebarView`
/// composes `SyncProgressFooter`, which reads
/// `@Environment(SyncCoordinator.self)`; without the injection SwiftUI
/// traps inside `EnvironmentBox.update` during initial layout.
@MainActor
private func previewSyncCoordinator() -> SyncCoordinator {
  // swiftlint:disable:next force_try
  let manager = try! ProfileContainerManager.forTesting()
  return SyncCoordinator(containerManager: manager)
}

/// Builds an `AccountStore` against `backend` configured for previews.
@MainActor
private func previewAccountStore(_ backend: CloudKitBackend) -> AccountStore {
  AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
}

/// Builds an `EarmarkStore` against `backend` configured for previews.
@MainActor
private func previewEarmarkStore(_ backend: CloudKitBackend) -> EarmarkStore {
  EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
}

/// Wraps `content` in the eight environment values `SidebarView` and
/// its sub-views read (`AccountStore`, `EarmarkStore`,
/// `AccountGroupStore`, `GroupUIStateStore`, `ProfileSession`,
/// `TransactionStore`, `ImportStore`, `SyncCoordinator`). Extracted so
/// each `#Preview` block fits SwiftLint's 30-line closure budget.
@MainActor
@ViewBuilder
private func sidebarPreviewEnvironment<Content: View>(
  backend: CloudKitBackend,
  session: ProfileSession,
  accountStore: AccountStore,
  accountGroupStore: AccountGroupStore,
  @ViewBuilder content: () -> Content
) -> some View {
  content()
    .environment(accountStore)
    .environment(previewEarmarkStore(backend))
    .environment(accountGroupStore)
    .environment(GroupUIStateStore(repository: backend.groupUIState))
    .environment(session)
    .environment(session.transactionStore)
    .environment(session.importStore)
    .environment(previewSyncCoordinator())
}

@MainActor
private func seedSidebarPreview(backend: any BackendProvider) async {
  // Both `accountStore` and `earmarkStore` are reactive — they load
  // themselves from `init` via `observeAll()`. Seeded rows propagate
  // through the observation streams without an explicit reload here.
  _ = try? await backend.accounts.create(
    Account(name: "Bank", type: .bank, instrument: .AUD),
    openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
  _ = try? await backend.accounts.create(
    Account(name: "Asset", type: .asset, instrument: .AUD),
    openingBalance: InstrumentAmount(quantity: 5000, instrument: .AUD))
  _ = try? await backend.earmarks.create(Earmark(name: "Holiday Fund", instrument: .AUD))
}

#Preview {
  let backend = PreviewBackend.create()
  let accountStore = previewAccountStore(backend)
  let accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()

  return NavigationSplitView {
    sidebarPreviewEnvironment(
      backend: backend,
      session: session,
      accountStore: accountStore,
      accountGroupStore: accountGroupStore
    ) {
      SidebarView(selection: .constant(nil))
        .task { await seedSidebarPreview(backend: backend) }
    }
  } detail: {
    Text("Detail")
  }
}

@MainActor
private func seedSidebarGroupPreview(
  backend: any BackendProvider,
  accountStore: AccountStore,
  accountGroupStore: AccountGroupStore
) async {
  // Seed a standalone bank account (so the Current Accounts section
  // isn't empty in the preview), then two crypto wallets joined into a
  // group. The preview renders the group as a single row with the two
  // members tucked underneath when the user expands it.
  _ = try? await backend.accounts.create(
    Account(name: "Bank", type: .bank, instrument: .AUD),
    openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
  _ = try? await backend.earmarks.create(
    Earmark(name: "Holiday Fund", instrument: .AUD))
  let walletAAccount = Account(
    name: "ETH/OP wallet",
    type: .crypto,
    instrument: .AUD,
    walletAddress: "0x7a3f1b5c9d2e8f4a1b6c3d5e7f9a0b2c4d6e8f0a",
    chainId: 1)
  let walletBAccount = Account(
    name: "Polygon wallet",
    type: .crypto,
    instrument: .AUD,
    walletAddress: "0x7a3f1b5c9d2e8f4a1b6c3d5e7f9a0b2c4d6e8f0a",
    chainId: 137)
  guard
    let walletA = try? await backend.accounts.create(
      walletAAccount,
      openingBalance: InstrumentAmount(quantity: 5210, instrument: .AUD)),
    let walletB = try? await backend.accounts.create(
      walletBAccount,
      openingBalance: InstrumentAmount(quantity: 410, instrument: .AUD))
  else { return }
  _ = try? await accountGroupStore.createGroup(
    joining: walletA,
    and: walletB,
    name: "Trust Fund Crypto",
    accountStore: accountStore
  )
}

#Preview("With a group") {
  let backend = PreviewBackend.create()
  let accountStore = previewAccountStore(backend)
  let accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()

  return NavigationSplitView {
    sidebarPreviewEnvironment(
      backend: backend,
      session: session,
      accountStore: accountStore,
      accountGroupStore: accountGroupStore
    ) {
      SidebarView(selection: .constant(nil))
        .task {
          await seedSidebarGroupPreview(
            backend: backend,
            accountStore: accountStore,
            accountGroupStore: accountGroupStore)
        }
    }
  } detail: {
    Text("Detail")
  }
}

#if os(macOS)
  /// Seeding helper for the macOS outline preview. Mirrors
  /// `seedSidebarGroupPreview` above but adds a standalone bank account
  /// so the preview exercises both the standalone-account and group
  /// rendering paths in `SidebarOutlineView`. Extracted from the inline
  /// `.task { }` closure to satisfy SwiftLint's closure_body_length
  /// rule.
  @MainActor
  private func seedOutlinePreview(
    backend: any BackendProvider,
    accountStore: AccountStore,
    accountGroupStore: AccountGroupStore
  ) async {
    _ = try? await backend.accounts.create(
      Account(name: "Bank", type: .bank, instrument: .AUD),
      openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
    let walletAAccount = Account(
      name: "ETH/OP wallet",
      type: .crypto,
      instrument: .AUD,
      walletAddress: "0x7a3f1b5c9d2e8f4a1b6c3d5e7f9a0b2c4d6e8f0a",
      chainId: 1)
    let walletBAccount = Account(
      name: "Polygon wallet",
      type: .crypto,
      instrument: .AUD,
      walletAddress: "0x7a3f1b5c9d2e8f4a1b6c3d5e7f9a0b2c4d6e8f0a",
      chainId: 137)
    guard
      let walletA = try? await backend.accounts.create(
        walletAAccount,
        openingBalance: InstrumentAmount(quantity: 5210, instrument: .AUD)),
      let walletB = try? await backend.accounts.create(
        walletBAccount,
        openingBalance: InstrumentAmount(quantity: 410, instrument: .AUD))
    else { return }
    _ = try? await accountGroupStore.createGroup(
      joining: walletA,
      and: walletB,
      name: "Trust Fund Crypto",
      accountStore: accountStore
    )
  }

  #Preview("macOS outline — Phase 1 skeleton") {
    // Drives the new `SidebarOutlineView` directly (no NavigationSplitView,
    // no surrounding List): this preview renders the Investments bucket
    // outline in isolation so the cell layout + selection wiring can be
    // eyeballed. The full `SidebarView` preview above exercises both
    // buckets in their natural section context.
    let backend = PreviewBackend.create()
    let accountStore = previewAccountStore(backend)
    let accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
    let groupUIStateStore = GroupUIStateStore(repository: backend.groupUIState)
    return SidebarOutlineView(
      selection: .constant(nil), bucket: .investments, accountToEdit: .constant(nil)
    )
    .environment(accountStore)
    .environment(accountGroupStore)
    .environment(groupUIStateStore)
    .frame(width: 260, height: 480)
    .task {
      await seedOutlinePreview(
        backend: backend,
        accountStore: accountStore,
        accountGroupStore: accountGroupStore)
    }
  }
#endif

#Preview("Empty earmarks") {
  let backend = PreviewBackend.create()
  let accountStore = previewAccountStore(backend)
  let accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()

  return NavigationSplitView {
    sidebarPreviewEnvironment(
      backend: backend,
      session: session,
      accountStore: accountStore,
      accountGroupStore: accountGroupStore
    ) {
      SidebarView(selection: .constant(nil))
        .task {
          // Seed only an account — no earmarks.
          _ = try? await backend.accounts.create(
            Account(name: "Bank", type: .bank, instrument: .AUD),
            openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
        }
    }
  } detail: {
    Text("Detail")
  }
}
