// Features/Settings/CryptoSettingsView+RPCEndpoints.swift
import SwiftUI

/// "Custom RPC Endpoints" section of the Crypto preferences tab — an
/// advanced, opt-in escape hatch that lets a user route on-chain calls
/// through their own JSON-RPC node instead of Alchemy or a public node.
/// Every member here closes over the parent view's `store` /
/// `rpcEndpointInput` bindings — no new state owned at this layer.
extension CryptoSettingsView {

  @ViewBuilder var rpcEndpointsSection: some View {
    Section {
      ForEach(store.rpcEndpoints, id: \.self) { url in
        rpcEndpointRow(url)
      }
      addRPCEndpointRow
    } header: {
      Text("Custom RPC Endpoints")
    } footer: {
      VStack(alignment: .leading, spacing: 6) {
        if let error = store.error {
          Text(error)
            .foregroundStyle(.red)
            .textSelection(.enabled)
        }
        Text(
          "Advanced. Route on-chain calls for wallets on a matching chain through your own "
            + "JSON-RPC node instead of Alchemy or a public node. Changes here update the status "
            + "below immediately; wallet sync picks up an edited list the next time sync runs."
        )
      }
    }
    .task { await store.probeEndpoints() }
  }

  /// Two-line row layout (URL + status on top, destructive action on its
  /// own trailing line) mirroring `SpamTokensView`/`DiscoveredTokensInboxView`
  /// so the "Remove" button and status badge don't crowd the URL at large
  /// Dynamic Type sizes.
  @ViewBuilder
  func rpcEndpointRow(_ url: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Text(url)
          .lineLimit(1)
          .truncationMode(.middle)
        Spacer()
        rpcEndpointStatusBadge(for: url)
      }
      HStack {
        Spacer()
        Button("Remove", role: .destructive) {
          Task { await store.removeRPCEndpointAndProbe(url) }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.rpcEndpointRemoveButton(url))
      }
    }
    .padding(.vertical, 4)
    .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.rpcEndpointRow(url))
  }

  @ViewBuilder var addRPCEndpointRow: some View {
    HStack {
      TextField(
        "Endpoint URL", text: $rpcEndpointInput, prompt: Text("https://your-node.example.com")
      )
      #if os(iOS)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled(true)
      #endif
      .accessibilityLabel("Endpoint URL")
      .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.rpcEndpointField)
      Button("Add") {
        let url = rpcEndpointInput
        rpcEndpointInput = ""
        Task { await store.addRPCEndpointAndProbe(url) }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .disabled(rpcEndpointInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.rpcEndpointAddButton)
    }
  }

  /// Coloured status indicator for one endpoint row, mirroring
  /// `alchemyStatusBadge`'s `Label(text, systemImage:)` + colour shape.
  /// The precedence itself is computed off-view by `RPCEndpointStatus`;
  /// this just maps each case to presentation.
  @ViewBuilder
  func rpcEndpointStatusBadge(for url: String) -> some View {
    let status = RPCEndpointStatus(probe: store.rpcProbes.first { $0.url == url })
    Group {
      switch status {
      case .notYetProbed:
        Label("Not probed", systemImage: "circle")
          .foregroundStyle(.secondary)
      case .unreachable:
        Label("Unreachable", systemImage: "xmark.circle.fill")
          .foregroundStyle(.red)
      case .reachable(let chainName):
        Label(chainName, systemImage: "checkmark.circle.fill")
          .foregroundStyle(.green)
      case .reachableUnknownChain(let chainId):
        Label("Unknown chain (id \(chainId))", systemImage: "questionmark.circle.fill")
          .foregroundStyle(.orange)
      }
    }
    .labelStyle(.titleAndIcon)
    .font(.caption)
    .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.rpcEndpointStatusLabel(url))
  }
}

/// Preview-only override matching each seeded URL in
/// `previewRPCEndpointsStore()` to the badge state it should demonstrate:
/// reachable+known chain, reachable+unknown chain, unreachable, and (via
/// `nil`, no matching `Probe`) not-yet-probed.
private func previewRPCEndpointProbe(for url: String) -> RPCEndpointResolver.Probe? {
  switch url {
  case "https://not-yet-probed.example.com":
    return nil
  case "https://unreachable.example.com":
    return RPCEndpointResolver.Probe(url: url, reachable: false, chainId: nil)
  case "https://exotic-chain.example.com":
    return RPCEndpointResolver.Probe(url: url, reachable: true, chainId: 999_999)
  default:
    return RPCEndpointResolver.Probe(url: url, reachable: true, chainId: 1)
  }
}

/// Builds a `CryptoTokenStore` seeded with one endpoint per badge state,
/// wired to `previewRPCEndpointProbe(for:)` instead of a live resolver.
@MainActor
private func previewRPCEndpointsStore() -> CryptoTokenStore {
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
  store.addRPCEndpoint("https://eth.example.com")
  store.addRPCEndpoint(
    "https://a-very-long-custom-node-hostname.example.com/v1/rpc/overflowing-path-segment")
  store.addRPCEndpoint("https://exotic-chain.example.com")
  store.addRPCEndpoint("https://unreachable.example.com")
  store.addRPCEndpoint("https://not-yet-probed.example.com")
  store.rpcProbeOverride = { endpoints in
    endpoints.compactMap(previewRPCEndpointProbe(for:))
  }
  return store
}

#Preview("RPC endpoint states") {
  // Preview-only wiring: an in-memory registry + a no-network price
  // service, with `rpcProbeOverride` set so every badge state renders
  // without a live JSON-RPC round trip.
  NavigationStack {
    CryptoSettingsView(store: previewRPCEndpointsStore())
  }
}
