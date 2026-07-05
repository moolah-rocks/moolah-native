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
  private(set) var raiseToMaxCount = 0

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

  /// Mirrors the real repository's atomic read-compare-write: holds the lock
  /// across the whole compare-then-set so no interleaved `save`/`raiseToMax`
  /// call can observe a torn state, and only bumps when the new value is
  /// strictly greater than what's stored (or nothing is stored yet).
  func raiseToMax(accountId: UUID, blockNumber: UInt64) async throws {
    lock.withLock {
      guard let existing = checkpoints[accountId] else {
        checkpoints[accountId] = WalletSyncCheckpoint(
          id: accountId, lastSyncedBlockNumber: blockNumber)
        raiseToMaxCount += 1
        return
      }
      guard blockNumber > existing.lastSyncedBlockNumber else { return }
      checkpoints[accountId] = WalletSyncCheckpoint(
        id: accountId, lastSyncedBlockNumber: blockNumber)
      raiseToMaxCount += 1
    }
  }
}
