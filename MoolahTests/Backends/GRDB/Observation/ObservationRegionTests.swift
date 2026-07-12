import Foundation
import GRDB
import Testing

@testable import Moolah

/// Verifies that every row whose table carries an `encoded_system_fields`
/// column exposes an `observableRegion` request that excludes that column,
/// and that `ValueObservation`s tracked over those regions do not re-fire
/// on sync-bookkeeping writes. See issue #865.
@Suite("Observation regions exclude encoded_system_fields")
struct ObservationRegionTests {

  // MARK: - Static region tests
  //
  // Each row type that has a CKSyncEngine `encoded_system_fields` column
  // must expose an `observableRegion` request that ValueObservation can
  // use as a `DatabaseRegionConvertible`. The region must include every
  // domain-relevant column but exclude `encoded_system_fields`, so writes
  // landing only on the system-fields blob do not re-fire the observation
  // fetch closure.

  @Test("AccountRow.observableRegion excludes encoded_system_fields")
  func accountRowRegion() throws {
    try assertProfileRegionExcludesSystemFields(AccountRow.observableRegion)
  }

  @Test("CategoryRow.observableRegion excludes encoded_system_fields")
  func categoryRowRegion() throws {
    try assertProfileRegionExcludesSystemFields(CategoryRow.observableRegion)
  }

  @Test("EarmarkRow.observableRegion excludes encoded_system_fields")
  func earmarkRowRegion() throws {
    try assertProfileRegionExcludesSystemFields(EarmarkRow.observableRegion)
  }

  @Test("EarmarkBudgetItemRow.observableRegion excludes encoded_system_fields")
  func earmarkBudgetItemRowRegion() throws {
    try assertProfileRegionExcludesSystemFields(EarmarkBudgetItemRow.observableRegion)
  }

  @Test("TransactionRow.observableRegion excludes encoded_system_fields")
  func transactionRowRegion() throws {
    try assertProfileRegionExcludesSystemFields(TransactionRow.observableRegion)
  }

  @Test("TransactionLegRow.observableRegion excludes encoded_system_fields")
  func transactionLegRowRegion() throws {
    try assertProfileRegionExcludesSystemFields(TransactionLegRow.observableRegion)
  }

  @Test("InstrumentRow.observableRegion excludes encoded_system_fields")
  func instrumentRowRegion() throws {
    // `InstrumentRow` lives on the profile-index DB — the per-profile
    // `instrument` table was removed by
    // `v10_drop_shared_instrument_legacy`, so the region must resolve
    // against the schema that still has the table.
    try assertProfileIndexRegionExcludesSystemFields(InstrumentRow.observableRegion)
  }

  @Test("CSVImportProfileRow.observableRegion excludes encoded_system_fields")
  func csvImportProfileRowRegion() throws {
    try assertProfileRegionExcludesSystemFields(CSVImportProfileRow.observableRegion)
  }

  @Test("ImportRuleRow.observableRegion excludes encoded_system_fields")
  func importRuleRowRegion() throws {
    try assertProfileRegionExcludesSystemFields(ImportRuleRow.observableRegion)
  }

  // MARK: - End-to-end fetch-count assertion
  //
  // The repository observations bridge to `AsyncStream` via the retrying
  // wrapper, so we can't directly count fetches against them. Instead we
  // build a `ValueObservation` using the same `*.observableRegion`
  // requests the production observations now pass to
  // `tracking(regions:fetch:)`, instrument the fetch closure with a
  // counter, and verify the counter does not advance when only
  // `encoded_system_fields` is written.

  @Test("fetch closure does not re-fire on encoded_system_fields write")
  func fetchClosureDoesNotRefireOnSystemFieldsWrite() async throws {
    let databaseQueue = try ProfileDatabase.openInMemory()
    let accountId = UUID()
    try await seedAccount(id: accountId, in: databaseQueue)

    let fetchCount = LockedBox<Int>(0)
    let observation = makeAccountObservation(fetchCount: fetchCount)
    let task = drainObservation(observation, in: databaseQueue)
    defer { task.cancel() }

    // Wait for the initial fetch to land.
    try await waitForCount(fetchCount, equals: 1, within: .milliseconds(500))
    let initialCount = fetchCount.get()

    // Sync-bookkeeping write — only touches encoded_system_fields.
    try await writeSystemFields(of: accountId, in: databaseQueue)
    // Give the observation 200ms to fire if it would. (It must not.)
    try await Task.sleep(for: .milliseconds(200))
    #expect(
      fetchCount.get() == initialCount,
      "fetch closure must NOT re-fire on encoded_system_fields write (issue #865)")

    // Sanity: writing a real column must trigger a re-fetch.
    try await renameAccount(id: accountId, in: databaseQueue)
    try await waitForCount(fetchCount, equals: initialCount + 1, within: .milliseconds(500))
  }

  // MARK: - Helpers

  /// Opens a fresh in-memory profile database and asserts the supplied
  /// request's tracked region does not include `encoded_system_fields`.
  /// Works for any row whose table lives in `ProfileDatabase` (every
  /// affected table in #865).
  private func assertProfileRegionExcludesSystemFields<R: DatabaseRegionConvertible>(
    _ request: R
  ) throws {
    let databaseQueue = try ProfileDatabase.openInMemory()
    try databaseQueue.read { database in
      let region = try request.databaseRegion(database)
      let description = String(describing: region)
      #expect(
        !description.contains("encoded_system_fields"),
        "tracked region must exclude encoded_system_fields, was: \(description)")
    }
  }

  /// Profile-index analogue of `assertProfileRegionExcludesSystemFields`
  /// for rows whose table lives on the shared profile-index DB
  /// (`InstrumentRow`, post-`v10_drop_shared_instrument_legacy`).
  /// Assertion semantics are identical.
  private func assertProfileIndexRegionExcludesSystemFields<
    R: DatabaseRegionConvertible
  >(
    _ request: R
  ) throws {
    let databaseQueue = try ProfileIndexDatabase.openInMemory()
    try databaseQueue.read { database in
      let region = try request.databaseRegion(database)
      let description = String(describing: region)
      #expect(
        !description.contains("encoded_system_fields"),
        "tracked region must exclude encoded_system_fields, was: \(description)")
    }
  }

  /// Inserts a single bank account row into an empty profile database.
  private func seedAccount(id accountId: UUID, in databaseQueue: DatabaseQueue) async throws {
    let recordName = "AccountRecord|\(accountId.uuidString.lowercased())"
    try await databaseQueue.write { database in
      try AccountRow(
        id: accountId,
        recordName: recordName,
        name: "A",
        type: "bank",
        instrumentId: "USD",
        position: 0,
        isHidden: false,
        encodedSystemFields: nil,
        valuationMode: "recordedValue",
        walletAddress: nil,
        chainId: nil
      ).insert(database)
    }
  }

  /// Builds a `ValueObservation` over `AccountRow.observableRegion` whose
  /// fetch closure bumps `fetchCount` on every invocation. The test uses
  /// this counter to detect whether a sync-bookkeeping write re-triggers
  /// the closure (it must not).
  private func makeAccountObservation(
    fetchCount: LockedBox<Int>
  ) -> ValueObservation<ValueReducers.Fetch<[AccountRow]>> {
    ValueObservation.tracking(
      regions: [AccountRow.observableRegion],
      fetch: { database in
        fetchCount.set(fetchCount.get() + 1)
        return try AccountRow.fetchAll(database)
      }
    )
  }

  /// Subscribes to `observation` against `databaseQueue` and discards
  /// every emission. Cancellation throws inside the `for try await` loop;
  /// the catch swallows it so the spawned `Task` always completes
  /// normally when its parent `defer` cancels it.
  private func drainObservation(
    _ observation: ValueObservation<ValueReducers.Fetch<[AccountRow]>>,
    in databaseQueue: DatabaseQueue
  ) -> Task<Void, Never> {
    Task<Void, Never> {
      do {
        for try await _ in observation.values(in: databaseQueue) {
          // drain — we only care about fetchCount
        }
      } catch {
        // Cancellation throws; ignore.
      }
    }
  }

  /// Writes a synthetic `encoded_system_fields` blob to the account row,
  /// mirroring `ProfileDataSyncHandler.updateSystemFieldsForSaved`'s
  /// per-batch update.
  private func writeSystemFields(of accountId: UUID, in databaseQueue: DatabaseQueue) async throws {
    try await databaseQueue.write { database in
      _ =
        try AccountRow
        .filter(AccountRow.Columns.id == accountId)
        .updateAll(
          database,
          [AccountRow.Columns.encodedSystemFields.set(to: Data([1, 2, 3]))])
    }
  }

  /// Writes a real (non-bookkeeping) column on the account row so the
  /// test's sanity assertion can confirm the observation still fires on
  /// legitimate writes.
  private func renameAccount(id accountId: UUID, in databaseQueue: DatabaseQueue) async throws {
    try await databaseQueue.write { database in
      _ =
        try AccountRow
        .filter(AccountRow.Columns.id == accountId)
        .updateAll(database, [AccountRow.Columns.name.set(to: "Renamed")])
    }
  }

  /// Polls `box` until it equals `target` or `timeout` elapses. Used by
  /// observation tests to wait for the next fetch closure invocation
  /// without sleeping past it (the fetch arrives via a Task-scheduled
  /// callback whose timing the test cannot drive directly).
  private func waitForCount(
    _ box: LockedBox<Int>,
    equals target: Int,
    within timeout: Duration
  ) async throws {
    let deadline = ContinuousClock().now.advanced(by: timeout)
    while box.get() != target {
      if ContinuousClock().now >= deadline {
        throw WaitForCountTimedOut(actual: box.get(), expected: target)
      }
      try await Task.sleep(for: .milliseconds(10))
      // CONCURRENCY_GUIDE §8: check cancellation after every suspension
      // point in polling loops so a cancelled test doesn't busy-spin.
      if Task.isCancelled { return }
    }
  }

  private struct WaitForCountTimedOut: Error, CustomStringConvertible {
    let actual: Int
    let expected: Int
    var description: String {
      "timed out waiting for fetch count to reach \(expected); was \(actual)"
    }
  }
}
