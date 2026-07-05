import Foundation

extension UITestIdentifiers {
  // MARK: - Reports

  public enum Reports {
    /// Tappable top-level category header in the Reports category table.
    /// `id` is the root category's UUID, lowercased. Applied at the
    /// `.accessibilityElement(children: .combine)` level so the whole
    /// header row resolves as one hittable element. Keyed by UUID because
    /// the Income and Expenses tables share the same header view — a
    /// title-keyed identifier would collide across the two columns, while
    /// income and expense category ids are always distinct.
    public static func categoryHeader(_ id: UUID) -> String {
      "reports.categoryheader.\(id.uuidString.lowercased())"
    }
  }
}
