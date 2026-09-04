import Foundation

extension UITestIdentifiers {
  // MARK: - TransferDetection

  public enum TransferDetection {
    /// Sentinel for the transaction-detail transfer-suggestion banner
    /// section. `id` is the annotated transaction's UUID, lowercased.
    /// Lets a macOS UI test assert the banner is present (or absent
    /// after a merge / dismiss) without depending on the banner copy.
    public static func detailBanner(_ id: UUID) -> String {
      "transferdetection.detail.banner.\(id.uuidString.lowercased())"
    }
  }
}
