// Features/Sync/SyncedAccountStore+Timer.swift
import Foundation

/// Hourly stale-check timer lifecycle. Split out of
/// `SyncedAccountStore+Internals.swift` (which owns the build/apply/
/// detection pipeline) to keep both files under the project's
/// `file_length` budget — timer start/stop is a distinct concern with no
/// dependency on the pipeline internals.
extension SyncedAccountStore {

  // MARK: - Timer

  /// Cancels any prior `timerTask` and starts a fresh one. Centralised
  /// so every entry point (scene-active, explicit re-arm) goes through
  /// the same cancel-then-spawn sequence.
  func restartTimer() {
    cancelTimer()
    timerTask = Task { [weak self] in
      await self?.runTimerLoop()
    }
  }

  /// Hourly stale-check loop. Foreground only — entry/exit is gated by
  /// `handleScenePhaseChange`. `Task.sleep` itself throws on cancellation;
  /// the explicit `Task.checkCancellation()` between sleep and dispatch
  /// catches a late cancellation that arrives in the gap so a cancelled
  /// task exits without leaking a fetch.
  func runTimerLoop() async {
    while !Task.isCancelled {
      do {
        try await Task.sleep(for: timerInterval)
        try Task.checkCancellation()
      } catch {
        return
      }
      await syncStaleAccounts()
    }
  }
}
