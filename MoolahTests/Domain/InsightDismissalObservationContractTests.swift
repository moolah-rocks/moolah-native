import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InsightDismissalRepository observation contract")
struct InsightDismissalObservationContractTests {

  /// A concrete repo over a fresh in-memory DB. The concrete type is needed
  /// so the system-fields-region test can drive `setEncodedSystemFieldsSync`
  /// (a sync entry point that lives off the domain protocol).
  private func makeRepo() throws -> GRDBInsightDismissalRepository {
    GRDBInsightDismissalRepository(database: try ProfileDatabase.openInMemory())
  }

  @Test("initial emission reflects current DB state")
  func initialEmission() async throws {
    let repo = try makeRepo()
    var iterator = repo.observeAll().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  @Test("recordDismissal emits the updated tally")
  func recordDismissalEmits() async throws {
    let repo = try makeRepo()
    var iterator = repo.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    _ = try await repo.recordDismissal(of: .subscriptionPriceHike)

    let after = await iterator.next()
    #expect(after?.count == 1)
    #expect(after?.first?.kind == .subscriptionPriceHike)
    #expect(after?.first?.count == 1)
  }

  /// A system-fields-only write (the per-batch sync bookkeeping CKSyncEngine
  /// performs after a successful upload) must NOT re-fire UI observers,
  /// because `observableRegion` excludes the `encoded_system_fields` column.
  /// Regression guard for issue #865.
  @Test("system-fields-only write does not re-emit")
  func systemFieldsWriteDoesNotReEmit() async throws {
    let repo = try makeRepo()

    // Seed one tally so there is a row to stamp, and consume the emissions
    // up to and including that seed.
    let seeded = try await repo.recordDismissal(of: .feeSpend)
    let rowId = InsightDismissalRow.id(for: seeded.kind)

    var iterator = repo.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial — single tally

    // Stamp system fields only. This touches `encoded_system_fields`, which
    // is excluded from `observableRegion`, so no new emission should arrive.
    _ = try repo.setEncodedSystemFieldsSync(id: rowId, data: Data([0xAB]))

    let receivedBox = LockedBox<Bool>(false)
    let pollTask = Task<Void, Never> { [receivedBox] in
      var localIterator = iterator
      if await localIterator.next() != nil {
        receivedBox.set(true)
      }
    }
    try? await Task.sleep(for: .milliseconds(200))
    pollTask.cancel()
    _ = await pollTask.value
    #expect(
      receivedBox.get() == false,
      "observableRegion did not exclude encoded_system_fields: a system-fields-only write re-emitted"
    )
  }
}
