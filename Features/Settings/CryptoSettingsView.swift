// Features/Settings/CryptoSettingsView.swift
import SwiftUI

/// Crypto preferences tab. Surfaces every user-facing control for the
/// wallet auto-import: Alchemy API key, CoinGecko API key, the list of
/// registered tokens, and the Discovered Tokens inbox and Spam tokens
/// management views.
///
/// The per-account sync control (last-synced timestamp + "Sync now")
/// lives in the account-detail header (`SyncedAccountHeaderView`), not
/// here — a duplicate Settings list would be a second source of truth.
///
/// `cryptoSyncStore` and `tokenDiscovery` are optional so the view can
/// still render in degraded launches (preview / no `instrumentRegistry`)
/// where the wallet-import feature is unavailable. Sections that depend
/// on them (the Alchemy status badge, the inbox actions) hide themselves
/// when the dependency is missing.
struct CryptoSettingsView: View {
  @Bindable var store: CryptoTokenStore
  let cryptoSyncStore: SyncedAccountStore?
  let tokenDiscovery: CryptoTokenDiscoveryService?

  // Module-internal so the sibling extension file
  // `CryptoSettingsView+TokenList.swift` can read / mutate the same
  // local UI state. Not part of the public surface.
  @State var coinGeckoApiKeyInput = ""
  @State var alchemyApiKeyInput = ""
  @State var showAddToken = false

  init(
    store: CryptoTokenStore,
    cryptoSyncStore: SyncedAccountStore? = nil,
    tokenDiscovery: CryptoTokenDiscoveryService? = nil
  ) {
    self.store = store
    self.cryptoSyncStore = cryptoSyncStore
    self.tokenDiscovery = tokenDiscovery
  }

  var body: some View {
    Form {
      alchemyApiKeySection
      tokenInboxNavigationSection
      tokenListSection
      coinGeckoApiKeySection
    }
    .formStyle(.grouped)
    .navigationTitle("Crypto Tokens")
    .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.container)
    .task { await store.loadRegistrations() }
    .sheet(isPresented: $showAddToken) {
      AddTokenSheet {
        Task { await store.loadRegistrations() }
      }
    }
  }

  // MARK: - Alchemy API Key
  //
  // Status precedence (most-specific wins):
  //
  // 1. `globalError == .invalidApiKey` — key was rejected by Alchemy.
  //    Show "Invalid" with a red exclamation mark.
  // 2. Key configured (`hasAlchemyApiKey == true`) and no global error
  //    — show "Configured" with a green checkmark.
  // 3. No key — show "Not set" with a neutral icon. The footer copy
  //    nudges the user to add one.
  //
  // `globalError == .missingApiKey` is folded into case 3 since the
  // store will set it whenever a sync runs without a key configured.

  @ViewBuilder private var alchemyApiKeySection: some View {
    Section {
      if store.hasAlchemyApiKey {
        configuredAlchemyRow
      } else {
        alchemyEntryRow
      }
      Link(
        "How to get an Alchemy API key",
        destination: alchemySignupURL
      )
      .font(.caption)
    } header: {
      HStack {
        Text("Alchemy")
        Spacer()
        alchemyStatusBadge
      }
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        if let error = store.error {
          Text(error)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
        Text(
          "Required to auto-import on-chain transactions for crypto wallet accounts. "
            + "A free Alchemy key is sufficient for personal use."
        )
      }
    }
  }

  @ViewBuilder private var configuredAlchemyRow: some View {
    HStack {
      Label("Alchemy API Key", systemImage: "key")
      Spacer()
      Text("Configured")
        .foregroundStyle(.secondary)
      Button("Remove", role: .destructive) {
        store.clearAlchemyApiKey()
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.alchemyApiKeyRemoveButton)
    }
  }

  @ViewBuilder private var alchemyEntryRow: some View {
    HStack {
      SecureField("Alchemy API Key", text: $alchemyApiKeyInput)
        .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.alchemyApiKeyField)
      Button("Save") {
        store.saveAlchemyApiKey(alchemyApiKeyInput)
        alchemyApiKeyInput = ""
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(alchemyApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.alchemyApiKeySaveButton)
    }
  }

  /// Coloured status indicator next to the section header. Encodes the
  /// status precedence described in the comment above
  /// `alchemyApiKeySection`. Returned as `some View` rather than three
  /// inline branches so the header layout stays readable.
  @ViewBuilder private var alchemyStatusBadge: some View {
    if cryptoSyncStore?.globalError == .invalidApiKey {
      Label("Invalid", systemImage: "exclamationmark.circle.fill")
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.red)
        .font(.caption)
    } else if store.hasAlchemyApiKey {
      Label("Configured", systemImage: "checkmark.circle.fill")
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.green)
        .font(.caption)
    } else {
      Label("Not set", systemImage: "circle")
        .labelStyle(.titleAndIcon)
        .foregroundStyle(.secondary)
        .font(.caption)
    }
  }

  /// Alchemy's free-tier signup landing page. Hard-coded constant rather
  /// than environment / config because the URL is a public resource and
  /// keeping it inline keeps the link a one-line `Link(...)` call.
  /// `URL(string:)`'s force-unwrap is gated by a known-good literal so a
  /// `nil` here is a programmer error, not a runtime failure mode.
  private var alchemySignupURL: URL {
    guard let url = URL(string: "https://www.alchemy.com/pricing") else {
      preconditionFailure("CryptoSettingsView: malformed Alchemy signup URL literal")
    }
    return url
  }

  // MARK: - Token inbox navigation

  @ViewBuilder private var tokenInboxNavigationSection: some View {
    Section {
      discoveredTokensNavigationLink
      spamTokensNavigationLink
    } header: {
      Text("Token Management")
    }
  }

  @ViewBuilder private var discoveredTokensNavigationLink: some View {
    NavigationLink {
      DiscoveredTokensInboxView(store: store, tokenDiscovery: tokenDiscovery)
    } label: {
      HStack {
        Label("Discovered Tokens", systemImage: "tray")
        Spacer()
        if store.unpricedCount > 0 {
          Text("\(store.unpricedCount)")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.tint, in: Capsule())
            .foregroundStyle(.white)
        }
      }
    }
    .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.discoveredTokensRow)
  }

  @ViewBuilder private var spamTokensNavigationLink: some View {
    NavigationLink {
      SpamTokensView(store: store)
    } label: {
      HStack {
        Label("Spam Tokens", systemImage: "trash")
        Spacer()
        if !store.spamRegistrations.isEmpty {
          Text("\(store.spamRegistrations.count)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
    }
    .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.spamTokensRow)
  }

  // The "Registered Tokens" + "CoinGecko API Key" sections live in
  // `CryptoSettingsView+TokenList.swift`.
}

#Preview("No keys") {
  // Preview-only wiring: an in-memory registry + a no-network price
  // service exercises the empty "no keys configured" state. The store's
  // keychain reads return `nil` on the preview host, so every provider
  // renders its entry-field row. `PreviewBackend.create(sharedRegistry:)`
  // supplies a conversion service wired over the same in-memory
  // profile-index DB the registry owns.
  // In-memory open cannot fail (no filesystem path); preview-only path.
  // swiftlint:disable:next force_try
  let database = try! ProfileIndexDatabase.openInMemory()
  let registry = GRDBInstrumentRegistryRepository(database: database)
  let backend = PreviewBackend.create(sharedRegistry: registry)
  let priceService = CryptoPriceService(clients: [], database: registry.database)
  let store = CryptoTokenStore(
    registry: registry,
    cryptoPriceService: priceService,
    conversionService: backend.conversionService)
  return NavigationStack {
    CryptoSettingsView(store: store)
  }
}
