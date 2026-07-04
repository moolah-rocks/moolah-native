// Shared/CryptoImport/RateLimiter.swift
import Foundation

/// Token-bucket rate limiter.
///
/// Shared across a provider's network calls to throttle them to its tier
/// (e.g. Alchemy, Blockscout) — `permitsPerSecond` sets the steady rate and
/// `burstCapacity` how many may fire back-to-back. The clock is injected so
/// tests can pin "now" deterministically — the live caller passes `{ Date() }`
/// and tests pass a closure backed by a counter.
///
/// Concurrency: this is an `actor`; multiple concurrent callers serialise
/// through `acquire()`. Cancellation is honoured between sleeps via
/// `Task.checkCancellation()`.
actor RateLimiter {
  private let permitsPerSecond: Double
  private let capacity: Double
  private let now: @Sendable () -> Date
  private var availablePermits: Double
  private var lastRefill: Date

  /// - Parameters:
  ///   - permitsPerSecond: Steady-state refill rate.
  ///   - burstCapacity: Maximum permits the bucket can hold, and the number
  ///     available to a freshly-constructed limiter. Governs how many calls
  ///     can fire back-to-back before throttling forces `permitsPerSecond`
  ///     spacing. Defaults to `permitsPerSecond` (a full second's worth of
  ///     burst) for callers that don't care. Pass a small value (e.g. `1`)
  ///     to strictly space calls at `1 / permitsPerSecond`, which is what
  ///     de-bursts the launch-time fan-out across many account syncs onto a
  ///     single shared limiter — otherwise every account's first request
  ///     fires simultaneously and trips the provider's per-second burst cap.
  ///   - now: Closure returning the current time. Defaults to `Date()`.
  ///     Tests inject a counter so wall-clock variance does not flake them.
  init(
    permitsPerSecond: Double,
    burstCapacity: Double? = nil,
    now: @Sendable @escaping () -> Date = { Date() }
  ) {
    precondition(permitsPerSecond > 0, "RateLimiter requires a positive permit rate")
    let capacity = burstCapacity ?? permitsPerSecond
    // `> 0` (not `>= 1`) so a sub-1 rate with a defaulted capacity stays legal
    // — there the first `acquire()` simply waits for the bucket to fill.
    precondition(capacity > 0, "RateLimiter burst capacity must be positive")
    self.permitsPerSecond = permitsPerSecond
    self.capacity = capacity
    self.availablePermits = capacity
    self.now = now
    self.lastRefill = now()
  }

  /// Awaits until at least one permit is available, then consumes it.
  ///
  /// Cancellation: throws `CancellationError` if the surrounding `Task` is
  /// cancelled while waiting, either before the first refill check or via
  /// `Task.sleep` interruption.
  func acquire() async throws {
    while true {
      try Task.checkCancellation()
      refill()
      if availablePermits >= 1 {
        availablePermits -= 1
        return
      }
      // Compute sleep duration until at least one permit is available.
      let needed = 1 - availablePermits
      let secondsToWait = needed / permitsPerSecond
      // Floor at 1ms so a near-zero deficit still yields a real sleep
      // rather than a busy loop. Convert to nanoseconds for `Task.sleep`.
      let nanos = UInt64(max(0.001, secondsToWait) * 1_000_000_000)
      try await Task.sleep(nanoseconds: nanos)
    }
  }

  /// Refills the bucket based on the time elapsed since the last refill.
  /// Capacity is bounded by `capacity`. Always called from inside
  /// the actor's isolation domain.
  private func refill() {
    let currentTime = now()
    let elapsed = currentTime.timeIntervalSince(lastRefill)
    if elapsed > 0 {
      availablePermits = min(
        capacity,
        availablePermits + elapsed * permitsPerSecond
      )
      lastRefill = currentTime
    }
  }
}
