import Foundation
import ImportExtensionKit

/// Fallback inbox used when the App Group entitlement is unavailable
/// and no UI-test override is set — Debug builds with no entitlement,
/// debug sandboxing without the App Group capability, etc. The
/// directory is per-launch and empty, so `PendingImportsBannerModel`
/// permanently reports `.none` against it. Lives in a dedicated file so
/// the no-entitlement branch in `MoolahApp.init` reads as one line.
///
/// The UI-test override (`UITestEnvironment.inboxDirectory`) is
/// resolved one layer up in `MoolahApp+Setup.resolveInboxWriter` so
/// the same path can be threaded into both the banner's read writer and
/// the deep-link coordinator's drain writer.
enum PendingImportsBannerFallback {
  static func inbox() -> InboxWriter {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pending-imports-fallback-\(UUID().uuidString)")
    return InboxWriter(rootDirectory: url)
  }
}
