import XCTest

/// Custom RPC Endpoints Settings section: adding an endpoint URL surfaces a
/// row whose status badge resolves to a chain name once probed, and
/// removing it drops the row again.
///
/// Reaches layers a store test cannot exercise on its own: the SwiftUI
/// `Form`/`Section` re-render on `CryptoTokenStore.rpcEndpoints` /
/// `rpcProbes` mutation, the `.task`-driven initial + post-edit
/// `probeEndpoints()` round trip, and the `TextField`/"Add"-button
/// disabled-state wiring. See `guides/UI_TEST_GUIDE.md` §1.
///
/// Uses the `.cryptoCatalogPreloaded` seed (already a network-free
/// Settings → Crypto tab seed) with
/// `UITestSeed.needsStubbedRPCProbe == true`, so `probeEndpoints()`
/// resolves every configured endpoint as reachable on chain 1 (Ethereum)
/// without a live `eth_chainId` JSON-RPC call — see
/// `UITestEnvironment.rpcProbeStubbedReachable`.
@MainActor
final class CryptoSettingsRPCEndpointsTests: MoolahUITestCase {
  private static let endpointURL = "https://custom-node.example.com/v1"

  func testAddingEndpointShowsResolvedStatusThenRemoveHidesRow() {
    let app = launch(seed: .cryptoCatalogPreloaded)

    app.settings.open()
    app.settings.openCryptoTab()
    app.cryptoSettings.addRPCEndpoint(Self.endpointURL)
    app.cryptoSettings.waitForRPCEndpointStatus(url: Self.endpointURL, chainName: "Ethereum")

    app.cryptoSettings.removeRPCEndpoint(Self.endpointURL)
  }
}
