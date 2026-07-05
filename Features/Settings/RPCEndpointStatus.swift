// Features/Settings/RPCEndpointStatus.swift
import Foundation

/// Status of one custom RPC endpoint's live probe, derived from the
/// matching `RPCEndpointResolver.Probe` (or its absence). A pure,
/// store-adjacent derivation kept out of `CryptoSettingsView` so it's
/// unit-testable without a SwiftUI harness — the view only maps each case
/// to a `Label` + colour, mirroring `alchemyStatusBadge`'s precedence
/// shape.
enum RPCEndpointStatus: Equatable {
  /// No `Probe` yet for this endpoint — `probeEndpoints()` hasn't
  /// completed since the endpoint was added (or since app launch).
  case notYetProbed

  /// The endpoint did not respond to `eth_chainId` (network failure,
  /// non-2xx response, or an unparseable URL string).
  case unreachable

  /// Reachable, and its `chainId` matches a chain `ChainConfig` knows
  /// about — `chainName` is that chain's `displayName`.
  case reachable(chainName: String)

  /// Reachable, but its `chainId` isn't one of the chains this app
  /// supports (`ChainConfig.config(for:) == nil`). Still worth surfacing
  /// distinctly from `unreachable`: the endpoint works, it's just not
  /// wired to route anything yet.
  case reachableUnknownChain(chainId: Int)

  /// - Parameter probe: The `Probe` matching this endpoint's URL, or
  ///   `nil` if `probeEndpoints()` hasn't produced one yet (e.g. the
  ///   endpoint was just added and the re-probe is still in flight).
  init(probe: RPCEndpointResolver.Probe?) {
    guard let probe else {
      self = .notYetProbed
      return
    }
    // `Probe.reachable == true` always pairs with a non-nil `chainId`
    // (see `RPCEndpointResolver.probe(_:)`); the `guard` below is
    // defensive, not a case this resolver actually produces.
    guard probe.reachable, let chainId = probe.chainId else {
      self = .unreachable
      return
    }
    if let config = ChainConfig.config(for: chainId) {
      self = .reachable(chainName: config.displayName)
    } else {
      self = .reachableUnknownChain(chainId: chainId)
    }
  }
}
