import Foundation
import GRDB
import Testing

@testable import Moolah

/// Rollback contract for the `needs_push` mark (issue #1081). Every
/// mutation sets `needs_push = 1` inside the same `database.write` as the
/// row change; a failure on the mark itself must roll the whole write
/// back, leaving no torn "fields updated but flag not set" (or vice-versa)
/// half-write.
@Suite("needs_push mark is transactional")
@MainActor
struct NeedsPushMarkRollbackTests {
  /// Installs a `BEFORE UPDATE OF needs_push` trigger on `account` that
  /// aborts, then drives `update(_:)` (which renames the row and then
  /// marks it dirty in the same transaction). The rename must be undone
  /// and the flag must stay clear.
  @Test
  func accountMutationNeedsPushMarkRollsBackTransactionally() async throws {
    let database = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let repo = GRDBAccountRepository(
      database: database,
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let id = UUID()
    let original = Account(id: id, name: "Original", type: .bank, instrument: .AUD)
    _ = try await repo.create(original, openingBalance: nil)
    // Clear the create's mark so the trigger below fires only on update's mark.
    _ = try repo.clearNeedsPushBatchSync([id])

    // Abort specifically when the `needs_push` column is updated — i.e. on
    // the mark step, after `update` has already issued the field UPDATE in
    // the same transaction.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_account_needs_push_mark
          BEFORE UPDATE OF needs_push ON account
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let mutated = Account(
      id: id, name: "Renamed", type: .bank, instrument: .AUD,
      position: 99, isHidden: true)
    do {
      _ = try await repo.update(mutated)
      Issue.record("update should have thrown but did not")
    } catch {
      // Expected — the needs_push mark trips the trigger.
    }

    // The whole write rolled back: field values are byte-equal to the
    // pre-update snapshot, and the flag is still clear.
    let surviving = try await database.read { database in
      try AccountRow.filter(AccountRow.Columns.id == id).fetchOne(database)
    }
    let row = try #require(surviving)
    #expect(row.name == "Original")
    #expect(row.position != 99)
    #expect(row.isHidden == false)
    #expect(try repo.dirtyIdsSync(from: [id]).isEmpty)
  }
}
