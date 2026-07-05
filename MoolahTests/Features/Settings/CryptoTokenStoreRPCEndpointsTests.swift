// MoolahTests/Features/Settings/CryptoTokenStoreRPCEndpointsTests.swift
import Foundation
import GRDB
import Security
import Testing

@testable import Moolah

/// Tests for the `CryptoTokenStore+RPCEndpoints` surface backing the
/// "Custom RPC Endpoints" Settings section: `rpcEndpoints` loading at
/// construction, `addRPCEndpoint`/`removeRPCEndpoint` persistence, and
/// `probeEndpoints()`'s `Probe` → `rpcProbes` plumbing.
///
/// `probeEndpoints()` is exercised entirely through `rpcProbeOverride` —
/// none of these tests touch the network or build a live
/// `RPCEndpointResolver`/`LiveJSONRPCClient`. The `RPCEndpointResolver`
/// probing/routing logic itself is covered by `RPCEndpointResolverTests`;
/// this suite only proves the store wires the override result into
/// `rpcProbes` and that `RPCEndpointStatus` derives the right case from a
/// `Probe`.
///
/// Keychain-backed (via `CryptoRPCEndpointsStore`) — requires code signing,
/// macOS only, mirroring `CryptoRPCEndpointsStoreTests` /
/// `CryptoSettingsAPIKeyTests`.
#if os(macOS)

  /// Deterministic `CryptoRPCEndpointsStoring` double whose `save(_:)`
  /// always fails, so tests can exercise `addRPCEndpoint`/
  /// `removeRPCEndpoint`'s rollback-on-failure path without depending on
  /// a genuine (and CI-flaky) Keychain error.
  private struct FailingRPCEndpointsStore: CryptoRPCEndpointsStoring {
    let seeded: [String]

    func load() -> [String] { seeded }

    func save(_ endpoints: [String]) throws {
      throw KeychainError.saveFailed(errSecParam)
    }
  }

  @Suite("CryptoTokenStore+RPCEndpoints")
  @MainActor
  struct CryptoTokenStoreRPCEndpointsTests {
    private func makeStore(
      seedEndpoints: [String] = [],
      rpcEndpointsStore overrideStore: (any CryptoRPCEndpointsStoring)? = nil
    ) throws -> (store: CryptoTokenStore, keychain: KeychainStore) {
      let keychain = KeychainStore(
        service: "com.moolah.test.rpc-endpoints-store.\(UUID().uuidString)",
        account: "rpc-endpoints",
        synchronizable: false)
      let endpointsStore = CryptoRPCEndpointsStore(store: keychain)
      if !seedEndpoints.isEmpty {
        try endpointsStore.save(seedEndpoints)
      }
      let database = try ProfileIndexDatabase.openInMemory()
      let registry = GRDBInstrumentRegistryRepository(database: database)
      let priceService = CryptoPriceService(clients: [], database: database)
      let store = CryptoTokenStore(
        registry: registry,
        cryptoPriceService: priceService,
        conversionService: FakeConversionService.passthrough,
        apiKeyStore: KeychainStore(
          service: "com.moolah.test.rpc-endpoints-coingecko.\(UUID().uuidString)",
          account: "coingecko", synchronizable: false),
        alchemyKeyStore: KeychainStore(
          service: "com.moolah.test.rpc-endpoints-alchemy.\(UUID().uuidString)",
          account: "alchemy", synchronizable: false),
        rpcEndpointsStore: overrideStore ?? endpointsStore)
      return (store, keychain)
    }

    // MARK: - rpcEndpoints

    @Test("rpcEndpoints loads from the injected store at construction")
    func rpcEndpointsLoadsAtConstruction() throws {
      let (store, keychain) = try makeStore(seedEndpoints: ["https://rpc.example.com"])
      defer { keychain.clear() }
      #expect(store.rpcEndpoints == ["https://rpc.example.com"])
    }

    @Test("rpcEndpoints is empty when the store has never been written")
    func rpcEndpointsEmptyByDefault() throws {
      let (store, keychain) = try makeStore()
      defer { keychain.clear() }
      #expect(store.rpcEndpoints.isEmpty)
    }

    // MARK: - addRPCEndpoint

    @Test("addRPCEndpoint trims, appends, and persists")
    func addRPCEndpointTrimsAppendsAndPersists() throws {
      let (store, keychain) = try makeStore()
      defer { keychain.clear() }
      store.addRPCEndpoint("  https://rpc.example.com  ")
      #expect(store.rpcEndpoints == ["https://rpc.example.com"])
      #expect(CryptoRPCEndpointsStore(store: keychain).load() == ["https://rpc.example.com"])
    }

    @Test("addRPCEndpoint ignores an empty or all-whitespace input")
    func addRPCEndpointIgnoresBlank() throws {
      let (store, keychain) = try makeStore()
      defer { keychain.clear() }
      store.addRPCEndpoint("   ")
      #expect(store.rpcEndpoints.isEmpty)
    }

    @Test("addRPCEndpoint ignores an exact duplicate of an existing entry")
    func addRPCEndpointIgnoresDuplicate() throws {
      let (store, keychain) = try makeStore(seedEndpoints: ["https://rpc.example.com"])
      defer { keychain.clear() }
      store.addRPCEndpoint("https://rpc.example.com")
      #expect(store.rpcEndpoints == ["https://rpc.example.com"])
    }

    @Test("addRPCEndpoint appends a second, distinct endpoint")
    func addRPCEndpointAppendsSecondEndpoint() throws {
      let (store, keychain) = try makeStore(seedEndpoints: ["https://a.example.com"])
      defer { keychain.clear() }
      store.addRPCEndpoint("https://b.example.com")
      #expect(store.rpcEndpoints == ["https://a.example.com", "https://b.example.com"])
    }

    // MARK: - removeRPCEndpoint

    @Test("removeRPCEndpoint removes the matching entry and persists")
    func removeRPCEndpointRemovesAndPersists() throws {
      let (store, keychain) = try makeStore(
        seedEndpoints: ["https://a.example.com", "https://b.example.com"])
      defer { keychain.clear() }
      store.removeRPCEndpoint("https://a.example.com")
      #expect(store.rpcEndpoints == ["https://b.example.com"])
      #expect(CryptoRPCEndpointsStore(store: keychain).load() == ["https://b.example.com"])
    }

    @Test("removeRPCEndpoint for a URL not in the list is a no-op")
    func removeRPCEndpointNoOpForUnknownURL() throws {
      let (store, keychain) = try makeStore(seedEndpoints: ["https://a.example.com"])
      defer { keychain.clear() }
      store.removeRPCEndpoint("https://not-configured.example.com")
      #expect(store.rpcEndpoints == ["https://a.example.com"])
    }

    // MARK: - Rollback on persistence failure

    @Test("addRPCEndpoint reverts rpcEndpoints and sets error when persistence fails")
    func addRPCEndpointRevertsOnPersistFailure() throws {
      let (store, keychain) = try makeStore(
        rpcEndpointsStore: FailingRPCEndpointsStore(seeded: ["https://existing.example.com"]))
      defer { keychain.clear() }
      store.addRPCEndpoint("https://new.example.com")
      #expect(store.rpcEndpoints == ["https://existing.example.com"])
      #expect(store.error != nil)
    }

    @Test("removeRPCEndpoint reverts rpcEndpoints and sets error when persistence fails")
    func removeRPCEndpointRevertsOnPersistFailure() throws {
      let (store, keychain) = try makeStore(
        rpcEndpointsStore: FailingRPCEndpointsStore(seeded: ["https://existing.example.com"]))
      defer { keychain.clear() }
      store.removeRPCEndpoint("https://existing.example.com")
      #expect(store.rpcEndpoints == ["https://existing.example.com"])
      #expect(store.error != nil)
    }

    // MARK: - probeEndpoints (via rpcProbeOverride)

    @Test("probeEndpoints stores the override's results in rpcProbes")
    func probeEndpointsStoresOverrideResults() async throws {
      let (store, keychain) = try makeStore(seedEndpoints: ["https://rpc.example.com"])
      defer { keychain.clear() }
      store.rpcProbeOverride = { endpoints in
        endpoints.map { RPCEndpointResolver.Probe(url: $0, reachable: true, chainId: 1) }
      }
      await store.probeEndpoints()
      #expect(
        store.rpcProbes == [
          RPCEndpointResolver.Probe(url: "https://rpc.example.com", reachable: true, chainId: 1)
        ])
    }

    @Test("probeEndpoints passes the current rpcEndpoints to the override")
    func probeEndpointsPassesCurrentEndpointList() async throws {
      let (store, keychain) = try makeStore()
      defer { keychain.clear() }
      store.addRPCEndpoint("https://rpc.example.com")
      // Echo the endpoints the override was called with back as `Probe`
      // results, so the assertion below can inspect what the store
      // actually passed in — without mutating a captured `var` from a
      // `@Sendable` closure (disallowed under strict concurrency).
      store.rpcProbeOverride = { endpoints in
        endpoints.map { RPCEndpointResolver.Probe(url: $0, reachable: false, chainId: nil) }
      }
      await store.probeEndpoints()
      #expect(store.rpcProbes.map(\.url) == ["https://rpc.example.com"])
    }

    // MARK: - addRPCEndpointAndProbe / removeRPCEndpointAndProbe

    @Test("addRPCEndpointAndProbe adds the endpoint and refreshes rpcProbes")
    func addRPCEndpointAndProbeAddsAndProbes() async throws {
      let (store, keychain) = try makeStore()
      defer { keychain.clear() }
      store.rpcProbeOverride = { endpoints in
        endpoints.map { RPCEndpointResolver.Probe(url: $0, reachable: true, chainId: 1) }
      }
      await store.addRPCEndpointAndProbe("https://rpc.example.com")
      #expect(store.rpcEndpoints == ["https://rpc.example.com"])
      #expect(store.rpcProbes.map(\.url) == ["https://rpc.example.com"])
    }

    @Test("removeRPCEndpointAndProbe removes the endpoint and refreshes rpcProbes")
    func removeRPCEndpointAndProbeRemovesAndProbes() async throws {
      let (store, keychain) = try makeStore(
        seedEndpoints: ["https://a.example.com", "https://b.example.com"])
      defer { keychain.clear() }
      store.rpcProbeOverride = { endpoints in
        endpoints.map { RPCEndpointResolver.Probe(url: $0, reachable: true, chainId: 1) }
      }
      await store.removeRPCEndpointAndProbe("https://a.example.com")
      #expect(store.rpcEndpoints == ["https://b.example.com"])
      #expect(store.rpcProbes.map(\.url) == ["https://b.example.com"])
    }

    // MARK: - RPCEndpointStatus

    @Test("RPCEndpointStatus is notYetProbed for a nil Probe")
    func statusNotYetProbedForNilProbe() {
      #expect(RPCEndpointStatus(probe: nil) == .notYetProbed)
    }

    @Test("RPCEndpointStatus is unreachable for a failed Probe")
    func statusUnreachableForFailedProbe() {
      let probe = RPCEndpointResolver.Probe(
        url: "https://bad.example.com", reachable: false, chainId: nil)
      #expect(RPCEndpointStatus(probe: probe) == .unreachable)
    }

    @Test("RPCEndpointStatus is reachable(chainName:) for a recognized chain id")
    func statusReachableForRecognizedChain() {
      let probe = RPCEndpointResolver.Probe(
        url: "https://eth.example.com", reachable: true, chainId: 1)
      #expect(RPCEndpointStatus(probe: probe) == .reachable(chainName: "Ethereum"))
    }

    @Test("RPCEndpointStatus is reachableUnknownChain for an unrecognized chain id")
    func statusReachableUnknownChainForUnrecognizedChain() {
      let probe = RPCEndpointResolver.Probe(
        url: "https://exotic.example.com", reachable: true, chainId: 999_999)
      #expect(RPCEndpointStatus(probe: probe) == .reachableUnknownChain(chainId: 999_999))
    }
  }

#endif
