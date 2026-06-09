// MoolahTests/Support/SleepRecorder.swift
import Foundation
import os

/// Thread-safe recorder for the durations passed to a warmer's injected
/// `sleep` closure, so tests can assert how many cooldown gaps were waited
/// out without depending on wall-clock time.
final class SleepRecorder: @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock(initialState: [Duration]())

  func record(_ duration: Duration) {
    lock.withLock { $0.append(duration) }
  }

  var count: Int { lock.withLock { $0.count } }

  var durations: [Duration] { lock.withLock { $0 } }
}
