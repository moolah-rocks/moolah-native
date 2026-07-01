// MoolahTests/Backends/GRDB/InstrumentRegistryPlanPinningTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning test for the shared instrument
/// registry's full-map rebuild query. Per
/// `guides/DATABASE_CODE_GUIDE.md` §6 every perf-relevant query gets a
/// paired plan-pinning test so a future schema edit that changes the
/// planner's strategy breaks the build immediately rather than
/// silently regressing.
///
/// `InstrumentRow.fetchInstrumentMap` issues a bare
/// `SELECT * FROM instrument` (via `InstrumentRow.fetchAll`) to load
/// every row and overlay it on the ambient ISO-fiat snapshot. A full
/// `SCAN instrument` is *intentional and correct* here: building the
/// snapshot requires the entire table, the table is small (a few
/// stored rows plus ambient fiat is synthesised in memory, not from
/// SQL), and the query runs only on a cold cache rebuild — never on
/// the memoised steady-state read path. The pin exists so that the
/// scan stays a deliberate full-table read and a future index/`WHERE`
/// edit that turns it into something else is a conscious decision.
@Suite("Shared instrument-registry GRDB query plans")
struct InstrumentRegistryPlanPinningTests {

  @Test("fetchInstrumentMap SELECT * FROM instrument is an intentional full scan")
  func fetchInstrumentMapIsIntentionalFullScan() throws {
    let database = try makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT * FROM instrument
        """)
    // The whole-table read is required to build the `[String:
    // Instrument]` snapshot; there is no `WHERE`/`ORDER BY` to drive an
    // index, and one shouldn't be added — the table is small and this
    // runs only on a cache rebuild. Pin the bare `SCAN instrument` so a
    // future schema change that (e.g.) silently routes this through a
    // partial index has to update this test deliberately.
    #expect(PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "instrument"))
  }

  /// `allCryptoRegistrations()` issues
  /// `SELECT * FROM instrument WHERE kind = ? AND alias_of IS NULL`
  /// (the `alias_of IS NULL` predicate hides aliased / retired rows from
  /// the Settings registry display).
  /// It runs on the startup preset-seeding path, the sync-merge loop,
  /// reconcile, and the analysis / store-refresh reads. There is no index
  /// on `kind` and the `instrument_by_alias` partial index covers the
  /// opposite predicate (`alias_of IS NOT NULL`), so SQLite plans a
  /// `SCAN instrument`: the table is small and reading every non-aliased
  /// crypto row is the query's whole purpose. Pin the intentional full scan
  /// so a future schema edit that (e.g.) routes this through a partial
  /// index has to update this test deliberately.
  @Test("allCryptoRegistrations WHERE kind and alias_of IS NULL is an intentional full scan")
  func allCryptoRegistrationsIsIntentionalFullScan() throws {
    let database = try makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT * FROM instrument WHERE kind = ? AND alias_of IS NULL
        """,
      arguments: [Instrument.Kind.cryptoToken.rawValue])
    #expect(PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "instrument"))
  }

  /// `all()` issues `SELECT * FROM instrument WHERE alias_of IS NULL`
  /// (the `alias_of IS NULL` predicate hides aliased / retired rows from
  /// the picker list). The
  /// `instrument_by_alias` partial index covers the opposite predicate
  /// (`alias_of IS NOT NULL`), so SQLite cannot use it here and plans a
  /// `SCAN instrument`. That is intentional and correct: `all()` needs
  /// every non-aliased row (crypto + stock + stored fiat), the table is
  /// small, and a full scan avoids the read-amplification a secondary
  /// index would add for zero benefit. Pin the scan so a future edit that
  /// (e.g.) adds an `IS NULL` partial index must also update this test.
  @Test("all() WHERE alias_of IS NULL is an intentional full scan")
  func allIsIntentionalFullScan() throws {
    let database = try makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT * FROM instrument WHERE alias_of IS NULL
        """)
    #expect(PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "instrument"))
  }
}

extension InstrumentRegistryPlanPinningTests {
  private func makeDatabase() throws -> DatabaseQueue {
    try ProfileIndexDatabase.openInMemory()
  }
}
