import Foundation

extension UITestIdentifiers {
  /// Accessibility identifiers for the "For You" insights panel. Shared by the
  /// SwiftUI view (`ForYouCard`) and the `ForYouScreen` UI-test driver so they
  /// never drift. Per-insight identifiers embed the (stable) insight id.
  public enum ForYou {
    public static let card = "foryou.card"

    public static func row(_ id: String) -> String { "foryou.row.\(id)" }

    public static func dismissButton(_ id: String) -> String { "foryou.dismiss.\(id)" }

    public static func viewButton(_ id: String) -> String { "foryou.view.\(id)" }
  }
}
