// Features/Settings/CryptoSettingsView+TokenList.swift
import SwiftUI

/// "Registered Tokens" + "CoinGecko" API-key sections of the Crypto
/// preferences tab. Every member here closes over the parent view's
/// `store` / `showAddToken` / `coinGeckoApiKeyInput` bindings — no new
/// state owned at this layer.
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
    } else if store.pricedRegistrations.isEmpty {
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
              Array(store.pricedRegistrations.enumerated()), id: \.element.id
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
        ForEach(store.pricedRegistrations) { registration in
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
      Link(
        "How to get a CoinGecko API key",
        destination: coinGeckoSignupURL
      )
      .font(.caption)
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
    if store.hasCoinGeckoApiKey {
      HStack {
        Label("CoinGecko API Key", systemImage: "key")
        Spacer()
        Text("Configured")
          .foregroundStyle(.secondary)
        Button("Remove", role: .destructive) {
          store.clearCoinGeckoApiKey()
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.coinGeckoApiKeyRemoveButton)
      }
    } else {
      HStack {
        SecureField("CoinGecko API Key", text: $coinGeckoApiKeyInput)
          .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.coinGeckoApiKeyField)
        Button("Save") {
          store.saveCoinGeckoApiKey(coinGeckoApiKeyInput)
          coinGeckoApiKeyInput = ""
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .disabled(coinGeckoApiKeyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.coinGeckoApiKeySaveButton)
      }
    }
  }

  /// CoinGecko API landing page. Hard-coded constant rather than
  /// environment / config because the URL is a public resource and keeping
  /// it inline keeps the link a one-line `Link(...)` call. `URL(string:)`'s
  /// force-unwrap is gated by a known-good literal so a `nil` here is a
  /// programmer error, not a runtime failure mode.
  private var coinGeckoSignupURL: URL {
    guard let url = URL(string: "https://www.coingecko.com/en/api") else {
      preconditionFailure("CryptoSettingsView: malformed CoinGecko signup URL literal")
    }
    return url
  }
}
