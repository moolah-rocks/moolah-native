import Foundation
import ImportExtensionKit

/// Fallback inbox used when the App Group entitlement is unavailable —
/// `--ui-testing` launches, debug sandboxing without entitlements, etc.
/// The directory is per-launch and empty, so `PendingImportsBannerModel`
/// permanently reports `.none` against it. Lives in a dedicated file so
/// the no-entitlement branch in `MoolahApp.init` reads as one line.
enum PendingImportsBannerFallback {
  static func inbox() -> InboxWriter {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pending-imports-fallback-\(UUID().uuidString)")
    return InboxWriter(rootDirectory: url)
  }
}
