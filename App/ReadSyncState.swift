import Foundation

/// App-wide iCloud progress, observed separately from a financial database snapshot.
/// This describes this Mac's sync engine; it cannot attest to another device's uploads.
enum ReadSyncState: String, Sendable, CaseIterable {
  case unknown
  case connecting
  case receiving
  case sending
  case syncing
  case upToDate = "up_to_date"
  case storageFull = "storage_full"
  case unavailable
  case retrying

  @MainActor
  init(progress: SyncProgress?) {
    guard let progress else {
      self = .unknown
      return
    }
    switch progress.phase {
    case .idle, .connecting: self = .connecting
    case .receiving: self = .receiving
    case .sending: self = .sending
    case .syncing: self = .syncing
    case .upToDate: self = .upToDate
    case .degraded(.quotaExceeded): self = .storageFull
    case .degraded(.iCloudUnavailable): self = .unavailable
    case .degraded(.retrying): self = .retrying
    }
  }

  var title: String {
    switch self {
    case .unknown: "Sync status unavailable"
    case .connecting: "Connecting…"
    case .receiving: "Receiving from iCloud"
    case .sending: "Sending to iCloud"
    case .syncing: "Syncing with iCloud"
    case .upToDate: "Up to date"
    case .storageFull: "iCloud storage full"
    case .unavailable: "iCloud unavailable"
    case .retrying: "Retrying"
    }
  }
}

extension SessionManager {
  var readSyncState: ReadSyncState {
    ReadSyncState(progress: syncCoordinator?.progress)
  }
}
