import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("GRDBInsightDismissalRepository sync helpers")
struct InsightDismissalRepoSyncHelpersTests {
  private func makeRepo() throws -> (GRDBInsightDismissalRepository, DatabaseQueue) {
    let queue = try ProfileDatabase.openInMemory()
    return (GRDBInsightDismissalRepository(database: queue), queue)
  }

  @Test
  func recordDismissalIncrementsAtomically() async throws {
    let (repo, _) = try makeRepo()
    _ = try await repo.recordDismissal(of: .newRecurringDetected)
    _ = try await repo.recordDismissal(of: .newRecurringDetected)
    let third = try await repo.recordDismissal(of: .newRecurringDetected)
    #expect(third.count == 3)
    let all = try await repo.fetchAll()
    #expect(all.count == 1)
    #expect(all.first?.count == 3)
  }

  @Test
  func distinctKindsAreIndependent() async throws {
    let (repo, _) = try makeRepo()
    _ = try await repo.recordDismissal(of: .newRecurringDetected)
    _ = try await repo.recordDismissal(of: .subscriptionPriceHike)
    _ = try await repo.recordDismissal(of: .subscriptionPriceHike)
    let byKind = Dictionary(
      uniqueKeysWithValues: try await repo.fetchAll().map { ($0.kind, $0.count) })
    #expect(byKind[.newRecurringDetected] == 1)
    #expect(byKind[.subscriptionPriceHike] == 2)
  }

  @Test
  func applyRemoteChangesUpsertsAndDeletes() throws {
    let (repo, _) = try makeRepo()
    let row = InsightDismissalRow(kind: .feeSpend, count: 5)
    try repo.applyRemoteChangesSync(saved: [row], deleted: [])
    #expect(try repo.fetchRowSync(id: row.id)?.count == 5)
    try repo.applyRemoteChangesSync(saved: [], deleted: [row.id])
    #expect(try repo.fetchRowSync(id: row.id) == nil)
  }

  @Test
  func unsyncedRowIdsReportsRowsMissingSystemFields() throws {
    let (repo, _) = try makeRepo()
    let row = InsightDismissalRow(kind: .feeSpend, count: 1)
    try repo.applyRemoteChangesSync(saved: [row], deleted: [])
    #expect(try repo.unsyncedRowIdsSync() == [row.id])
    _ = try repo.setEncodedSystemFieldsSync(id: row.id, data: Data([0x01]))
    #expect(try repo.unsyncedRowIdsSync().isEmpty)
  }
}
