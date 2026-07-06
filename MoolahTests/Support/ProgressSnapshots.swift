// MoolahTests/Support/ProgressSnapshots.swift
import Foundation

@testable import Moolah

/// Thread-safe collector for `WalletSyncProgress` snapshots captured from a
/// mid-scan chain-client hook. Used by the windowed-sync routing tests to
/// prove `SyncedAccountStore.progressPerAccount` publishes determinate
/// progress while a window is in flight. `@unchecked Sendable` with an
/// `NSLock`, matching the project's non-actor test-stub convention.
final class ProgressSnapshots: @unchecked Sendable {
  private let lock = NSLock()
  private var values: [WalletSyncProgress?] = []

  func append(_ value: WalletSyncProgress?) {
    lock.withLock { values.append(value) }
  }

  var all: [WalletSyncProgress?] {
    lock.withLock { values }
  }
}
