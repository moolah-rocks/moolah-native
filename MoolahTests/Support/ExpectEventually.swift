import Foundation
import Testing

@testable import Moolah

/// Polls `condition` on the `@MainActor` until it returns `true` or `timeout`
/// elapses. On timeout it records a Swift Testing issue at the call site so the
/// test fails with a clear message.
///
/// Use this to assert post-mutation store / service state instead of the
/// flake-prone "await one observation emission, then read the value once"
/// shape. A reactive store's published state can be momentarily overwritten by
/// a racing observation pass (e.g. an instrument-registry refetch) in the
/// window between the emission you awaited and the value you read — so the
/// single read occasionally sees stale state even though the steady state is
/// correct.
///
/// Polling the **exact asserted expression** closes that gap: put the entire
/// post-condition inside the closure so there is no second, unguarded read
/// afterwards. The condition runs on the `@MainActor` (it reads
/// `@MainActor`-isolated store state), and the `Task.sleep` between polls
/// yields the actor so the observation pipeline keeps making progress.
///
/// This complements — does not replace — `TestableStoreObservation`'s
/// `waitForNextEmission`: use that to assert an emission *occurs*; use this to
/// assert a *value* settles. A `condition` that throws should be wrapped in
/// `try?` by the caller (a thrown error reads as "not yet satisfied").
@MainActor
func expectEventually(
  _ description: @autoclosure () -> String = "condition to hold",
  timeout: Duration = .seconds(2),
  pollInterval: Duration = .milliseconds(20),
  sourceLocation: SourceLocation = #_sourceLocation,
  _ condition: @MainActor () async -> Bool
) async {
  let clock = ContinuousClock()
  let deadline = clock.now.advanced(by: timeout)
  while clock.now < deadline {
    if await condition() { return }
    try? await Task.sleep(for: pollInterval)
  }
  // One final check so a condition that becomes true exactly at the deadline
  // isn't reported as a spurious timeout.
  if await condition() { return }
  Issue.record(
    "expectEventually timed out after \(timeout): \(description())",
    sourceLocation: sourceLocation)
}
