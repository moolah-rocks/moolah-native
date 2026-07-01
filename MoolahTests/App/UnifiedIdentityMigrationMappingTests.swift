// MoolahTests/App/UnifiedIdentityMigrationMappingTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

@MainActor
@Suite
struct UnifiedIdentityMigrationMappingTests {
  @Test("deriveMapping maps every retired per-chain id to its canonical id")
  func mapsRetiredToCanonical() async throws {
    let harness = try MigrationTestHarness.make()
    // Seed the shared registry with ETH on mainnet + OP + Base (all coingeckoId "ethereum"),
    // and OP-USDC alongside mainnet-USDC. Retired rows are present (alias_of written by Task 2).
    try await harness.seedSharedRegistry([
      .ethMainnet, .ethOptimism, .ethBase, .usdcMainnet, .usdcOptimism,
      .noKeyToken(chainId: 10, address: "0xdead"),  // no provider key -> its own canonical
    ])
    let mapping = try await harness.migration.deriveMapping()

    #expect(mapping["10:native"] == "1:native")
    #expect(mapping["8453:native"] == "1:native")
    #expect(
      mapping["10:0x0b2c639c533813f4aa9d7837caf62653d097ff85"]
        == "1:0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48")
    #expect(mapping["1:native"] == nil)  // canonical is never a key
    #expect(mapping["10:0xdead"] == nil)  // no-key token stays chain-scoped
  }
}
