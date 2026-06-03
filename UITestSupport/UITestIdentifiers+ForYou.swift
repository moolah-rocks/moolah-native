import Foundation

extension UITestIdentifiers {
  /// Accessibility identifiers for the "For You" insights panel. Shared by the
  /// SwiftUI view (`ForYouCard`) and the `ForYouScreen` UI-test driver so they
  /// never drift. Per-insight identifiers embed the (stable) insight id.
  public enum ForYou {
    public static let card = "foryou.card"

    public static func row(_ id: String) -> String { "foryou.row.\(id)" }

    /// Identifier on the "Show less" control that dismisses an insight row and
    /// bumps its per-kind fatigue penalty.
    public static func showLess(_ id: String) -> String { "foryou.showless.\(id)" }

    public static func viewButton(_ id: String) -> String { "foryou.view.\(id)" }

    /// Identifier on the single headline `Text` view for an insight row (the
    /// resolved AI line, or the detector title fallback).
    public static func headline(_ id: String) -> String { "foryou.headline.\(id)" }
  }
}
