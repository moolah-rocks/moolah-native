import Foundation

@testable import Moolah

/// In-memory `WalletSyncCheckpointRepository` for tests and previews.
///
/// **`@unchecked Sendable` justification.** `checkpoints` is a Swift
/// `Dictionary`, not Sendable on its own. `lock` is an `NSLock` and mediates
/// every mutation and read — every method body wraps its access in
/// `lock.withLock`. No state escapes the lock; no mutation happens outside it.
/// The standard in-memory test-double pattern (locks + `@unchecked Sendable`,
/// not an `actor`, because the protocol is `async` and the method bodies are
/// synchronous-once-locked) — mirrors `InMemoryWalletSyncStateRepository`.
final class InMemoryWalletSyncCheckpointRepository:
  WalletSyncCheckpointRepository, @unchecked Sendable
{
  private let lock = NSLock()
  private var checkpoints: [UUID: WalletSyncCheckpoint] = [:]
  private(set) var saveCount = 0

  init(_ initial: [WalletSyncCheckpoint] = []) {
    for checkpoint in initial {
      checkpoints[checkpoint.id] = checkpoint
    }
  }

  func load(accountId: UUID) async throws -> WalletSyncCheckpoint? {
    lock.withLock { checkpoints[accountId] }
  }

  func save(_ checkpoint: WalletSyncCheckpoint) async throws {
    lock.withLock {
      checkpoints[checkpoint.id] = checkpoint
      saveCount += 1
    }
  }
}
