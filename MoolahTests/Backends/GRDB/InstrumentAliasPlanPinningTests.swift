// MoolahTests/Backends/GRDB/InstrumentAliasPlanPinningTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pins the resolver's alias map-build query so a future
/// schema edit that drops `instrument_by_alias` breaks the build immediately.
/// The query itself gains a production consumer in a later PR (the alias map
/// build + registry filter); pinning it now guarantees the index it depends
/// on is correct the moment that code lands. Per `DATABASE_CODE_GUIDE.md` §6.
@Suite("Instrument alias-map query plan")
struct InstrumentAliasPlanPinningTests {
  private func makeDatabase() throws -> DatabaseQueue {
    try ProfileIndexDatabase.openInMemory()
  }

  @Test("alias-map build query uses instrument_by_alias, not a table scan")
  func aliasMapUsesPartialIndex() throws {
    let database = try makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT id, alias_of FROM instrument WHERE alias_of IS NOT NULL
        """)
    // SQLite reports `SCAN instrument USING COVERING INDEX instrument_by_alias`
    // because the partial index (id, alias_of) covers every column the query
    // needs — no main-table lookup required. "COVERING INDEX" is strictly better
    // than a plain index scan; the positive assertion pins the index name, and
    // the negative assertion (via planHasFullTableScanOf) distinguishes a true
    // full-table scan from the covered scan SQLite emits here.
    #expect(detail.contains("USING COVERING INDEX instrument_by_alias"))
    #expect(!PlanPinningTestHelpers.planHasFullTableScanOf(detail, alias: "instrument"))
  }
}
