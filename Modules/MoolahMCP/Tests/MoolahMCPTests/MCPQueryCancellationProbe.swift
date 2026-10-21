import MCP

actor MCPQueryCancellationProbe {
  private var hasStarted = false
  private var startedWaiters: [CheckedContinuation<Void, Never>] = []
  private(set) var didCancel = false

  func waitUntilStarted() async {
    guard !hasStarted else { return }
    await withCheckedContinuation { startedWaiters.append($0) }
  }

  func run() async throws -> CallTool.Result {
    let (stream, continuation) = AsyncStream<Void>.makeStream()
    hasStarted = true
    for waiter in startedWaiters { waiter.resume() }
    startedWaiters.removeAll()
    for await _ in stream {}
    continuation.finish()
    didCancel = Task.isCancelled
    try Task.checkCancellation()
    return .init(content: [])
  }
}
