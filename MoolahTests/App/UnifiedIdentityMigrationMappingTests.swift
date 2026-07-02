// MoolahTests/App/UnifiedIdentityMigrationMappingTests.swift

import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("UnifiedIdentityMigration: mapping derivation")
struct UnifiedIdentityMigrationMappingTests {
  @Test("deriveMapping maps every retired per-chain id to its canonical id")
  func mapsRetiredToCanonical() async throws {
    let harness = try MigrationTestHarness.make()
    // Seed the shared registry with ETH on mainnet + OP + Base (all coingeckoId "ethereum"),
    // and OP-USDC alongside mainnet-USDC.
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

  /// Regression backstop: `deriveMapping()` MUST use the UNFILTERED query
  /// `allCryptoRegistrationsIncludingAliased()`. If it were swapped to the
  /// filtered `allCryptoRegistrations()` (which hides rows where
  /// `alias_of IS NOT NULL`), it would silently no-op — the very rows it
  /// needs to map are the aliased ones.
  ///
  /// Seed scenario: `10:native` has `alias_of = "1:native"` set directly via
  /// raw SQL (the state PR4's apply path or Task 2 leaves it in — present,
  /// aliased, and invisible to the filtered query). Then:
  /// A) assert the filtered query does NOT return `10:native` (proving the
  ///    two queries differ for this row — the test premise is sound).
  /// B) assert `deriveMapping()` maps `10:native` → `1:native` (proving it
  ///    reached the aliased row through the unfiltered query).
  ///
  /// RED confirmation: swapping `deriveMapping()` to call
  /// `allCryptoRegistrations()` instead of `allCryptoRegistrationsIncludingAliased()`
  /// makes assertion B fail — `mapping["10:native"]` is `nil` because the
  /// aliased row is invisible to the filtered query and never enters the
  /// mapping loop.
  @Test("deriveMapping reads aliased rows via the unfiltered query (regression backstop)")
  func deriveMappingUsesUnfilteredQuery() async throws {
    let harness = try MigrationTestHarness.make()
    // Seed canonical 1:native and retired 10:native through the normal path.
    try await harness.seedSharedRegistry([.ethMainnet, .ethOptimism])
    // Simulate the alias_of state that PR4's apply path (or Task 2) writes.
    // alias_of is a local-only column absent from InstrumentRow.CodingKeys,
    // so it can only be written by raw SQL — the same constraint production
    // code obeys (see GRDBInstrumentRegistryRepository+SyncEntryPoints.swift).
    try await harness.registry.database.write { database in
      try database.execute(
        sql: "UPDATE instrument SET alias_of = ? WHERE id = ?",
        arguments: ["1:native", "10:native"])
    }
    // Assert A: allCryptoRegistrations() (alias_of IS NULL filter) must NOT
    // return the aliased row. This proves the two query forms differ — the
    // filter is live and the test premise is sound.
    let filteredIds = try await harness.registry.allCryptoRegistrations().map(\.instrument.id)
    #expect(!filteredIds.contains("10:native"))
    // Assert B: deriveMapping() must include the aliased row in the mapping.
    // Fails if deriveMapping() uses the filtered query, because 10:native
    // would be invisible and mapping["10:native"] would be nil.
    let mapping = try await harness.migration.deriveMapping()
    #expect(mapping["10:native"] == "1:native")
  }
}
