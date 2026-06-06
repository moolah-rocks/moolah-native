import XCTest

/// Reusable driver for any text field whose accessibility identifier
/// matches `<area>.<element>` and whose autocomplete dropdown matches
/// `autocomplete.<element>`. Use one for each autocomplete-bearing field
/// (payee, category, etc.).
///
/// Each action method starts with `Trace.record(#function)` and waits
/// for a real post-condition before returning — see
/// `guides/UI_TEST_GUIDE.md` §3 (driver invariants).
@MainActor
struct AutocompleteFieldDriver {
  let app: MoolahApp
  let fieldIdentifier: String
  let dropdownIdentifier: String
  let suggestionIdentifier: (Int) -> String

  // MARK: - Actions

  /// Clicks the field to give it keyboard focus. Returns once the field
  /// reports `hasKeyboardFocus`. Use this when the field has not been
  /// auto-focused by the surrounding view (e.g. `defaultFocus(.payee)`
  /// does not always win the macOS first-responder).
  func tap() {
    Trace.record(#function, detail: "field=\(fieldIdentifier)")
    let field = app.element(for: fieldIdentifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("field '\(fieldIdentifier)' did not appear for tap")
      XCTFail("Autocomplete field '\(fieldIdentifier)' did not appear within 3s")
      return
    }
    field.click()
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    app.testCase?.captureFailureSnapshot(reason: "tap-no-focus-\(fieldIdentifier)")
    Trace.recordFailure("tap on '\(fieldIdentifier)' did not produce focus")
    XCTFail("Autocomplete field '\(fieldIdentifier)' did not focus after tap")
  }

  /// Types `text` into the field. Returns once the field's reported value
  /// reflects the typed text.
  func type(_ text: String) {
    Trace.record(detail: "field=\(fieldIdentifier) text=\"\(text)\"")
    let field = app.element(for: fieldIdentifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("field '\(fieldIdentifier)' did not appear")
      XCTFail("Autocomplete field '\(fieldIdentifier)' did not appear within 3s")
      return
    }
    field.click()
    field.typeText(text)

    // Post-condition: the field reports back a value containing the typed
    // text. (`SwiftUI` text field values are exposed via the `value`
    // accessor.)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let value = field.value as? String, value.contains(text) { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    app.testCase?.captureFailureSnapshot(reason: "type-no-value-\(fieldIdentifier)")
    Trace.recordFailure("field value did not propagate after typing")
    XCTFail("Autocomplete field value did not contain '\(text)' within 3s")
  }

  /// Clears any existing text in the field via Cmd+A then backspace.
  /// Returns once the field's reported value is empty. Use before `type`
  /// when the field was pre-populated (e.g. editing an existing payee) or
  /// inside a test that asserts "clearing hides the dropdown".
  func clear() {
    Trace.record(detail: "field=\(fieldIdentifier)")
    let field = app.element(for: fieldIdentifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("field '\(fieldIdentifier)' did not appear for clear")
      XCTFail("Autocomplete field '\(fieldIdentifier)' did not appear within 3s")
      return
    }
    field.click()
    app.pressKeyboardShortcut("a", modifiers: .command)
    app.pressKeyboardShortcut(XCUIKeyboardKey.delete.rawValue)

    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if let value = field.value as? String, value.isEmpty { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    app.testCase?.captureFailureSnapshot(reason: "clear-not-empty-\(fieldIdentifier)")
    Trace.recordFailure("field did not empty after clear")
    XCTFail("Autocomplete field '\(fieldIdentifier)' did not clear within 3s")
  }

  /// Sends a single arrow-down key press to the field. Returns once the
  /// dropdown reports a highlighted row (any suggestion with `isSelected`).
  /// Caller is expected to ensure the dropdown is visible — the
  /// `.downArrow` handler in `AutocompleteField` is guarded on
  /// `suggestionCount > 0`, so arrow-down with no suggestions is a no-op.
  func pressArrowDown() {
    Trace.record(detail: "field=\(fieldIdentifier)")
    app.application.typeKey(.downArrow, modifierFlags: [])
    if !waitUntilAnySuggestionSelected(timeout: 3) {
      Trace.recordFailure("arrow-down did not produce any highlighted suggestion")
      XCTFail(
        "Autocomplete dropdown '\(dropdownIdentifier)' had no highlighted suggestion "
          + "within 3s of arrow-down")
    }
  }

  /// Sends a single Return key press to the field. Returns once the
  /// dropdown has hidden (the selection was committed and the overlay
  /// dismissed).
  func pressEnter() {
    Trace.record(detail: "field=\(fieldIdentifier)")
    app.application.typeKey(.return, modifierFlags: [])
    if !waitUntilDropdownHidden(timeout: 3) {
      Trace.recordFailure("dropdown '\(dropdownIdentifier)' did not hide after Return")
      XCTFail(
        "Autocomplete dropdown '\(dropdownIdentifier)' did not hide within 3s of Return")
    }
  }

  /// Sends a single Tab key press to the field. Returns once the
  /// dropdown has hidden — by then focus has moved off the field, so the
  /// blur handler has run. For category fields, that handler commits a
  /// highlighted suggestion (#509); for payee, it preserves the user's
  /// typed text (#510). Callers assert the resulting field value
  /// separately.
  func pressTab() {
    Trace.record(detail: "field=\(fieldIdentifier)")
    app.application.typeKey("\t", modifierFlags: [])
    if !waitUntilDropdownHidden(timeout: 3) {
      Trace.recordFailure("dropdown '\(dropdownIdentifier)' did not hide after Tab")
      XCTFail(
        "Autocomplete dropdown '\(dropdownIdentifier)' did not hide within 3s of Tab")
    }
  }

  /// Sends a single Escape key press to the field. Returns once the
  /// dropdown has hidden. The user's typed text is **not** cleared —
  /// callers asserting the field value should still expect whatever the
  /// user typed before pressing Escape (#510).
  func pressEscape() {
    Trace.record(detail: "field=\(fieldIdentifier)")
    app.application.typeKey(.escape, modifierFlags: [])
    if !waitUntilDropdownHidden(timeout: 3) {
      Trace.recordFailure("dropdown '\(dropdownIdentifier)' did not hide after Escape")
      XCTFail(
        "Autocomplete dropdown '\(dropdownIdentifier)' did not hide within 3s of Escape")
    }
  }

  // MARK: - Internal: post-condition waits

  private func waitUntilDropdownHidden(timeout: TimeInterval) -> Bool {
    let dropdown = app.element(for: dropdownIdentifier)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if !dropdown.exists { return true }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return false
  }

  private func waitUntilAnySuggestionSelected(timeout: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      var index = 0
      while app.element(for: suggestionIdentifier(index)).exists {
        let suggestion = app.element(for: suggestionIdentifier(index))
        if (suggestion.value(forKey: "isSelected") as? Bool) ?? false { return true }
        index += 1
        if index > 200 { break }
      }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return false
  }

  // MARK: - Expectations (read-only)

  /// Asserts the field currently holds keyboard focus. Polls for up to
  /// 3 s — SwiftUI propagates `@FocusState` on a later runloop pass than
  /// the field's value binding, so a field can exist (and even hold its
  /// new value) a tick before focus lands. A single point-in-time read
  /// would flake on a CI runner that processes that pass slower than
  /// local hardware.
  func expectFocused() {
    let field = app.element(for: fieldIdentifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("field '\(fieldIdentifier)' not present for focus check")
      XCTFail("Autocomplete field '\(fieldIdentifier)' did not appear within 3s")
      return
    }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if (field.value(forKey: "hasKeyboardFocus") as? Bool) ?? false { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("field '\(fieldIdentifier)' is not focused")
    XCTFail("Autocomplete field '\(fieldIdentifier)' did not have keyboard focus")
  }

  /// Asserts the field's current value equals `expected`. Polls for up
  /// to 3 s — bindings from `onChange(of: text)` can lag a frame behind
  /// the key event that triggered them.
  func expectValue(_ expected: String) {
    let field = app.element(for: fieldIdentifier)
    if !field.waitForExistence(timeout: 3) {
      Trace.recordFailure("field '\(fieldIdentifier)' not present for value check")
      XCTFail("Autocomplete field '\(fieldIdentifier)' did not appear within 3s")
      return
    }
    let deadline = Date().addingTimeInterval(3)
    var lastActual = ""
    while Date() < deadline {
      lastActual = (field.value as? String) ?? ""
      if lastActual == expected { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("field value '\(lastActual)' != '\(expected)'")
    XCTFail("Autocomplete field expected value '\(expected)', got '\(lastActual)'")
  }

  /// Asserts the autocomplete dropdown is currently visible and contains
  /// the given number of suggestions. Polls until the count matches and
  /// stays stable, because suggestions render asynchronously after the
  /// dropdown appears.
  func expectSuggestionsVisible(count: Int) {
    let dropdown = app.element(for: dropdownIdentifier)
    if !dropdown.waitForExistence(timeout: 3) {
      Trace.recordFailure("dropdown '\(dropdownIdentifier)' did not appear")
      XCTFail("Autocomplete dropdown '\(dropdownIdentifier)' did not appear within 3s")
      return
    }
    let deadline = Date().addingTimeInterval(3)
    var lastFound = -1
    while Date() < deadline {
      var found = 0
      while app.element(for: suggestionIdentifier(found)).exists {
        found += 1
        if found > 200 { break }  // safety cap; suggestions are bounded by view
      }
      if found == count { return }
      lastFound = found
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("expected \(count) suggestions, last seen \(lastFound)")
    XCTFail("Autocomplete dropdown had \(lastFound) suggestions, expected \(count)")
  }

  /// Asserts the autocomplete dropdown is hidden.
  func expectSuggestionsHidden() {
    // Wait briefly for hide to settle, then assert.
    let dropdown = app.element(for: dropdownIdentifier)
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if !dropdown.exists { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("dropdown '\(dropdownIdentifier)' still visible after 3s")
    XCTFail("Autocomplete dropdown '\(dropdownIdentifier)' did not hide within 3s")
  }

  /// Asserts the suggestion at `index` is currently highlighted. Polls
  /// for up to 3 s so the assertion tolerates a frame of lag between the
  /// key event and SwiftUI's `highlightedIndex` update.
  func expectHighlightedSuggestion(at index: Int) {
    let identifier = suggestionIdentifier(index)
    let suggestion = app.element(for: identifier)
    if !suggestion.waitForExistence(timeout: 3) {
      Trace.recordFailure("suggestion '\(identifier)' not present")
      XCTFail("Autocomplete suggestion at index \(index) did not appear within 3s")
      return
    }
    let deadline = Date().addingTimeInterval(3)
    while Date() < deadline {
      if (suggestion.value(forKey: "isSelected") as? Bool) ?? false { return }
      RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    Trace.recordFailure("suggestion '\(identifier)' is not highlighted")
    XCTFail("Autocomplete suggestion at index \(index) is not highlighted within 3s")
  }
}
