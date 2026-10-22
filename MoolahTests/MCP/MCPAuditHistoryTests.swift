import Foundation
import MoolahMCP
import Testing

@testable import Moolah

struct MCPAuditHistoryTests {
  @Test
  func retentionCapacityAndClearSurviveReopening() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("audit.json")
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let history = MCPAuditHistory(url: url, now: { instant })
    let credentialID = UUID()
    let profileID = UUID()
    for index in 0..<1002 {
      try await history.append(
        MCPAuditEvent(
          timestamp: instant.addingTimeInterval(Double(index - 1002)),
          credentialID: credentialID,
          tool: "moolah_list_accounts",
          profileID: profileID,
          duration: 0.01,
          outcome: "OK"
        )
      )
    }
    let loaded = try await history.entries()
    #expect(loaded.count == 1000)
    let later = MCPAuditHistory(url: url, now: { instant.addingTimeInterval(7 * 86400) })
    #expect(try await later.entries().isEmpty)
    #expect(try JSONDecoder().decode([MCPAuditEvent].self, from: Data(contentsOf: url)).isEmpty)
    try await history.clear()
    #expect(try await history.entries().isEmpty)
  }

  @Test
  func concurrentAppendsAreSerializedWithoutLosingEvents() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let history = MCPAuditHistory(
      url: directory.appendingPathComponent("audit.json"),
      now: { instant }
    )
    try await withThrowingTaskGroup(of: Void.self) { group in
      for _ in 0..<50 {
        group.addTask {
          try await history.append(
            MCPAuditEvent(
              timestamp: instant,
              credentialID: UUID(),
              tool: "unknown",
              profileID: nil,
              duration: 0,
              outcome: "OK"
            )
          )
        }
      }
      try await group.waitForAll()
    }
    let entries = try await history.entries()
    #expect(entries.count == 50)
    #expect(Set(entries.map(\.credentialID)).count == 50)
  }

  @Test
  func loadedRecordsAreValidatedAndClearRecoversInvalidMetadata() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("audit.json")
    let event = MCPAuditEvent(
      timestamp: Date(timeIntervalSince1970: 1_700_000_000),
      credentialID: UUID(),
      tool: "arbitrary persisted query",
      profileID: nil,
      duration: 0,
      outcome: "OK"
    )
    try JSONEncoder().encode([event]).write(to: url)
    let history = MCPAuditHistory(url: url)
    await #expect(throws: MCPStorageFailure.self) { _ = try await history.entries() }
    try await history.clear()
    #expect(try await history.entries().isEmpty)
  }

  @Test
  func historyAcceptsOnlyClosedDiagnosticMetadata() async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let history = MCPAuditHistory(
      url: directory.appendingPathComponent("audit.json"),
      now: { instant }
    )
    await #expect(throws: MCPStorageFailure.self) {
      try await history.append(
        MCPAuditEvent(
          timestamp: instant,
          credentialID: UUID(),
          tool: "secret payee query",
          profileID: nil,
          duration: 0,
          outcome: "OK"
        )
      )
    }
    await #expect(throws: MCPStorageFailure.self) {
      try await history.append(
        MCPAuditEvent(
          timestamp: instant,
          credentialID: UUID(),
          tool: "unknown",
          profileID: nil,
          duration: 0,
          outcome: "secret underlying error"
        )
      )
    }
    #expect(try await history.entries().isEmpty)
  }
  @Test(arguments: ["RESULT_TOO_LARGE", "CALCULATION_LIMIT_EXCEEDED", "RESPONSE_TOO_LARGE"])
  func limitOutcomeCodesSurviveReopening(code: String) async throws {
    let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("audit.json")
    let instant = Date(timeIntervalSince1970: 1_700_000_000)
    let history = MCPAuditHistory(url: url, now: { instant })
    try await history.append(
      MCPAuditEvent(
        timestamp: instant,
        credentialID: UUID(),
        tool: "moolah_get_summary",
        profileID: nil,
        duration: 0,
        outcome: code
      )
    )
    let reopened = MCPAuditHistory(url: url, now: { instant })
    #expect(try await reopened.entries().first?.outcome == code)
  }

}
