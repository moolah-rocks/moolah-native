// MoolahTests/Features/CapitalGainsIdentityMigrationGateTests.swift

import Foundation
import Testing

@testable import Moolah

/// Gates the capital-gains surface on the unified cross-chain identity
/// migration: while the one-shot migration is in flight, `CostBasisEngine`
/// keys lots by `instrument.id`, so lots for the same asset may still be split
/// across retired + canonical ids — any FIFO figure would be wrong.
@Suite("Capital-gains identity-migration gate")
@MainActor
struct CapitalGainsIdentityMigrationGateTests {

  // MARK: - Helpers

  private func makeIsolatedDefaults(tag: String) throws -> UserDefaults {
    let suiteName = "cg-gate-test-\(tag)-\(UUID().uuidString)"
    return try #require(UserDefaults(suiteName: suiteName))
  }

  private func makeDate(year: Int, month: Int, day: Int) throws -> Date {
    try #require(
      Calendar(identifier: .gregorian).date(
        from: DateComponents(year: year, month: month, day: day)))
  }

  // MARK: - Tests

  /// Verifies that `ReportingStore.loadCapitalGains` is a no-op while the
  /// unified-identity migration has not yet completed: `capitalGainsSummary`
  /// must remain `nil` so no FIFO figure is returned while lots are still
  /// split across retired + canonical instrument ids. After the flag is set,
  /// the gate lifts and `loadCapitalGains` populates `capitalGainsSummary`
  /// (even with an empty transaction set — the summary is set to all-zeros).
  @Test("capital gains are gated while migration incomplete")
  func capitalGainsGatedWhileMigrating() async throws {
    let defaults = try makeIsolatedDefaults(tag: "migrating")
    // Flag NOT set → migration in flight.
    let (backend, _) = try TestBackend.create()
    let store = ReportingStore(
      transactionRepository: backend.transactions,
      conversionService: FakeConversionService.fixedRates([:]),
      profileCurrency: .AUD,
      userDefaults: defaults
    )
    #expect(store.isMigratingCrossChainIdentity)

    await store.loadCapitalGains(financialYear: 2023)
    // loadCapitalGains must not populate capitalGainsSummary while migrating.
    #expect(store.capitalGainsSummary == nil)

    // Once the flag is set the gate lifts.
    UnifiedInstrumentIdentityMigration.markCompleteForTesting(in: defaults)
    #expect(!store.isMigratingCrossChainIdentity)

    // After lifting, loadCapitalGains proceeds and populates capitalGainsSummary
    // (all-zeros with no transaction data, but non-nil — proving the gate is gone).
    await store.loadCapitalGains(financialYear: 2023)
    #expect(store.capitalGainsSummary != nil)
  }

  /// Verifies the split-vs-merge property of `CostBasisEngine` keying by
  /// `instrument.id`. Two states are compared:
  ///
  /// **PRE-migration (split):** The OP-ETH buy (`10:native`) and mainnet-ETH
  /// buy (`1:native`) land in separate FIFO queues. Selling the canonical
  /// (`1:native`) only sees the 2022 canonical lot — the 2021 OP lot is
  /// invisible.
  ///
  /// **POST-migration (merged):** Both buys carry the canonical id (`1:native`),
  /// so they share one queue and FIFO consumes the earlier 2021 lot first.
  @Test("post-migration: canonical instrument merges per-chain lots into one FIFO queue")
  func fifoMergesAfterCanonicalization() throws {
    let eth = CryptoRegistration.ethMainnet.instrument  // id = "1:native"
    let opEth = CryptoRegistration.ethOptimism.instrument  // id = "10:native"
    let d2021 = try makeDate(year: 2021, month: 6, day: 1)
    let d2022 = try makeDate(year: 2022, month: 6, day: 1)
    let d2023 = try makeDate(year: 2023, month: 6, day: 1)

    // PRE-migration: buys are on different instrument ids (10:native vs 1:native).
    // Selling the canonical (1:native) sees only the 2022 lot — the 2021 OP lot
    // is in the 10:native queue and is invisible to the sell.
    var preMigration = CostBasisEngine()
    preMigration.processBuy(
      instrument: opEth, quantity: 1, costPerUnit: 100, date: d2021)
    preMigration.processBuy(
      instrument: eth, quantity: 1, costPerUnit: 200, date: d2022)
    let preEvents = preMigration.processSell(
      instrument: eth, quantity: 1, proceedsPerUnit: 300, date: d2023)
    // Only the 2022 canonical lot is in the 1:native queue.
    #expect(preEvents.first?.acquiredDate == d2022)
    #expect(preEvents.first?.costBasis == 200)

    // POST-migration: both buys carry the canonical id (1:native), forming one
    // FIFO queue. FIFO must consume the 2021 lot first.
    var postMigration = CostBasisEngine()
    postMigration.processBuy(
      instrument: eth, quantity: 1, costPerUnit: 100, date: d2021)
    postMigration.processBuy(
      instrument: eth, quantity: 1, costPerUnit: 200, date: d2022)
    let postEvents = postMigration.processSell(
      instrument: eth, quantity: 1, proceedsPerUnit: 300, date: d2023)
    // 2021 lot is consumed first.
    #expect(postEvents.first?.acquiredDate == d2021)
    #expect(postEvents.first?.costBasis == 100)
  }
}
