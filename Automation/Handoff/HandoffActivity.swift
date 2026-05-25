import Foundation

/// Shared constants for Moolah's Handoff (`NSUserActivity`) integration.
enum HandoffActivity {
  /// The `NSUserActivity.activityType` used for all Handoff continuation
  /// between Moolah devices. Must match the entry in `NSUserActivityTypes`
  /// in `App/Info-iOS.plist` and `App/Info-macOS.plist`.
  static let continueActivityType = "com.moolah.continue"
}
