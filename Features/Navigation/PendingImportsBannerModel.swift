import Foundation
import ImportExtensionKit
import Observation
import os

/// Observable model backing `PendingImportsBanner`. Reads the App Group
/// inbox on demand, classifies the contents into a `State` the view can
/// render in one switch, and forwards a tap on `Review` to the deep-link
/// sink with the newest pending payload's id.
///
/// The newest-first ordering comes from `InboxWriter.list()`, which sorts
/// by file mtime descending — so a fresh capture always wins over an
/// older "Review Later" file when the user taps the banner.
@Observable
@MainActor
final class PendingImportsBannerModel {
  enum State: Equatable {
    case none
    case one(host: String)
    case many(count: Int)
  }

  private(set) var state: State = .none

  private let writer: InboxWriter
  private let onTap: @MainActor (DeepLinkDestination) -> Void
  private var newestId: UUID?
  /// Re-entrancy guard for `refresh()`. `ContentView.task`, the scene
  /// `.onChange(of:)` hop, and any explicit refresh call can all reach
  /// here concurrently; the second arrival sees the guard and bails so
  /// the inbox isn't read twice in parallel.
  private var isRefreshing = false
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "PendingImportsBannerModel")

  init(
    writer: InboxWriter,
    onTap: @escaping @MainActor (DeepLinkDestination) -> Void = { _ in }
  ) {
    self.writer = writer
    self.onTap = onTap
  }

  func refresh() async {
    if isRefreshing { return }
    isRefreshing = true
    defer { isRefreshing = false }
    let ids: [UUID]
    do {
      ids = try writer.list()
    } catch {
      logger.error(
        "Inbox list failed: \(error.localizedDescription, privacy: .public)")
      state = .none
      newestId = nil
      return
    }
    guard !ids.isEmpty else {
      state = .none
      newestId = nil
      return
    }
    newestId = ids.first
    if ids.count == 1 {
      do {
        let payload = try writer.read(id: ids[0])
        state = .one(host: payload.sourceHost)
      } catch {
        // The bad batch is dropped from the UI until the next refresh.
        // `InboxWriter.read` quarantines on decode failure, so a second
        // refresh after recovery will see a clean inbox.
        logger.error(
          "Inbox read failed: \(error.localizedDescription, privacy: .public)")
        state = .none
        newestId = nil
      }
    } else {
      state = .many(count: ids.count)
    }
  }

  func reviewTapped() {
    guard let id = newestId else { return }
    onTap(.importInbox(id))
  }

  #if DEBUG
    /// Seed `state` directly without touching disk. Used only by
    /// `#Preview` blocks so canvas renders are deterministic.
    func previewSeed(_ state: State) { self.state = state }
  #endif
}
