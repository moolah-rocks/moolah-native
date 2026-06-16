// Features/Settings/CryptoSettingsView+TokenList.swift
import SwiftUI

/// "Registered Tokens" + "CoinGecko" / "CryptoCompare" API-key sections
/// of the Crypto preferences tab. Every member here closes over the
/// parent view's `store` / `showAddToken` / `coinGeckoApiKeyInput` /
/// `cryptoCompareApiKeyInput` bindings — no new state owned at this
/// layer.
extension CryptoSettingsView {

  // MARK: - Registered Tokens

  @ViewBuilder var tokenListSection: some View {
    Section {
      tokenListContent
    } header: {
      tokenListHeader
    }
  }

  @ViewBuilder var tokenListContent: some View {
    if store.isLoading && store.registrations.isEmpty {
      HStack {
        Spacer()
        ProgressView()
        Spacer()
      }
    } else if pricedRegistrations.isEmpty {
      ContentUnavailableView(
        "No Tokens",
        systemImage: "bitcoinsign.circle",
        description: Text("Add crypto tokens to track their prices.")
      )
      .frame(maxWidth: .infinity)
    } else {
      // `showsContractAddress: true` — wallets with copied tickers
      // (issue #790) need the full contract address visible so a
      // legitimate token can be told apart from a spam contract
      // claiming the same symbol.
      #if os(macOS)
        // Cap the section's height so a long token list scrolls within
        // its own pane instead of pushing the CoinGecko / API-key
        // sections off-screen.
        ScrollView {
          LazyVStack(spacing: 0) {
            ForEach(
              Array(pricedRegistrations.enumerated()), id: \.element.id
            ) { index, registration in
              if index > 0 {
                Divider()
              }
              registrationRow(for: registration)
                .padding(.vertical, 4)
            }
          }
        }
        .frame(maxHeight: 280)
      #else
        ForEach(pricedRegistrations) { registration in
          registrationRow(for: registration)
        }
      #endif
    }
  }

  @ViewBuilder var tokenListHeader: some View {
    HStack {
      Text("Registered Tokens")
      Spacer()
      Button {
        showAddToken = true
      } label: {
        Image(systemName: "plus")
      }
      .buttonStyle(.borderless)
      .accessibilityLabel("Add token")
      .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.addTokenButton)
    }
  }

  /// Tokens that are neither `.unpriced` nor `.spam` — i.e. the set the
  /// "Registered Tokens" list shows. Filtering at the view layer keeps
  /// the store's `registrations` a single source of truth that the
  /// inbox + spam views can also read.
  var pricedRegistrations: [CryptoRegistration] {
    store.registrations.filter { $0.pricingStatus == .priced }
  }

  /// One row in the Registered Tokens list, with an inline ellipsis
  /// `Menu` carrying both per-row actions. The earlier `.contextMenu`
  /// + `.swipeActions` + `.onDelete` stack triggered a SwiftUI
  /// `ForEachState` crash on macOS — a single inline `Menu` is the
  /// proven primitive used elsewhere in the app's Form-style preferences.
  ///
  /// "Mark as Spam" calls the same `setStatus(.spam, for:)` plumbing
  /// the Discovered Tokens inbox uses. It exists here so the user can
  /// un-poison registrations the pre-#790 broken resolver wrote as
  /// `.priced` with a spoofed mapping.
  @ViewBuilder
  func registrationRow(for registration: CryptoRegistration) -> some View {
    HStack {
      CryptoRegistrationRow(registration: registration, showsContractAddress: true)
      Menu {
        Button(role: .destructive) {
          Task { await store.setStatus(.spam, for: registration) }
        } label: {
          Label("Mark as Spam", systemImage: "trash")
        }
        .accessibilityIdentifier(
          UITestIdentifiers.CryptoSettings.markSpamButton(registration.id))
        Button(role: .destructive) {
          Task { await store.removeRegistration(registration) }
        } label: {
          Label("Remove", systemImage: "minus.circle")
        }
      } label: {
        Image(systemName: "ellipsis.circle")
          .accessibilityLabel("Token actions")
      }
      .menuStyle(.borderlessButton)
      .fixedSize()
    }
    .accessibilityIdentifier(
      UITestIdentifiers.CryptoSettings.registrationRow(registration.id))
  }

  // MARK: - CoinGecko API Key

  var coinGeckoApiKeySection: some View {
    Section {
      coinGeckoApiKeyControl
    } header: {
      Text("CoinGecko")
    } footer: {
      Text(
        "Optional. Enables CoinGecko as the highest-priority price provider. "
          + "Requires a free Demo API key from coingecko.com."
      )
    }
  }

  @ViewBuilder var coinGeckoApiKeyControl: some View {
    if store.hasApiKey {
      HStack {
        Label("CoinGecko API Key", systemImage: "key")
        Spacer()
        Text("Configured")
          .foregroundStyle(.secondary)
        Button("Remove", role: .destructive) {
          store.clearApiKey()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
      }
    } else {
      HStack {
        SecureField("CoinGecko API Key", text: $coinGeckoApiKeyInput)
        Button("Save") {
          let trimmed = coinGeckoApiKeyInput.trimmingCharacters(in: .whitespaces)
          guard !trimmed.isEmpty else { return }
          store.saveApiKey(trimmed)
          coinGeckoApiKeyInput = ""
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(coinGeckoApiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
      }
    }
  }

  // MARK: - CryptoCompare API Key

  var cryptoCompareApiKeySection: some View {
    Section {
      cryptoCompareApiKeyControl
      Link(
        "How to get a CryptoCompare API key",
        destination: cryptoCompareSignupURL
      )
      .font(.caption)
    } header: {
      Text("CryptoCompare")
    } footer: {
      Text(
        "Optional. Restores deep price history for tokens like DAI. "
          + "Requires a free API key from CoinDesk Data, formerly CryptoCompare."
      )
    }
  }

  @ViewBuilder var cryptoCompareApiKeyControl: some View {
    if store.hasCryptoCompareApiKey {
      HStack {
        Label("CryptoCompare API Key", systemImage: "key")
        Spacer()
        Text("Configured")
          .foregroundStyle(.secondary)
        Button("Remove", role: .destructive) {
          store.clearCryptoCompareApiKey()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.cryptoCompareApiKeyRemoveButton)
      }
    } else {
      HStack {
        SecureField("CryptoCompare API Key", text: $cryptoCompareApiKeyInput)
          .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.cryptoCompareApiKeyField)
        Button("Save") {
          let trimmed = cryptoCompareApiKeyInput.trimmingCharacters(in: .whitespaces)
          guard !trimmed.isEmpty else { return }
          store.saveCryptoCompareApiKey(trimmed)
          cryptoCompareApiKeyInput = ""
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(cryptoCompareApiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
        .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.cryptoCompareApiKeySaveButton)
      }
    }
  }

  /// CoinDesk Data (formerly CryptoCompare) API landing page. Hard-coded
  /// constant rather than environment / config because the URL is a
  /// public resource and keeping it inline keeps the link a one-line
  /// `Link(...)` call. `URL(string:)`'s force-unwrap is gated by a
  /// known-good literal so a `nil` here is a programmer error, not a
  /// runtime failure mode.
  private var cryptoCompareSignupURL: URL {
    guard let url = URL(string: "https://developers.coindesk.com") else {
      preconditionFailure("CryptoSettingsView: malformed CryptoCompare signup URL literal")
    }
    return url
  }
}
