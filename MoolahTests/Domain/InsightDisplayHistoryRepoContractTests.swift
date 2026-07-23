import Foundation
import Testing

@testable import Moolah

@Suite("InsightDisplayHistoryRepository contract")
struct InsightDisplayHistoryRepoContractTests {
  @Test("recordShown stores each semantic presentation key")
  func recordsPresentationKeys() async throws {
    let (backend, _) = try TestBackend.create()
    let shownAt = Date(timeIntervalSince1970: 1_700_000_000)

    try await backend.insightDisplayHistory.recordShown(
      ["large-payment:one", "large-payment:two"], at: shownAt)

    let history = try await backend.insightDisplayHistory.fetchLastShown()
    #expect(history["large-payment:one"] == shownAt)
    #expect(history["large-payment:two"] == shownAt)
  }

  @Test("recordShown keeps the most recent display")
  func keepsMostRecentDisplay() async throws {
    let (backend, _) = try TestBackend.create()
    let recent = Date(timeIntervalSince1970: 1_700_100_000)
    let older = Date(timeIntervalSince1970: 1_700_000_000)

    try await backend.insightDisplayHistory.recordShown(["idle-cash"], at: recent)
    try await backend.insightDisplayHistory.recordShown(["idle-cash"], at: older)

    let history = try await backend.insightDisplayHistory.fetchLastShown()
    #expect(history["idle-cash"] == recent)
  }

  @Test("recordShown removes display history after the retention window")
  func removesExpiredHistory() async throws {
    let (backend, _) = try TestBackend.create()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let staleDate = now.addingTimeInterval(-100 * 24 * 60 * 60)

    try await backend.insightDisplayHistory.recordShown(["stale"], at: staleDate)
    try await backend.insightDisplayHistory.recordShown(["current"], at: now)

    let history = try await backend.insightDisplayHistory.fetchLastShown()
    #expect(history["stale"] == nil)
    #expect(history["current"] == now)
  }
}
