import Foundation

extension UITestIdentifiers {
  // MARK: - TaxOwnerSettings

  public enum TaxOwnerSettings {
    /// Title of the Profiles tab in the macOS Settings TabView. SwiftUI's
    /// `Tab` toolbar item does not carry a stable accessibility identifier on
    /// macOS, so the Settings driver resolves it by this shared label.
    public static let profilesTabTitle = "Profiles"

    /// Profile-detail Form that contains the Tax Owners Settings section.
    /// Drivers use it only as the scroll surface when the section renders
    /// below the visible Settings window on CI.
    public static let container = "settings.taxOwner.container"

    public static func actionsButtonLabel(ownerName: String) -> String {
      "Actions for \(ownerName)"
    }

    public static func defaultBadgeLabel(ownerName: String) -> String {
      "\(ownerName) default tax owner"
    }

    /// Adds a new tax owner from the Tax Owners section.
    public static let addButton = "settings.taxOwner.add"

    /// Name field shared by Add Tax Owner and Rename Tax Owner sheets.
    public static let editNameField = "settings.taxOwner.edit.name"

    /// Confirmation toolbar button shared by Add ("Add") and Rename ("Save") sheets.
    public static let editConfirmButton = "settings.taxOwner.edit.confirm"

    /// Replacement picker in the Delete Default Owner sheet.
    public static let replacementPicker = "settings.taxOwner.deleteDefault.replacement"

    /// Destructive confirmation toolbar button in the Delete Default Owner sheet.
    public static let deleteDefaultConfirmButton = "settings.taxOwner.deleteDefault.confirm"

    /// Settings owner menu item labels. Native macOS menu items do not inherit
    /// SwiftUI accessibility identifiers, so the driver resolves them by label
    /// through `MoolahApp.menuItem(label:)`.
    public static let setAsDefaultMenuTitle = "Set as Default"
    public static let renameMenuTitle = "Rename…"
    public static let deleteMenuTitle = "Delete…"
  }
}
