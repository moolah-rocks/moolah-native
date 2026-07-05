import XCTest

/// Driver for the first-run `WelcomeView` state machine. Returned from
/// `MoolahApp.welcome`. Covers hero, create-profile form, and the
/// multi-profile picker. Per `guides/UI_TEST_GUIDE.md`, tests never
/// touch `XCUIElement` directly — every UI action routes through this
/// driver.
@MainActor
struct WelcomeScreen {
  let app: MoolahApp

  /// Waits for the hero "Get started" button to be visible. Used at
  /// the start of first-run tests to confirm the state machine landed
  /// in `.heroChecking` / `.heroNoneFound` / `.heroOff` rather than
  /// auto-activating.
  func waitForHero(timeout: TimeInterval = 10) {
    Trace.record()
    let button = app.element(for: UITestIdentifiers.Welcome.heroGetStartedButton)
    if !button.waitForExistence(timeout: timeout) {
      Trace.recordFailure("hero 'Get started' button did not appear")
      XCTFail("Welcome hero did not appear within \(timeout)s")
    }
  }

  /// Post-condition for auto-open paths (single cloud profile, etc.)
  /// where the hero must never appear. Waits up to `timeout` for the
  /// hero CTA to be absent and fails if it ever shows up.
  func expectHeroAbsent(timeout: TimeInterval = 10) {
    Trace.record()
    let hero = app.element(for: UITestIdentifiers.Welcome.heroGetStartedButton)
    let expectation = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: hero
    )
    if XCTWaiter().wait(for: [expectation], timeout: timeout) != .completed {
      Trace.recordFailure("hero 'Get started' button appeared unexpectedly")
      XCTFail("Welcome hero appeared within \(timeout)s when it should have stayed hidden")
    }
  }

  /// Waits for the multi-profile picker to be visible. The picker is
  /// identified by its "+ Create a new profile" footer row.
  func waitForPicker(timeout: TimeInterval = 10) {
    Trace.record()
    let row = app.element(for: UITestIdentifiers.Welcome.pickerCreateNewRow)
    if !row.waitForExistence(timeout: timeout) {
      Trace.recordFailure("picker create-new row did not appear")
      XCTFail("Multi-profile picker did not appear within \(timeout)s")
    }
  }

  /// Number of profile rows visible in the picker. Rows are identified
  /// by the `welcome.picker.row.` prefix followed by a UUID. Counting
  /// requires a prefix match across an unbounded UUID set, so this
  /// driver routes through `MoolahApp.buttons(matching:)` — the
  /// documented escape hatch from `element(for:)` for prefix scans.
  func pickerRowCount() -> Int {
    let predicate = NSPredicate(
      format: "identifier BEGINSWITH %@", UITestIdentifiers.Welcome.pickerRowPrefix)
    return app.buttons(matching: predicate).count
  }

  /// Taps "Get started" and waits for the create-profile Name field to
  /// appear.
  func tapGetStarted() {
    Trace.record()
    app.element(for: UITestIdentifiers.Welcome.heroGetStartedButton).click()
    let nameField = app.element(for: UITestIdentifiers.Welcome.nameField)
    if !nameField.waitForExistence(timeout: 10) {
      Trace.recordFailure("name field did not appear after tapGetStarted")
      XCTFail("Name field did not appear after tapping Get started")
    }
  }

  /// Types `name` into the Name field after giving it keyboard focus.
  /// Returns once the field's reported value equals `name` — the same
  /// post-condition pattern as `AutocompleteFieldDriver.type(_:)` so a
  /// downstream `tapCreateProfile` cannot race ahead of the binding.
  func typeName(_ name: String) {
    Trace.record(detail: "name=\(name)")
    let field = app.element(for: UITestIdentifiers.Welcome.nameField)
    field.click()
    field.typeText(name)

    let deadline = Date().addingTimeInterval(10)
    while Date() < deadline {
      if let value = field.value as? String, value == name { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("name field value did not propagate after typing")
    XCTFail("Welcome name field did not contain '\(name)' within 10s")
  }

  /// Taps "Create Profile" and waits for the hero to disappear — the
  /// post-condition that the session has loaded.
  func tapCreateProfile() {
    Trace.record()
    app.element(for: UITestIdentifiers.Welcome.createProfileButton).click()
    expectHeroAbsent()
  }

  /// Taps the multi-profile picker row for the given profile id. Used
  /// by tests that pre-seed two or more profiles and need to select
  /// one.
  func tapPickerRow(forProfile id: UUID, timeout: TimeInterval = 10) {
    Trace.record(detail: "id=\(id.uuidString.lowercased())")
    let row = app.element(for: UITestIdentifiers.Welcome.pickerRow(id))
    if !row.waitForExistence(timeout: timeout) {
      Trace.recordFailure("picker row \(id) did not appear")
      XCTFail("Picker row \(id) did not appear within \(timeout)s")
      return
    }
    row.click()
  }
}
