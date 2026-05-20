import Foundation
import GRDB
import Testing
import os

@testable import Moolah

// Unit tests for the retry-loop driver shared by every
// `toRetryingAsyncStream(...)` caller. We exercise the loop through
// `makeRetryingAsyncStream(makeAttempt:policy:)` — the test seam for
// `ValueObservation.toRetryingAsyncStream` — by passing a synthetic
// factory that emits canned errors. This lets
// us verify retry counting, backoff, budget exhaustion, and emission-
// resets-counter behaviour without standing up a real GRDB
// `ValueObservation` (injecting `SQLITE_FULL` into a live DB is
// non-trivial and would couple the test to SQLite VFS internals).
//
// Programmer-bug routing through the loop (SQLITE_ERROR) is NOT tested
// here because it deliberately trips `assertionFailure` in debug,
// which would crash the test runner. The predicate is verified
// directly in `AccountRepoObservationContractTests`.
@Suite("RetryingAsyncStream retry loop")
struct RetryingAsyncStreamTests {

  // Tight backoffs so tests run in ms, not seconds. Production uses
  // [1 s, 5 s, 30 s] per `DATABASE_CODE_GUIDE.md` §2 convention 5;
  // those constants are tested-by-inspection.
  private static let testBackoffs: [Duration] = [
    .milliseconds(1), .milliseconds(2), .milliseconds(4),
  ]

  // Upper bound on how long any single test will wait for its
  // retry-loop work to complete. Locally each test finishes in a few
  // ms, but CI runs the suite with ~3000 other tests competing for the
  // cooperative thread pool; a 2 s bound has been observed to trip on
  // contended runners with no actual bug present (the producer task
  // simply did not get scheduled fast enough to push 5 emissions
  // through). 30 s is 100× the worst plausible scheduler stall while
  // still failing fast on a genuine hang.
  private static let progressTimeout: Duration = .seconds(30)

  @Test("transient error triggers a restart and then emits successfully")
  func transientErrorRestarts() async throws {
    // Synthetic factory: first attempt fails immediately with
    // SQLITE_FULL; second attempt emits a single value, then suspends.
    let attemptCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
    let channel = ObservationErrorChannel()

    let stream = makeRetryingAsyncStream(
      makeAttempt: { errorSink in
        let attempt = attemptCounter.withLock { current -> Int in
          current += 1
          return current
        }
        return AsyncStream<Int> { continuation in
          if attempt == 1 {
            // First attempt: deliver SQLITE_FULL via the sink, then
            // finish so the loop reads the box and decides to retry.
            Task {
              await errorSink(
                DatabaseError(resultCode: .SQLITE_FULL, message: "test"))
              continuation.finish()
            }
          } else {
            // Second attempt: emit one value and stay open; the test
            // reads the value from the outer stream, then cancels.
            continuation.yield(42)
            // Hold the stream open by NOT finishing it; the test will
            // cancel the consumer Task to tear everything down.
          }
        }
      },
      policy: RetryingAsyncStreamPolicy(
        errorChannel: channel,
        repoMethod: "test.transientErrorRestarts",
        maxFailures: 5,
        backoffs: Self.testBackoffs))

    // Read up to one value with a generous timeout; restart + 1 ms
    // backoff should complete in well under a second. See
    // `progressTimeout` for why the bound is generous.
    let result = try await withThrowingTaskGroup(of: Int?.self) { group in
      group.addTask {
        var iterator = stream.makeAsyncIterator()
        return await iterator.next()
      }
      group.addTask {
        try await Task.sleep(for: Self.progressTimeout)
        return nil  // timeout sentinel
      }
      let first = try await group.next() ?? nil
      group.cancelAll()
      return first
    }
    #expect(result == 42, "loop should have restarted and emitted on attempt 2")

    let attemptsMade = attemptCounter.withLock { $0 }
    #expect(attemptsMade == 2, "exactly two attempts: one failure + one success")
  }

  @Test("budget exhaustion surfaces the most recent error and finishes")
  func budgetExhaustion() async throws {
    // Synthetic factory: every attempt fails with SQLITE_IOERR. After
    // `maxFailures` attempts the loop should surface the error and
    // finish without further retries.
    let attemptCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
    let channel = ObservationErrorChannel()
    let maxFailures = 3

    let stream = makeRetryingAsyncStream(
      makeAttempt: { errorSink in
        attemptCounter.withLock { $0 += 1 }
        return Self.alwaysFailingStream(
          errorSink: errorSink,
          resultCode: .SQLITE_IOERR)
      },
      policy: RetryingAsyncStreamPolicy(
        errorChannel: channel,
        repoMethod: "test.budgetExhaustion",
        maxFailures: maxFailures,
        backoffs: Self.testBackoffs))

    let done = await Self.drainUntilFinishedOrTimeout(
      stream, timeout: Self.progressTimeout)
    #expect(done, "stream should have finished within timeout")

    let attemptsMade = attemptCounter.withLock { $0 }
    #expect(
      attemptsMade == maxFailures,
      "exactly \(maxFailures) attempts before budget exhaustion (got \(attemptsMade))")

    var errorIterator = channel.stream.makeAsyncIterator()
    let surfaced = await errorIterator.next()
    #expect(surfaced != nil, "errorChannel should have received the final error")
    if let dbError = surfaced as? DatabaseError {
      #expect(dbError.resultCode == .SQLITE_IOERR)
    } else {
      Issue.record("surfaced error was not a DatabaseError")
    }
  }

  @Test("a successful emission resets the transient failure counter")
  func emissionResetsCounter() async throws {
    // Pattern across attempts (maxFailures = 3):
    //   1: emit + error  (counter resets on emit, then bumps to 1)
    //   2: emit + error  (counter resets to 0 on emit, then bumps to 1)
    //   3: emit + error  (same)
    //   4: emit + error  (same — total 4 attempts but no consecutive
    //      run of 3 errors WITHOUT an intervening emission)
    //   5: emit + error  → still under budget, four resets so far
    //
    // If reset weren't happening, we'd hit budget exhaustion at
    // attempt 3 (three consecutive errors). With reset, every attempt
    // emits a value first so the counter never accumulates above 1
    // and the loop runs as long as the consumer keeps draining.
    //
    // We collect five emissions and verify each attempt was run
    // exactly once.
    let attemptCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
    let channel = ObservationErrorChannel()

    let stream = makeRetryingAsyncStream(
      makeAttempt: { errorSink in
        let attempt = attemptCounter.withLock { current -> Int in
          current += 1
          return current
        }
        return AsyncStream<Int> { continuation in
          // Each attempt emits a value (resets counter), then errors.
          continuation.yield(attempt)
          Task {
            await errorSink(
              DatabaseError(resultCode: .SQLITE_FULL, message: "test"))
            continuation.finish()
          }
        }
      },
      policy: RetryingAsyncStreamPolicy(
        errorChannel: channel,
        repoMethod: "test.emissionResetsCounter",
        maxFailures: 3,
        backoffs: Self.testBackoffs))

    // Collect five emissions. If the counter resets correctly we'll
    // get them; if it doesn't we'd hit budget exhaustion at the third
    // failure (after three attempts). See `progressTimeout` for why
    // the bound is generous.
    let collected = try await withThrowingTaskGroup(of: [Int]?.self) { group in
      group.addTask {
        var values: [Int] = []
        for await value in stream {
          values.append(value)
          if values.count >= 5 { break }
        }
        return values
      }
      group.addTask {
        try await Task.sleep(for: Self.progressTimeout)
        return nil
      }
      let first = try await group.next() ?? nil
      group.cancelAll()
      return first ?? []
    }
    #expect(
      collected == [1, 2, 3, 4, 5], "counter should reset on each emission; got \(collected)")
  }

  @Test("consumer cancellation tears down the loop without surfacing an error")
  func consumerCancellation() async throws {
    let attemptCounter = OSAllocatedUnfairLock<Int>(initialState: 0)
    let channel = ObservationErrorChannel()

    let stream = makeRetryingAsyncStream(
      makeAttempt: { _ in
        attemptCounter.withLock { $0 += 1 }
        return AsyncStream<Int> { continuation in
          // Emit one value and stay open indefinitely.
          continuation.yield(99)
        }
      },
      policy: RetryingAsyncStreamPolicy(
        errorChannel: channel,
        repoMethod: "test.consumerCancellation",
        maxFailures: 5,
        backoffs: Self.testBackoffs))

    let task = Task {
      var iterator = stream.makeAsyncIterator()
      _ = await iterator.next()  // initial emission
      _ = await iterator.next()  // suspends — no further emissions
    }

    // Give the loop a moment to suspend on the second `next()`.
    try await Task.sleep(for: .milliseconds(20))
    task.cancel()
    _ = await task.value

    // The errorChannel should NOT have received anything: cancellation
    // is a clean shutdown, not an error.
    let pollTask = Task<(any Error)?, Never> {
      var iterator = channel.stream.makeAsyncIterator()
      return await iterator.next()
    }
    try await Task.sleep(for: .milliseconds(50))
    pollTask.cancel()
    let surfaced = await pollTask.value
    #expect(surfaced == nil, "cancellation should not surface an error")
  }

  // MARK: - Helpers

  /// Builds a one-attempt synthetic stream that delivers a single
  /// `DatabaseError` to the loop's `errorSink` and then finishes,
  /// emulating a failed observation attempt. The Task wrapper is
  /// required because `errorSink` is `async` but `AsyncStream`'s
  /// producer closure is synchronous.
  private static func alwaysFailingStream(
    errorSink: @escaping @Sendable (any Error) async -> Void,
    resultCode: ResultCode
  ) -> AsyncStream<Int> {
    AsyncStream<Int> { continuation in
      Task {
        await errorSink(DatabaseError(resultCode: resultCode, message: "test"))
        continuation.finish()
      }
    }
  }

  /// Drains the stream to completion, racing the drain against a
  /// timeout so a misbehaving loop can't hang the suite. Returns
  /// `true` if the stream completed cleanly within the deadline,
  /// `false` if the timeout fired first.
  private static func drainUntilFinishedOrTimeout(
    _ stream: AsyncStream<some Sendable>,
    timeout: Duration
  ) async -> Bool {
    await withTaskGroup(of: Bool.self) { group in
      group.addTask {
        for await _ in stream {}
        return true
      }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
  }
}
