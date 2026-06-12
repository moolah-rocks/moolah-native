// MoolahTests/Backends/GRDB/ProfileIndexPlanPinningTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// `EXPLAIN QUERY PLAN`-pinning tests for the profile-index DB. Per
/// `guides/DATABASE_CODE_GUIDE.md` §6 every perf-critical query gets a
/// paired plan-pinning test so an index regression breaks the build
/// immediately.
///
/// Pinned queries:
///
/// 1. `profile.created_at` ascending — the canonical fetch order used
///    by `GRDBProfileIndexRepository.fetchAll()` and the profile picker.
///    Must hit `profile_by_created_at` and avoid a temp B-tree sort.
/// 2. `profile.id` lookup — primary-key search used by
///    `GRDBProfileIndexRepository.profile(forID:)` (every session-open)
///    and `mergeDataFormatVersionSync` (every sync-merge). Must use the
///    table's primary key.
/// 3. `deletion_journal` ordered by `queued_at` — the start-time
///    deletion-journal replay sweep (`DeletionJournal.allEntries(in:)`,
///    issue #1090 / #1097). Must hit `deletion_journal_by_queued_at`
///    and avoid a temp B-tree sort.
@Suite("Profile-index GRDB query plans")
struct ProfileIndexPlanPinningTests {
  /// `PlanPinningTestHelpers.makeDatabase` opens the per-profile
  /// database, but the profile-index DB has its own factory. Open the
  /// in-memory profile-index queue here and reuse the shared `planDetail`
  /// helper for the EXPLAIN-fetch glue.
  private func makeDatabase() throws -> DatabaseQueue {
    try ProfileIndexDatabase.openInMemory()
  }

  @Test("fetchAll ORDER BY created_at uses profile_by_created_at index")
  func profileOrderByCreatedAtUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT id FROM profile ORDER BY created_at
        """)
    // `GRDBProfileIndexRepository.fetchAll` orders by created_at ASC —
    // pinning the index here prevents a future schema edit from
    // silently regressing fetchAll() to a temp-B-tree sort over the
    // entire table.
    //
    // SQLite emits `SCAN profile USING INDEX profile_by_created_at`
    // for ORDER BY index scans (the table itself is "scanned" via the
    // index in created_at order). A literal `!detail.contains("SCAN
    // profile")` guard would always fail here — the absence of `USE
    // TEMP B-TREE` is the correct regression signal that the planner
    // is using the index for ordering rather than a transient sort.
    #expect(detail.contains("USING INDEX profile_by_created_at"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }

  @Test("filter by id uses primary key index")
  func profileFilterByIdUsesPrimaryKey() throws {
    let database = try makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT id FROM profile WHERE id = ?
        """,
      arguments: [UUID()])
    // BLOB PRIMARY KEY columns surface as
    // `SEARCH … USING INDEX sqlite_autoindex_profile_1`. Pin the exact
    // auto-index name so a future change that drops the PK declaration
    // (and silently reverts to a SCAN) fails this test rather than
    // passing on a `SEARCH` against any other index.
    //
    // `profile(forID:)` runs on every session-open and
    // `mergeDataFormatVersionSync` runs on every sync-merge — both
    // perf-sensitive paths that DATABASE_CODE_GUIDE.md §6 requires we
    // pin.
    #expect(detail.contains("sqlite_autoindex_profile_1"))
    #expect(!detail.contains("SCAN"))
  }

  @Test("allEntries ORDER BY queued_at uses deletion_journal_by_queued_at index")
  func deletionJournalOrderByQueuedAtUsesIndex() throws {
    let database = try makeDatabase()
    let detail = try PlanPinningTestHelpers.planDetail(
      database,
      query: """
        SELECT zone_name, record_name, record_type, queued_at
        FROM deletion_journal ORDER BY queued_at
        """)
    // `DeletionJournal.allEntries(in:)` runs at every engine start to drive the
    // deletion-journal replay (issue #1090 / #1097); pinning the index prevents
    // a future schema edit from regressing it to a temp-B-tree sort.
    #expect(detail.contains("USING INDEX deletion_journal_by_queued_at"))
    #expect(!detail.contains("USE TEMP B-TREE"))
  }
}
