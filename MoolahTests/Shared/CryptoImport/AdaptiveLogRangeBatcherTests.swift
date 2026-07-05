// MoolahTests/Shared/CryptoImport/AdaptiveLogRangeBatcherTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("AdaptiveLogRangeBatcher")
struct AdaptiveLogRangeBatcherTests {
  /// Records every `(from, to)` pair the fake `fetch` closure observed, and
  /// which of those calls the fake let succeed. Guarded by a lock so
  /// concurrent-looking Swift Concurrency code still records safely even
  /// though `run` is expected to call `fetch` serially.
  private final class CallLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var allCalls: [(from: UInt64, to: UInt64)] = []
    private(set) var successfulCalls: [(from: UInt64, to: UInt64)] = []

    func recordAttempt(from: UInt64, to: UInt64) {
      lock.lock()
      defer { lock.unlock() }
      allCalls.append((from, to))
    }

    func recordSuccess(from: UInt64, to: UInt64) {
      lock.lock()
      defer { lock.unlock() }
      successfulCalls.append((from, to))
    }
  }

  /// A lock-guarded mutable flag, for fakes that need to remember "have I
  /// already failed once?" across calls from a `@Sendable` closure.
  private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = false

    var value: Bool {
      get {
        lock.lock()
        defer { lock.unlock() }
        return storage
      }
      set {
        lock.lock()
        defer { lock.unlock() }
        storage = newValue
      }
    }
  }

  /// A lock-guarded call counter, for fakes that need to count invocations
  /// from a `@Sendable` closure.
  private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return storage
    }

    func increment() {
      lock.lock()
      defer { lock.unlock() }
      storage += 1
    }
  }

  /// Every successful `(from, to)` chunk, sorted ascending, must tile the
  /// whole `[from, to]` range with no gaps and no overlaps: each chunk's
  /// `from` must be exactly one past the previous chunk's `to`.
  private func assertContiguousCoverage(
    _ chunks: [(from: UInt64, to: UInt64)],
    from: UInt64,
    to: UInt64
  ) {
    let sorted = chunks.sorted { $0.from < $1.from }
    #expect(sorted.first?.from == from)
    #expect(sorted.last?.to == to)
    for index in 1..<sorted.count {
      #expect(sorted[index].from == sorted[index - 1].to + 1)
    }
  }

  @Test
  func halvesUntilChunksFitBeneathAnImplicitRangeLimit() async throws {
    let log = CallLog()
    let batcher = AdaptiveLogRangeBatcher()

    // The fake treats any chunk spanning more than 2000 blocks as "too
    // large" — mirroring a provider's undocumented eth_getLogs range cap.
    // The batcher must never be told this threshold; it only sees the
    // thrown error and halves in response.
    let results = try await batcher.run(from: 0, to: 10_000) { chunkFrom, chunkTo in
      log.recordAttempt(from: chunkFrom, to: chunkTo)
      if chunkTo - chunkFrom > 2_000 {
        throw RangeTooLargeError()
      }
      log.recordSuccess(from: chunkFrom, to: chunkTo)
      // One synthetic result per block so completeness is checkable via count.
      return Array(chunkFrom...chunkTo)
    }

    assertContiguousCoverage(log.successfulCalls, from: 0, to: 10_000)
    #expect(results == Array(UInt64(0)...10_000))
  }

  @Test
  func recoversFromASingleTimeoutByHalvingThenGrowingBack() async throws {
    let log = CallLog()
    let batcher = AdaptiveLogRangeBatcher()
    let hasTimedOutOnce = LockedFlag()

    let results = try await batcher.run(from: 0, to: 10_000) { chunkFrom, chunkTo in
      log.recordAttempt(from: chunkFrom, to: chunkTo)
      // Simulate the very first (maximal, 10k-wide) attempt timing out
      // exactly once; every other chunk — including the halved retry —
      // succeeds.
      if !hasTimedOutOnce.value, chunkTo - chunkFrom == 9_999 {
        hasTimedOutOnce.value = true
        throw URLError(.timedOut)
      }
      log.recordSuccess(from: chunkFrom, to: chunkTo)
      return Array(chunkFrom...chunkTo)
    }

    #expect(hasTimedOutOnce.value)
    assertContiguousCoverage(log.successfulCalls, from: 0, to: 10_000)
    #expect(results == Array(UInt64(0)...10_000))
    // Confirms the retry after the timeout used a halved (5000-wide) chunk,
    // not a re-attempt at the same 10k width.
    #expect(log.allCalls.contains { $0.from == 0 && $0.to == 4_999 })
  }

  @Test
  func propagatesAnErrorThatPersistsDownToTheRangeFloor() async throws {
    let batcher = AdaptiveLogRangeBatcher(maxRange: 10_000, minRange: 1)
    let attempts = LockedCounter()

    await #expect(throws: PersistentProviderError.self) {
      _ = try await batcher.run(from: 0, to: 10_000) { _, _ -> [Int] in
        attempts.increment()
        throw PersistentProviderError()
      }
    }
    // The failing fetch must actually have been retried all the way down
    // to a single-block chunk before the error was allowed to propagate —
    // otherwise this test would pass even if `run` gave up early.
    #expect(attempts.value > 1)
  }

  @Test
  func cancellationPropagatesImmediatelyWithoutBeingTreatedAsARangeFailure() async throws {
    let batcher = AdaptiveLogRangeBatcher()
    let attempts = LockedCounter()

    let task = Task {
      try await batcher.run(from: 0, to: 10_000) { _, _ -> [Int] in
        attempts.increment()
        throw CancellationError()
      }
    }
    task.cancel()

    await #expect(throws: CancellationError.self) {
      _ = try await task.value
    }
    // A cancellation must not be mistaken for "range too large": the
    // batcher must not halve and retry, it must propagate on the first
    // observed CancellationError.
    #expect(attempts.value == 1)
  }

  private struct RangeTooLargeError: Error {}
  private struct PersistentProviderError: Error {}
}
