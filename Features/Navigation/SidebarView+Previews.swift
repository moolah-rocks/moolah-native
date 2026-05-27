// SidebarView previews. Both previews reference internal SidebarView
// APIs and seed an in-memory PreviewBackend; nothing here is referenced
// from production code.

import SwiftUI

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
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
  let groupUIStateStore = GroupUIStateStore(repository: backend.groupUIState)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()

  return NavigationSplitView {
    SidebarView(selection: .constant(nil))
      .environment(accountStore)
      .environment(earmarkStore)
      .environment(accountGroupStore)
      .environment(groupUIStateStore)
      .environment(session)
      .task {
        await seedSidebarPreview(backend: backend)
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
  // Seed two crypto wallets, then create a group joining them. The
  // preview renders the group as a single row with the two members
  // tucked underneath when the user expands it.
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
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
  let groupUIStateStore = GroupUIStateStore(repository: backend.groupUIState)
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()

  return NavigationSplitView {
    SidebarView(selection: .constant(nil))
      .environment(accountStore)
      .environment(earmarkStore)
      .environment(accountGroupStore)
      .environment(groupUIStateStore)
      .environment(session)
      .task {
        await seedSidebarGroupPreview(
          backend: backend,
          accountStore: accountStore,
          accountGroupStore: accountGroupStore)
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
    // no surrounding List): Task 4 wires it into the SwiftUI sidebar, this
    // preview just renders the outline in isolation so the cell layout +
    // selection wiring can be eyeballed.
    let backend = PreviewBackend.create()
    let accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: backend.conversionService,
      targetInstrument: .AUD)
    let accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
    let groupUIStateStore = GroupUIStateStore(repository: backend.groupUIState)
    return SidebarOutlineView(selection: .constant(nil), accountToEdit: .constant(nil))
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
  let accountStore = AccountStore(
    repository: backend.accounts,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let earmarkStore = EarmarkStore(
    repository: backend.earmarks,
    conversionService: backend.conversionService,
    targetInstrument: .AUD)
  let accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
  let groupUIStateStore = GroupUIStateStore(repository: backend.groupUIState)
  // In-memory preview session can't fail in practice: opens an ephemeral
  // GRDB queue with no disk access. A trap here is acceptable in #Preview.
  // swiftlint:disable:next force_try
  let session = try! ProfileSession.preview()

  return NavigationSplitView {
    SidebarView(selection: .constant(nil))
      .environment(accountStore)
      .environment(earmarkStore)
      .environment(accountGroupStore)
      .environment(groupUIStateStore)
      .environment(session)
      .task {
        // Seed only an account — no earmarks. Validates that the
        // Earmarks section header (and its iOS "+" button) renders in
        // the empty-state, and that the macOS toolbar shows both the
        // "New Account" and "New Earmark" buttons.
        _ = try? await backend.accounts.create(
          Account(name: "Bank", type: .bank, instrument: .AUD),
          openingBalance: InstrumentAmount(quantity: 1000, instrument: .AUD))
      }
  } detail: {
    Text("Detail")
  }
}
