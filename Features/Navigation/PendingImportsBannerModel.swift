import Foundation
import ImportExtensionKit
import Observation

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
public final class PendingImportsBannerModel {
  public enum State: Equatable {
    case none
    case one(host: String)
    case many(count: Int)
  }

  public private(set) var state: State = .none

  private let writer: InboxWriter
  private let onTap: (DeepLinkDestination) -> Void
  private var newestId: UUID?

  public init(writer: InboxWriter, onTap: @escaping (DeepLinkDestination) -> Void = { _ in }) {
    self.writer = writer
    self.onTap = onTap
  }

  public func refresh() async {
    guard let ids = try? writer.list(), !ids.isEmpty else {
      state = .none
      newestId = nil
      return
    }
    newestId = ids.first
    if ids.count == 1, let payload = try? writer.read(id: ids[0]) {
      state = .one(host: payload.sourceHost)
    } else {
      state = .many(count: ids.count)
    }
  }

  public func reviewTapped() {
    guard let id = newestId else { return }
    onTap(.importInbox(id))
  }
}
