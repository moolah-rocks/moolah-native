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
  /// split across retired + canonical instrument ids.
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
    UnifiedInstrumentIdentityMigration.setCompleteForTesting(in: defaults)
    #expect(!store.isMigratingCrossChainIdentity)
  }

  /// Verifies that after migration both OP-ETH and mainnet-ETH lots carry the
  /// canonical instrument id and are therefore keyed into the same FIFO queue
  /// in `CostBasisEngine`. The earlier 2021 lot must be consumed first.
  @Test("post-migration: canonical instrument merges per-chain lots into one FIFO queue")
  func fifoMergesAfterCanonicalization() throws {
    // After migration, buys on OP-ETH and mainnet-ETH both carry the canonical
    // instrument (1:native), so CostBasisEngine queues them together.
    var engine = CostBasisEngine()
    let eth = CryptoRegistration.ethMainnet.instrument
    let d2021 = try makeDate(year: 2021, month: 6, day: 1)
    let d2022 = try makeDate(year: 2022, month: 6, day: 1)
    let d2023 = try makeDate(year: 2023, month: 6, day: 1)
    engine.processBuy(instrument: eth, quantity: 1, costPerUnit: 100, date: d2021)
    engine.processBuy(instrument: eth, quantity: 1, costPerUnit: 200, date: d2022)
    let events = engine.processSell(
      instrument: eth, quantity: 1, proceedsPerUnit: 300, date: d2023)
    // FIFO: 2021 lot consumed first.
    #expect(events.first?.acquiredDate == d2021)
    #expect(events.first?.costBasis == 100)
  }
}
