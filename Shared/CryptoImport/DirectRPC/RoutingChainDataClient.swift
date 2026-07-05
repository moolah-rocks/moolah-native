// Shared/CryptoImport/DirectRPC/RoutingChainDataClient.swift
import Foundation

/// `ChainDataClient` that routes each chain's on-chain calls to whichever
/// concrete client an `RPCEndpointResolver` selects: a matching custom
/// endpoint's direct JSON-RPC client, else Alchemy, else the chain's default
/// public node (also a direct client). Every call first asks the resolver
/// `client(for:)`, then dispatches to a `makeAlchemy()` client for `.alchemy`
/// or a `makeDirect(rpc)` client for `.direct(rpc)`.
///
/// With no custom endpoint configured and an Alchemy key present, every chain
/// resolves to `.alchemy`, so every call routes to a single shared Alchemy
/// client — no behaviour difference from calling that client directly.
///
/// The concrete resolved client is memoized per `chain.chainId` in a small
/// private `actor` (the struct itself stays `Sendable`; the actor is a shared
/// reference). A single sync pass issues one `getAssetTransfers` followed by
/// many `getTransactionReceipt` calls for the same chain; reusing one concrete
/// client across them keeps the direct path's `TokenMetadataResolver` cache
/// warm rather than rebuilding a fresh (empty) metadata cache per receipt.
struct RoutingChainDataClient {
  private let resolver: RPCEndpointResolver
  private let makeAlchemy: @Sendable () -> any ChainDataClient
  private let makeDirect: @Sendable (LiveJSONRPCClient) -> any ChainDataClient
  private let cache = ResolvedClientCache()

  /// - Parameters:
  ///   - resolver: Selects, per chain, whether to route to Alchemy or a
  ///     direct JSON-RPC client (custom endpoint or default public node).
  ///   - makeAlchemy: Builds the client used for a `.alchemy` resolution.
  ///     May return a shared instance — the Alchemy client is stateless.
  ///   - makeDirect: Wraps a resolver-supplied `LiveJSONRPCClient` in the
  ///     direct `ChainDataClient` (with its per-endpoint token-metadata
  ///     resolver) used for a `.direct` resolution.
  init(
    resolver: RPCEndpointResolver,
    makeAlchemy: @escaping @Sendable () -> any ChainDataClient,
    makeDirect: @escaping @Sendable (LiveJSONRPCClient) -> any ChainDataClient
  ) {
    self.resolver = resolver
    self.makeAlchemy = makeAlchemy
    self.makeDirect = makeDirect
  }

  /// Returns the concrete client for `chain`, resolving (and memoizing) it on
  /// first use. On a cache miss the resolver picks `.alchemy` / `.direct`, the
  /// matching factory builds the client, and `storeIfAbsent` records it — that
  /// last step returns any client a concurrent first-resolution for the same
  /// chain already stored, so both callers converge on one instance.
  private func client(for chain: ChainConfig) async -> any ChainDataClient {
    if let cached = await cache.client(forChainId: chain.chainId) {
      return cached
    }
    let resolved = await resolver.client(for: chain)
    let built: any ChainDataClient
    switch resolved {
    case .alchemy:
      built = makeAlchemy()
    case .direct(let rpc):
      built = makeDirect(rpc)
    }
    return await cache.storeIfAbsent(built, forChainId: chain.chainId)
  }
}

// MARK: - ChainDataClient

extension RoutingChainDataClient: ChainDataClient {
  func getAssetTransfers(
    chain: ChainConfig,
    walletAddress: String,
    fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    try await client(for: chain)
      .getAssetTransfers(
        chain: chain, walletAddress: walletAddress, fromBlock: fromBlock)
  }

  func getTransactionReceipt(
    chain: ChainConfig,
    hash: String
  ) async throws -> AlchemyTransactionReceipt {
    try await client(for: chain).getTransactionReceipt(chain: chain, hash: hash)
  }
}

/// Per-`chainId` cache of the concrete client `RoutingChainDataClient`
/// resolved. An `actor` so the `Sendable` struct can share mutable state
/// across concurrent calls; `storeIfAbsent` collapses a race between two
/// first-resolutions of the same chain onto the client that landed first.
private actor ResolvedClientCache {
  private var clients: [Int: any ChainDataClient] = [:]

  func client(forChainId chainId: Int) -> (any ChainDataClient)? {
    clients[chainId]
  }

  func storeIfAbsent(
    _ client: any ChainDataClient, forChainId chainId: Int
  ) -> any ChainDataClient {
    if let existing = clients[chainId] {
      return existing
    }
    clients[chainId] = client
    return client
  }
}
