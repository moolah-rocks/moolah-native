import Foundation

extension InboxWriter {
  public static let appGroupIdentifier = "group.rocks.moolah.shared"

  /// Returns a writer rooted in the App Group container, or `nil` if entitlements
  /// are misconfigured (a configuration-error state, not a runtime-failure state).
  public static func shared(groupIdentifier: String = appGroupIdentifier) -> InboxWriter? {
    guard
      let url = FileManager.default
        .containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    else { return nil }
    let importRoot = url.appendingPathComponent("Import")
    return InboxWriter(rootDirectory: importRoot)
  }
}
