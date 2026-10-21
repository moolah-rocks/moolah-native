import Foundation
import Synchronization

@testable import MoolahMCP

final class MCPMemorySecrets: MCPSecretPersisting {
  struct State: Sendable {
    var data: Data?
    var failWrites = false
  }

  let state = Mutex(State())

  func readData() throws -> Data? { state.withLock { $0.data } }
  func writeData(_ data: Data) throws {
    try state.withLock {
      if $0.failWrites { throw MCPStorageFailure.unavailable }
      $0.data = data
    }
  }
}

final class MCPSecurityTestClock: Sendable {
  let tick = Mutex((wall: TimeInterval(0), monotonic: TimeInterval(0)))

  var date: Date { Date(timeIntervalSince1970: 1_700_000_000 + tick.withLock { $0.wall }) }
  var uptime: TimeInterval { tick.withLock { $0.monotonic } }

  func advanceWall(_ interval: TimeInterval) { tick.withLock { $0.wall += interval } }
  func advanceUptime(_ interval: TimeInterval) { tick.withLock { $0.monotonic += interval } }

}

actor MCPActiveQueryProbe {
  private(set) var starts = 0
  private(set) var cancellations = 0
  private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

  func run() async throws -> Int {
    starts += 1
    let ready = waiters.filter { starts >= $0.0 }
    waiters.removeAll { starts >= $0.0 }
    for (_, continuation) in ready { continuation.resume() }
    do {
      try await Task.sleep(for: .seconds(60))
      return 42
    } catch {
      cancellations += 1
      throw error
    }
  }

  func waitForStarts(_ count: Int) async {
    if starts >= count { return }
    await withCheckedContinuation { waiters.append((count, $0)) }
  }
}

actor MCPValidationGate {
  private var paused = false
  private var blocked: CheckedContinuation<Void, Never>?
  private var observer: CheckedContinuation<Void, Never>?

  func pause() async {
    paused = true
    observer?.resume()
    observer = nil
    await withCheckedContinuation { blocked = $0 }
  }

  func waitUntilPaused() async {
    if paused { return }
    await withCheckedContinuation { observer = $0 }
  }

  func resume() {
    blocked?.resume()
    blocked = nil
  }
}
