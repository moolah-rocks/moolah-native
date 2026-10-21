import Foundation
import MoolahMCP

/// Device-local metadata, bounded to seven days and 1,000 calls. Operations serialize before
/// off-caller file transactions, so actor reentrancy cannot lose concurrent audit appends.
actor MCPAuditHistory {
  private let file: MCPAuditFile
  private var operationTask: Task<[MCPAuditEvent], any Error>?
  private var operationID: UUID?

  init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    file = MCPAuditFile(url: url, now: now)
  }

  func entries() async throws -> [MCPAuditEvent] { try await transact(.read) }
  func append(_ event: MCPAuditEvent) async throws { _ = try await transact(.append(event)) }
  func clear() async throws { _ = try await transact(.clear) }

  private func transact(_ action: MCPAuditFile.Action) async throws -> [MCPAuditEvent] {
    let predecessor = operationTask
    let file = file
    let id = UUID()
    let task = Task {
      _ = await predecessor?.result
      try Task.checkCancellation()
      return try await file.apply(action)
    }
    operationTask = task
    operationID = id
    defer {
      if operationID == id {
        operationTask = nil
        operationID = nil
      }
    }
    return try await withTaskCancellationHandler {
      try await task.value
    } onCancel: {
      task.cancel()
    }
  }
}
