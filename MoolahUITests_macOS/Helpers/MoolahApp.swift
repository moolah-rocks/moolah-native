import XCTest

/// Driver entrypoint for UI tests. Owns the underlying `XCUIApplication`,
/// launches it with the `--ui-testing` argument and the chosen seed, and
/// exposes typed screen drivers as properties.
///
/// Tests interact with the app **only** through this type and the screen
/// drivers it returns — never `XCUIElement` or `XCUIApplication` directly.
/// See `guides/UI_TEST_GUIDE.md` §2 (the screen-driver rule).
@MainActor
final class MoolahApp {
  let application: XCUIApplication
  let seed: UITestSeed
  /// On-disk directory the app's fallback inbox is rooted at for this
  /// launch — mirrored from the `UITestEnvironment.inboxDirectory`
  /// `launchEnvironment` value so drivers can poll the same path the
  /// app reads / writes (the test process does not inherit
  /// `launchEnvironment`, hence the explicit hand-off). Drivers that
  /// don't touch the inbox simply ignore it.
  let inboxDirectory: URL
  /// Back-reference set by `MoolahUITestCase.launch(seed:)` so drivers can
  /// request an immediate failure snapshot via
  /// `app.testCase?.captureFailureSnapshot(reason:)` before calling
  /// `XCTFail` — useful when a click silently misses the target and the
  /// regular `tearDown` snapshot fires too late to show what was on
  /// screen at the click.
  weak var testCase: MoolahUITestCase?

  /// The standard launch entrypoint used by tests:
  ///
  ///   let app = MoolahApp.launch(seed: .tradeBaseline)
  ///
  /// Always pair with `MoolahApp` returned to a local — never store on the
  /// test class. The application is terminated automatically by
  /// `MoolahUITestCase.tearDown`.
  ///
  /// Always exports `UITestEnvironment.inboxDirectory` to a per-launch
  /// temp directory so seeds that pre-write inbox files (e.g.
  /// `.pendingWebImportOneChaseInbox`) and the app's fallback inbox
  /// agree on the same on-disk path. Seeds that never read the inbox
  /// simply inherit an empty directory and ignore it.
  static func launch(seed: UITestSeed) -> MoolahApp {
    let application = XCUIApplication()
    application.launchArguments = ["--ui-testing"]
    // Use the shared `/private/tmp` rather than `FileManager.default
    // .temporaryDirectory`, which resolves into the xctrunner's
    // sandboxed Container path. The AUT (`rocks.moolah.app`,
    // unsandboxed in Debug-Tests) cannot read from another app's
    // container even without its own sandbox — TCC blocks access. A
    // path under `/private/tmp` is world-accessible and both
    // processes can read/write it.
    let inboxDirectory = URL(fileURLWithPath: "/private/tmp")
      .appendingPathComponent("moolah-ui-test-inbox-\(UUID().uuidString)")
    application.launchEnvironment = [
      "UI_TESTING_SEED": seed.rawValue,
      UITestEnvironment.inboxDirectory: inboxDirectory.path,
    ]
    application.launch()
    let app = MoolahApp(
      application: application, seed: seed, inboxDirectory: inboxDirectory)
    app.expectMainWindowVisible()
    return app
  }

  init(application: XCUIApplication, seed: UITestSeed, inboxDirectory: URL) {
    self.application = application
    self.seed = seed
    self.inboxDirectory = inboxDirectory
  }

  // MARK: - Screen drivers

  /// Sidebar containing accounts, named views, and earmarks.
  var sidebar: SidebarScreen { SidebarScreen(app: self) }

  /// First-run `WelcomeView` state machine (hero / form / picker).
  var welcome: WelcomeScreen { WelcomeScreen(app: self) }

  /// Centre column listing transactions for the current sidebar selection.
  var transactionList: TransactionListScreen { TransactionListScreen(app: self) }

  /// Recently Added landing page (`RecentlyAddedView`): imported-row
  /// list with the passive transfer pill and the row context-menu
  /// merge / dismiss actions.
  var recentlyAdded: RecentlyAddedScreen { RecentlyAddedScreen(app: self) }

  /// "For You" insights panel (`ForYouCard`): the first card in the
  /// Analysis detail leaf. Row expand / dismiss / deep-link actions.
  var forYou: ForYouScreen { ForYouScreen(app: self) }

  /// Right column or sheet showing a single transaction's editable detail.
  var transactionDetail: TransactionDetailScreen { TransactionDetailScreen(app: self) }

  /// System dialogs (alerts, delete confirmations, error sheets).
  var dialogs: DialogScreen { DialogScreen(app: self) }

  /// First-run hero surface (`WelcomeHero`). Available when the app is in
  /// a welcome / first-run state (no active profile yet).
  var welcomeHero: WelcomeHeroScreen { WelcomeHeroScreen(app: self) }

  /// Sidebar sync-progress footer (`SyncProgressFooter`). Available when a
  /// profile is active and the sidebar is visible.
  var syncFooter: SyncFooterScreen { SyncFooterScreen(app: self) }

  /// `CreateAccountView` sheet. Open it by calling `createAccount.open(...)`.
  var createAccount: CreateAccountScreen { CreateAccountScreen(app: self) }

  /// `EditAccountView` sheet. Open it by right-clicking an account row in
  /// the sidebar and choosing "Edit Account…", or programmatically via
  /// `editAccount.open(account:)`.
  var editAccount: EditAccountScreen { EditAccountScreen(app: self) }

  /// macOS Settings scene. Open it via `settings.open()`; tab drivers
  /// (e.g. `settings.openCryptoTab()`) hang off the returned screen.
  var settings: SettingsScreen { SettingsScreen(app: self) }

  /// Crypto tab of the Settings scene (`CryptoSettingsView`). Available
  /// after `settings.openCryptoTab()` has selected the tab.
  var cryptoSettings: CryptoSettingsScreen { CryptoSettingsScreen(app: self) }

  /// `AddTokenSheet` (the crypto-only `InstrumentPickerSheet`). Available
  /// after `cryptoSettings.tapAddToken()` has presented the sheet.
  var addToken: AddTokenScreen { AddTokenScreen(app: self) }

  /// `IncompatibleProfileView`. Reachable from the multi-profile picker
  /// when the selected profile's `dataFormatVersion` exceeds the
  /// build's `DataFormatVersion.current`.
  var incompatibleProfile: IncompatibleProfileScreen {
    IncompatibleProfileScreen(app: self)
  }

  /// In-window banner that surfaces unconsumed inbox payloads from the
  /// Safari import extension (`PendingImportsBanner`). Available on
  /// every main-window launch — renders to `EmptyView` when the inbox
  /// is empty.
  var pendingImportsBanner: PendingImportsBannerScreen {
    PendingImportsBannerScreen(app: self)
  }

  // MARK: - Single element resolver

  /// All identifier lookups in the driver layer go through this method, by
  /// rule. One place to add logging, change resolution strategy, or
  /// future-proof the lookup mechanism.
  func element(for identifier: String) -> XCUIElement {
    application.descendants(matching: .any).matching(identifier: identifier).firstMatch
  }

  /// Toolbar-button-by-label resolver. Used by drivers when SwiftUI
  /// drops `.accessibilityIdentifier(_:)` on the underlying control —
  /// macOS Settings `Tab(...)` toolbar buttons are the current case. The
  /// `label` argument should still be a typed constant from
  /// `UITestIdentifiers` so drivers stay free of raw English literals.
  /// All such lookups route through this method so the single-resolver
  /// invariant (UI_TEST_GUIDE §3 #5) is preserved.
  func toolbarButton(label: String) -> XCUIElement {
    application.toolbars.buttons[label]
  }

  /// Menu-item-by-label resolver. Used by drivers when SwiftUI drops
  /// `.accessibilityIdentifier(_:)` on the underlying control — context
  /// menus and macOS Picker pop-ups are the current cases (NSMenuItem
  /// doesn't inherit the SwiftUI identifier). All such lookups route
  /// through this method so the single-resolver invariant is preserved.
  func menuItem(label: String) -> XCUIElement {
    application.menuItems[label]
  }

  // MARK: - Predicate-based escape hatches
  //
  // ui-test-review: allow single-resolver — predicate-based matching is
  // required when a driver needs to count or scan a *family* of elements
  // sharing an identifier prefix (e.g. `welcome.picker.row.<uuid>`) or
  // matching a label substring (e.g. accessibility-combined trade rows).
  // Routing those lookups through narrow helpers here keeps the driver
  // layer free of direct `application.<query>` references and preserves
  // the single-resolver invariant: every identifier touch in a driver
  // still goes through `MoolahApp`.

  /// Predicate-matched button query. Use when a driver needs to count
  /// or enumerate buttons sharing an identifier prefix — the only
  /// supported escape hatch from `element(for:)`. Pass an
  /// `UITestIdentifiers` prefix constant, never an inline literal.
  func buttons(matching predicate: NSPredicate) -> [XCUIElement] {
    application.buttons.matching(predicate).allElementsBoundByIndex
  }

  /// Predicate-matched static-text query. Use when waiting on a row
  /// whose accessibility label is composed at render time (e.g. a
  /// transaction row whose label combines payee + amount + date) and
  /// no stable identifier exists for it.
  func staticTexts(matching predicate: NSPredicate) -> [XCUIElement] {
    application.staticTexts.matching(predicate).allElementsBoundByIndex
  }

  /// Predicate-matched cell query. Same rationale as `staticTexts`,
  /// for views that surface as cells in the accessibility tree
  /// (List rows on iOS / cell-style List items on macOS).
  func cells(matching predicate: NSPredicate) -> [XCUIElement] {
    application.cells.matching(predicate).allElementsBoundByIndex
  }

  /// First popover element in the application — used by drivers to wait
  /// for an NSPopover's host NSWindow to finish its close animation.
  /// On macOS a SwiftUI `.popover(...)` is hosted in a separate NSWindow
  /// whose teardown lags behind the SwiftUI sheet view's accessibility
  /// unmount: `application.popovers.firstMatch.exists` returns `false`
  /// only once the host NSWindow has fully closed, which is the
  /// deterministic signal that residual modal state cannot
  /// block hit-testing on the parent window. Routing the lookup
  /// through here preserves the single-resolver invariant
  /// (UI_TEST_GUIDE §3 #5).
  ///
  /// `firstMatch` is sufficient when at most one popover is open at a
  /// time. A future flow that presents nested popovers should wait on
  /// `application.popovers.count == 0` via a predicate instead.
  var popover: XCUIElement { application.popovers.firstMatch }

  /// Keyboard shortcut entrypoint for drivers. Drivers must route keyboard
  /// events through this method rather than reaching into `application`
  /// directly — the single seam keeps `MoolahApp` as the only surface the
  /// driver layer talks to (mirrors `element(for:)`).
  func pressKeyboardShortcut(_ key: String, modifiers: XCUIElement.KeyModifierFlags = []) {
    application.typeKey(key, modifierFlags: modifiers)
  }

  // MARK: - Helpers used by drivers and `MoolahUITestCase`

  /// Bounded wait for an element with the given identifier to exist. Used
  /// by drivers and by `MoolahUITestCase.waitForIdentifier(_:timeout:)`.
  /// Default 3 s — see `guides/UI_TEST_GUIDE.md` §3 invariant 1.
  @discardableResult
  func waitForElement(identifier: String, timeout: TimeInterval = 3) -> Bool {
    element(for: identifier).waitForExistence(timeout: timeout)
  }

  /// Waits up to `timeout` seconds for the main profile window to appear,
  /// then ensures the app is the foreground process so subsequent
  /// keyboard / focus assertions reflect a real interactive session
  /// (the launcher → profile-window handoff under `--ui-testing` can
  /// briefly hand activation back to the test runner).
  /// Called automatically from `launch(seed:)`; drivers reuse it after
  /// actions that re-create the window.
  ///
  /// The 30 s default is the standard CI-friendly waiting budget — GitHub-
  /// hosted macos-26 runners are slow on cold start, often taking 15 s+
  /// before SwiftUI's launcher → profile-window handoff completes (issue
  /// #493). The deterministic part of the fix is in
  /// `UITestingLauncherView`: keeping the launcher around eliminates the
  /// open/dismiss race that can leave the app windowless. This timeout
  /// is then the upper bound on launch-plus-render, not on a race
  /// recovery window.
  func expectMainWindowVisible(timeout: TimeInterval = 30) {
    if !application.windows.firstMatch.waitForExistence(timeout: timeout) {
      Trace.recordFailure("main window did not appear within \(timeout)s")
      XCTFail("Moolah main window did not appear within \(timeout)s of launch")
      return
    }
    application.activate()
  }
}
