import MCP

/// Owns the tool work because the SDK dispatches handlers in unstructured tasks.
actor MCPRequestExecution {
  private var task: Task<CallTool.Result, any Error>?
  private var isFinished = false

  func run(
    _ parameters: CallTool.Parameters,
    call: @escaping @Sendable (CallTool.Parameters) async throws -> CallTool.Result
  ) async throws -> CallTool.Result {
    guard !isFinished else { throw CancellationError() }
    let task = Task { try await call(parameters) }
    self.task = task
    return try await task.value
  }

  /// Closing the gate first prevents a delayed SDK dispatch from starting new work.
  func cancelAndWait() async {
    isFinished = true
    task?.cancel()
    do {
      _ = try await task?.value
    } catch {
      // The transport owns error reporting. Teardown must await both success and failure.
    }
    task = nil
  }
}
