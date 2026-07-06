// Features/Sync/WalletSyncProgress.swift
import Foundation

/// Observable progress for a single account's in-flight wallet sync.
/// `SyncedAccountStore.progressPerAccount` publishes this per account id;
/// the windowed sync runner is the sole writer via `setSyncProgress`, and
/// the sync-button view is the reader.
///
/// `.indeterminate` covers every phase where the runner cannot yet compute
/// a fraction — e.g. before the first window's block range is known.
/// `.scanning(fraction:)` is emitted once the runner knows how many
/// windows it needs to walk to reach the chain head, so the view can show
/// a determinate bar instead of a spinner. `fraction` is expected to
/// already be clamped to `0...1` — `SyncedAccountStore.setSyncProgress`
/// (the sole write path) does the clamping so this type stays a plain
/// value.
enum WalletSyncProgress: Sendable, Equatable {
  case indeterminate
  case scanning(fraction: Double)
}
