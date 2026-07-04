// MoolahTests/Shared/CryptoImport/RateLimiterTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("RateLimiter")
struct RateLimiterTests {
  /// Test clock: a `Sendable` closure backed by a `Mutex` so the test can
  /// pin "now" deterministically. `RateLimiter`'s constructor and `refill`
  /// only ever call the closure inside the actor, so a single shared
  /// reference under a lock is safe and adequate here.
  private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var currentTime: Date

    init(start: Date) { self.currentTime = start }

    func now() -> Date {
      lock.lock()
      defer { lock.unlock() }
      return currentTime
    }

    func advance(by seconds: TimeInterval) {
      lock.lock()
      defer { lock.unlock() }
      currentTime = currentTime.addingTimeInterval(seconds)
    }
  }

  @Test
  func fullBucketAllowsBurstWithoutWaiting() async throws {
    let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
    let limiter = RateLimiter(permitsPerSecond: 25) { clock.now() }

    // 25 acquires must complete with no advancement of the clock. If the
    // limiter required wall-clock time we'd hang the test runner; we
    // bound the assertion with a timeout via `withTimeout`.
    try await withTimeout(seconds: 1) {
      for _ in 0..<25 {
        try await limiter.acquire()
      }
    }
  }

  @Test
  func twentySixthAcquireWaitsForRefill() async throws {
    let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
    let limiter = RateLimiter(permitsPerSecond: 25) { clock.now() }

    // Burn the bucket.
    for _ in 0..<25 {
      try await limiter.acquire()
    }

    // Start a 26th acquire in a child task; it should still be running
    // because the clock has not advanced.
    let task = Task { try await limiter.acquire() }

    // Yield enough times for the limiter to enter its sleep loop. Without
    // advancing the clock, the actor must not return.
    for _ in 0..<5 {
      await Task.yield()
    }
    #expect(task.isCancelled == false)
    // The task is still in flight (not yet completed) — we can verify
    // by checking it hasn't published a result. There's no public API
    // for that; cancel and check the cancellation propagates instead.
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test
  func cancelledAcquireThrowsCancellationError() async throws {
    let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
    let limiter = RateLimiter(permitsPerSecond: 25) { clock.now() }

    for _ in 0..<25 {
      try await limiter.acquire()
    }
    let task = Task { try await limiter.acquire() }
    // Allow the task to enter the sleep loop, then cancel.
    for _ in 0..<3 {
      await Task.yield()
    }
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test
  func bucketRefillsOverTime() async throws {
    let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
    let limiter = RateLimiter(permitsPerSecond: 25) { clock.now() }

    // Burn the bucket.
    for _ in 0..<25 {
      try await limiter.acquire()
    }
    // Advance one second — that should refill the entire bucket.
    clock.advance(by: 1.0)
    try await withTimeout(seconds: 1) {
      for _ in 0..<25 {
        try await limiter.acquire()
      }
    }
  }

  @Test
  func burstCapacityCapsTheInitialBurstBelowTheRefillRate() async throws {
    let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
    // High refill rate but a burst capacity of 1: only one call may fire
    // before throttling forces spacing, regardless of `permitsPerSecond`.
    // This is the launch-time de-burst that stops every account's first
    // request firing simultaneously onto one shared limiter.
    let limiter = RateLimiter(permitsPerSecond: 25, burstCapacity: 1) { clock.now() }

    // The single burst permit is consumed with no clock advance…
    try await withTimeout(seconds: 1) {
      try await limiter.acquire()
    }

    // …and the very next acquire must wait, because the bucket is empty and
    // the clock has not advanced to refill it.
    let task = Task { try await limiter.acquire() }
    for _ in 0..<5 {
      await Task.yield()
    }
    #expect(task.isCancelled == false)
    task.cancel()
    await #expect(throws: CancellationError.self) {
      try await task.value
    }
  }

  @Test
  func burstCapacityRefillsAtPermitsPerSecondNotCapacity() async throws {
    let clock = TestClock(start: Date(timeIntervalSince1970: 1_000_000))
    let limiter = RateLimiter(permitsPerSecond: 10, burstCapacity: 1) { clock.now() }

    // Burn the single permit.
    try await limiter.acquire()
    // At 10 permits/sec, 0.1s refills exactly one — spacing is 1 / rate,
    // decoupled from the burst capacity.
    clock.advance(by: 0.1)
    try await withTimeout(seconds: 1) {
      try await limiter.acquire()
    }
  }
}

// MARK: - Test helpers

/// Runs `body` and traps if it does not return within `seconds`. Used to
/// guarantee that "no-wait" assertions do not hang the test runner if the
/// implementation regresses to a real wait.
private func withTimeout<T: Sendable>(
  seconds: TimeInterval,
  body: @Sendable @escaping () async throws -> T
) async throws -> T {
  try await withThrowingTaskGroup(of: T.self) { group in
    group.addTask { try await body() }
    group.addTask {
      try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
      throw TimeoutError()
    }
    guard let value = try await group.next() else {
      throw TimeoutError()
    }
    group.cancelAll()
    return value
  }
}

private struct TimeoutError: Error {}
