// MoolahTests/Shared/CryptoImport/CryptoTokenDiscoveryCoalescerTests.swift
import Foundation
import Testing

@testable import Moolah

/// Concurrency-focused tests for `CryptoTokenDiscoveryService`'s
/// in-flight task coalescer. The behavioural / classification tests live
/// in `CryptoTokenDiscoveryServiceTests`; this file isolates the heavier
/// stress assertions.
@Suite("CryptoTokenDiscoveryService — Coalescer")
struct CryptoTokenDiscoveryCoalescerTests {
  private static let usdcAddress = "0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48"
  private static let usdcId = "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"

  @Test("100 concurrent resolves on the same key → 1 resolver call")
  func coalescerCoalescesIdenticalKey() async throws {
    let subject = makeDiscoverySubject()
    subject.resolver.script(
      .init(chainId: 1, contractAddress: Self.usdcAddress.lowercased()),
      .success(coingecko: "usd-coin", cryptocompare: nil, binance: nil))

    let n = 100
    try await withThrowingTaskGroup(of: CryptoRegistration.self) { group in
      for _ in 0..<n {
        group.addTask {
          try await subject.service.resolveOrLoad(
            chain: .ethereum,
            contractAddress: Self.usdcAddress,
            symbol: "USDC",
            name: "USD Coin",
            decimals: 6)
        }
      }
      var observedIds: Set<String> = []
      for try await result in group {
        observedIds.insert(result.id)
      }
      #expect(observedIds == [Self.usdcId])
    }

    let resolverKey = CountingRegistrationResolver.Key(
      chainId: 1, contractAddress: Self.usdcAddress.lowercased())
    #expect(subject.resolver.callCount(for: resolverKey) == 1)
  }

  @Test("Stress: 1000 resolves across 5 keys → exactly 1 call per key")
  func coalescerScalesAcrossKeys() async throws {
    let subject = makeDiscoverySubject()
    let keys: [(chain: ChainConfig, address: String)] = [
      (.ethereum, "0x1111111111111111111111111111111111111111"),
      (.ethereum, "0x2222222222222222222222222222222222222222"),
      (.optimism, "0x3333333333333333333333333333333333333333"),
      (.base, "0x4444444444444444444444444444444444444444"),
      (.optimism, "0x5555555555555555555555555555555555555555"),
    ]
    for (chain, address) in keys {
      subject.resolver.script(
        .init(chainId: chain.chainId, contractAddress: address.lowercased()),
        .success(coingecko: "id-\(chain.chainId)", cryptocompare: nil, binance: nil))
    }

    let totalCalls = 1000
    try await withThrowingTaskGroup(of: Void.self) { group in
      for index in 0..<totalCalls {
        let pick = keys[index % keys.count]
        group.addTask {
          _ = try await subject.service.resolveOrLoad(
            chain: pick.chain,
            contractAddress: pick.address,
            symbol: "T\(pick.chain.chainId)",
            name: "Token \(pick.chain.chainId)",
            decimals: 18)
        }
      }
      try await group.waitForAll()
    }

    for (chain, address) in keys {
      let resolverKey = CountingRegistrationResolver.Key(
        chainId: chain.chainId, contractAddress: address.lowercased())
      #expect(subject.resolver.callCount(for: resolverKey) == 1)
    }
  }
}
