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
      Text(
        "Advanced. Route on-chain calls for wallets on a matching chain through your own "
          + "JSON-RPC node instead of Alchemy or a public node. Changes here update the status "
          + "below immediately; wallet sync picks up an edited list the next time the app "
          + "starts."
      )
    }
    .task { await store.probeEndpoints() }
  }

  @ViewBuilder
  func rpcEndpointRow(_ url: String) -> some View {
    HStack {
      Text(url)
        .lineLimit(1)
        .truncationMode(.middle)
      Spacer()
      rpcEndpointStatusBadge(for: url)
      Button("Remove", role: .destructive) {
        store.removeRPCEndpoint(url)
        Task { await store.probeEndpoints() }
      }
      .buttonStyle(.bordered)
      .controlSize(.small)
      .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.rpcEndpointRemoveButton(url))
    }
    .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.rpcEndpointRow(url))
  }

  @ViewBuilder var addRPCEndpointRow: some View {
    HStack {
      TextField("https://your-node.example.com", text: $rpcEndpointInput)
        .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.rpcEndpointField)
      Button("Add") {
        store.addRPCEndpoint(rpcEndpointInput)
        rpcEndpointInput = ""
        Task { await store.probeEndpoints() }
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
        Label("Unknown chain (\(chainId))", systemImage: "questionmark.circle.fill")
          .foregroundStyle(.orange)
      }
    }
    .labelStyle(.titleAndIcon)
    .font(.caption)
    .accessibilityIdentifier(UITestIdentifiers.CryptoSettings.rpcEndpointStatusLabel(url))
  }
}
