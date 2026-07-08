import XCTest

/// Targeted Settings UI coverage for issue #1271 tax-owner management.
/// Store/repository tests already cover the domain edge cases; these tests
/// defend the rendered SwiftUI Settings flow and its sheet/menu wiring.
@MainActor
final class TaxOwnerManagementUITests: MoolahUITestCase {
  private static let initialOwner = "Default owner"
  private static let renamedOwner = "Alex"
  private static let addedOwner = "Jordan"

  func testSoleDefaultTaxOwnerCanBeRenamedInSettings() {
    let app = launch(seed: .tradeBaseline)

    app.settings.open()
    app.settings.openProfilesTab()
    app.taxOwnerSettings.expectOwnerVisible(Self.initialOwner)
    app.taxOwnerSettings.expectDefaultOwner(Self.initialOwner)

    app.taxOwnerSettings.renameOwner(Self.initialOwner, to: Self.renamedOwner)

    app.taxOwnerSettings.expectOwnerVisible(Self.renamedOwner)
    app.taxOwnerSettings.expectDefaultOwner(Self.renamedOwner)
    app.taxOwnerSettings.expectOwnerAbsent(Self.initialOwner)
  }

  func testManagingOwnersFromSettingsRequiresReplacementWhenDeletingDefault() {
    let app = launch(seed: .tradeBaseline)

    app.settings.open()
    app.settings.openProfilesTab()
    app.taxOwnerSettings.addOwner(named: Self.addedOwner)
    app.taxOwnerSettings.setDefaultOwner(Self.addedOwner)
    app.taxOwnerSettings.setDefaultOwner(Self.initialOwner)

    app.taxOwnerSettings.deleteDefaultOwner(
      Self.initialOwner,
      replacementName: Self.addedOwner)

    app.taxOwnerSettings.expectOwnerAbsent(Self.initialOwner)
    app.taxOwnerSettings.expectDefaultOwner(Self.addedOwner)
  }
}
