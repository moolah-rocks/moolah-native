import XCTest

/// Driver for the macOS Settings scene. Returned from `MoolahApp.settings`.
///
/// The Settings scene is opened via the system Cmd+, shortcut and presents
/// a `TabView` containing the Profiles, Crypto, Import, and Rules tabs.
/// Each tab is rendered as a toolbar button labelled with its tab title;
/// tab content drivers hang off this screen (e.g. `openCryptoTab()`).
///
/// Each action method starts with `Trace.record(#function)` and waits for
/// a real post-condition before returning — see
/// `guides/UI_TEST_GUIDE.md` §3 (driver invariants).
@MainActor
struct SettingsScreen {
  let app: MoolahApp

  // MARK: - Actions

  /// Opens the Settings scene via the system Cmd+, shortcut and waits
  /// until the Settings window's tab toolbar is visible. The Profiles tab
  /// button is the post-condition because every UI-testing launch can show
  /// profile management, while specialized tabs (such as Crypto) depend on
  /// the active profile's capabilities.
  ///
  /// The lookup matches by accessibility label (the tab's title) because
  /// SwiftUI's `Tab` on macOS does not propagate
  /// `.accessibilityIdentifier(_:)` to the generated toolbar button. The
  /// label string lives in `UITestIdentifiers.TaxOwnerSettings.profilesTabTitle`
  /// so the production view and this driver share one source of truth.
  func open() {
    Trace.record(#function)
    app.pressKeyboardShortcut(",", modifiers: .command)
    let profilesTab = profilesTabButton
    if !profilesTab.waitForExistence(timeout: 10) {
      Trace.recordFailure("Settings Profiles tab toolbar button did not appear")
      XCTFail("Settings window did not appear within 10s of Cmd+,")
    }
  }

  /// Switches the Settings TabView to the Profiles tab and waits for the
  /// tax-owner management section's Add button. The active UI-test seeds
  /// boot into an open CloudKit profile, so the Add button is the narrow
  /// sentinel proving the Profiles detail pane has a live `TaxOwnerStore`.
  func openProfilesTab() {
    Trace.record(#function)
    let tab = profilesTabButton
    if !tab.waitForExistence(timeout: 10) {
      Trace.recordFailure("Settings Profiles tab toolbar button did not appear")
      XCTFail("Profiles tab toolbar button did not appear within 10s")
      return
    }
    tab.click()
    let addButton = app.element(for: UITestIdentifiers.TaxOwnerSettings.addButton)
    if !addButton.waitForExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.add did not appear after Profiles tab click")
      XCTFail("Tax Owners section did not appear within 10s of opening Profiles Settings")
    }
  }

  /// Switches the Settings TabView to the Crypto tab and waits for the
  /// `CryptoSettingsView`'s root container to appear in the accessibility
  /// tree.
  func openCryptoTab() {
    Trace.record(#function)
    let tab = cryptoTabButton
    if !tab.waitForExistence(timeout: 10) {
      Trace.recordFailure("Settings Crypto tab toolbar button did not appear")
      XCTFail("Crypto tab toolbar button did not appear within 10s")
      return
    }
    tab.click()
    let container = app.element(for: UITestIdentifiers.CryptoSettings.container)
    if !container.waitForExistence(timeout: 10) {
      Trace.recordFailure("crypto.settings.container did not appear after tab click")
      XCTFail("CryptoSettingsView container did not appear within 10s of tab click")
    }
  }

  // MARK: - Helpers

  /// The Settings TabView's Profiles tab toolbar button, located by its
  /// accessibility label (the title of the `Tab`). See `open()` for why
  /// this driver uses label matching rather than `app.element(for:)`.
  /// The lookup routes through `MoolahApp.toolbarButton(label:)` so the
  /// single-resolver invariant (UI_TEST_GUIDE §3 #5) is preserved.
  private var profilesTabButton: XCUIElement {
    app.toolbarButton(label: UITestIdentifiers.TaxOwnerSettings.profilesTabTitle)
  }

  /// The Settings TabView's Crypto tab toolbar button, located by its
  /// accessibility label (the title of the `Tab`). See `open()` for why
  /// this driver uses label matching rather than `app.element(for:)`.
  /// The lookup routes through `MoolahApp.toolbarButton(label:)` so the
  /// single-resolver invariant (UI_TEST_GUIDE §3 #5) is preserved.
  private var cryptoTabButton: XCUIElement {
    app.toolbarButton(label: UITestIdentifiers.Settings.cryptoTabTitle)
  }
}
