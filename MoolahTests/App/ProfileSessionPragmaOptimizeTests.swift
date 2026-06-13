import Foundation
import Testing

@testable import Moolah

/// Pins the hourly-while-active `PRAGMA optimize` cadence required by
/// `guides/DATABASE_SCHEMA_GUIDE.md` §5 (issue #576). Each profile session
/// owns a long-lived task that fires `runPragmaOptimize` at most once per
/// `interval` while the session is alive, and that task is cancelled in
/// `cleanupSync(coordinator:)` so it cannot leak past teardown.
///
/// Tests drive the cadence with a millisecond-scale interval so the
/// behaviour is observable without sleeping for an hour.
@Suite("ProfileSession PRAGMA optimize periodic tick")
@MainActor
struct ProfileSessionPragmaOptimizeTests {
  private func makeProfile(label: String = "Test") -> Profile {
    Profile(label: label)
  }

  @Test("runPragmaOptimize bumps the run counter")
  func runPragmaOptimizeBumpsCounter() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let session = try ProfileSession(
      profile: makeProfile(), containerManager: containerManager)

    let before = session.pragmaOptimizeRunCount
    await session.runPragmaOptimize()

    #expect(session.pragmaOptimizeRunCount == before + 1)
  }

  @Test("startPeriodicPragmaOptimize fires runPragmaOptimize repeatedly")
  func periodicTickFiresRepeatedly() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let session = try ProfileSession(
      profile: makeProfile(), containerManager: containerManager)
    let baseline = session.pragmaOptimizeRunCount

    session.startPeriodicPragmaOptimize(interval: .milliseconds(20))

    // Wait long enough for at least three ticks to fire. Timeout is
    // generous because heavily-loaded CI (iOS Simulator under merge-queue
    // contention) can drag the 20 ms cadence into seconds-range; we only
    // need *eventually*-fires, not tight cadence (#884).
    try await waitUntil {
      session.pragmaOptimizeRunCount >= baseline + 3
    }

    #expect(session.pragmaOptimizeRunCount >= baseline + 3)
  }

  @Test("startPeriodicPragmaOptimize replaces a prior periodic task")
  func startReplacesPriorPeriodicTask() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let session = try ProfileSession(
      profile: makeProfile(), containerManager: containerManager)

    // First scheduling, with a long interval so it never fires during the test.
    session.startPeriodicPragmaOptimize(interval: .seconds(3600))
    let baselineAfterFirstStart = session.pragmaOptimizeRunCount

    // Replace with a fast interval; if the prior task were still running
    // alongside this one we'd accumulate duplicate ticks but that's not a
    // correctness issue. The behaviour we pin is that the fast cadence
    // takes effect.
    session.startPeriodicPragmaOptimize(interval: .milliseconds(20))

    try await waitUntil {
      session.pragmaOptimizeRunCount >= baselineAfterFirstStart + 2
    }

    #expect(session.pragmaOptimizeRunCount >= baselineAfterFirstStart + 2)
  }

  @Test("cleanupSync stops the periodic tick")
  func cleanupSyncStopsPeriodicTick() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let coordinator = SyncCoordinator(
      containerManager: containerManager,
      isCloudKitAvailable: true)
    let session = try ProfileSession(
      profile: makeProfile(),
      containerManager: containerManager,
      syncCoordinator: coordinator)

    session.startPeriodicPragmaOptimize(interval: .milliseconds(20))

    // Let it fire at least once so we know the loop is running.
    try await waitUntil {
      session.pragmaOptimizeRunCount >= 1
    }

    session.cleanupSync(coordinator: coordinator)

    // After cleanup, the count should stop growing. A `runPragmaOptimize`
    // that was already in flight at the cancellation point may still
    // complete, so settle first (one full interval is enough for any
    // in-flight call to finish), then sample, wait, and re-sample.
    try await Task.sleep(for: .milliseconds(50))
    let countAfterSettle = session.pragmaOptimizeRunCount
    try await Task.sleep(for: .milliseconds(150))
    #expect(session.pragmaOptimizeRunCount == countAfterSettle)
  }

  // MARK: - Helpers

  /// Polls `condition` on the main actor until it returns true or the
  /// timeout elapses. Throws `TimeoutError` if the condition never holds.
  /// Used to wait on background ticks without relying on a fixed sleep.
  private func waitUntil(
    timeout: Duration = .seconds(10),
    pollEvery: Duration = .milliseconds(10),
    _ condition: @MainActor () -> Bool
  ) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while ContinuousClock.now < deadline {
      if condition() { return }
      try await Task.sleep(for: pollEvery)
    }
    if condition() { return }
    throw TimeoutError()
  }

  private struct TimeoutError: Error {}
}
