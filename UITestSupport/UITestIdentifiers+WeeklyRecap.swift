import Foundation

extension UITestIdentifiers {
  /// Accessibility identifiers for the weekly recap card. Shared by the
  /// SwiftUI view (`WeeklyRecapCard`) and the `WeeklyRecapScreen` UI-test
  /// driver so they never drift (issue #1042).
  public enum WeeklyRecap {
    /// The recap card container (or its header text for stable identification).
    public static let card = "weeklyRecap.card"

    /// The dismiss button that hides the recap card.
    public static let dismiss = "weeklyRecap.dismiss"
  }
}
