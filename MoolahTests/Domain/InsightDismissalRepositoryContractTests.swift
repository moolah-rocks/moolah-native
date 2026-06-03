import Foundation
import Testing

@testable import Moolah

@Suite("InsightDismissalRepository contract")
struct InsightDismissalRepositoryContractTests {
  @Test
  func recordAndFetch() async throws {
    let (backend, _) = try TestBackend.create()
    _ = try await backend.insightDismissals.recordDismissal(of: .newRecurringDetected)
    let all = try await backend.insightDismissals.fetchAll()
    #expect(all.first { $0.kind == .newRecurringDetected }?.count == 1)
  }

  @Test
  func dismissalSurvivesReopen() async throws {
    // Same on-disk file reopened == relaunch. Use a temp file DB, not the
    // in-memory one, so the second open sees the first open's writes.
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("insight-dismissal-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: url) }

    let first = GRDBInsightDismissalRepository(database: try ProfileDatabase.open(at: url))
    _ = try await first.recordDismissal(of: .feeSpend)
    _ = try await first.recordDismissal(of: .feeSpend)

    let second = GRDBInsightDismissalRepository(database: try ProfileDatabase.open(at: url))
    let all = try await second.fetchAll()
    #expect(all.first { $0.kind == .feeSpend }?.count == 2)
  }
}
