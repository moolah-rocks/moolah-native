import XCTest

/// Driver for the Tax Owners section in Settings → Profiles. The tests use
/// this screen only after `SettingsScreen.openProfilesTab()` has selected the
/// Profiles tab and waited for the section sentinel.
@MainActor
struct TaxOwnerSettingsScreen {
  let app: MoolahApp

  // MARK: - Actions

  /// Opens the sole/default owner's action menu, chooses Rename, and saves a
  /// new name. Returns once the renamed owner row is visible and the old name
  /// has disappeared, proving the SwiftUI row re-rendered after the store
  /// update.
  func renameOwner(_ currentName: String, to newName: String) {
    Trace.record(#function, detail: "currentName=\(currentName) newName=\(newName)")
    guard openActionsMenu(for: currentName) else { return }
    guard clickOwnerMenuItem(UITestIdentifiers.TaxOwnerSettings.renameMenuTitle) else { return }
    guard typeNameInPresentedSheet(newName) else { return }
    guard clickEditConfirmation() else { return }

    waitForOwnerName(newName)
    waitForOwnerNameGone(currentName)
  }

  /// Adds an individual tax owner using the Add Tax Owner sheet. Returns once
  /// the new owner row is visible in the Settings form.
  func addOwner(named name: String) {
    Trace.record(#function, detail: "name=\(name)")
    let button = app.element(for: UITestIdentifiers.TaxOwnerSettings.addButton)
    if !button.waitForExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.add did not appear")
      XCTFail("Add Tax Owner button did not appear within 10s")
      return
    }
    if !scrollFormUntilHittable(button, timeout: 10) {
      Trace.recordFailure("settings.taxOwner.add was not hittable within 10s")
      XCTFail("Add Tax Owner button was not hittable within 10s")
      return
    }
    button.click()

    guard typeNameInPresentedSheet(name) else { return }
    guard clickEditConfirmation() else { return }
    waitForOwnerName(name)
  }

  /// Chooses the row menu's Set as Default item and returns once the selected
  /// owner carries the Default badge.
  func setDefaultOwner(_ name: String) {
    Trace.record(#function, detail: "name=\(name)")
    guard openActionsMenu(for: name) else { return }
    guard clickOwnerMenuItem(UITestIdentifiers.TaxOwnerSettings.setAsDefaultMenuTitle) else {
      return
    }
    waitForDefaultBadge(name)
  }

  /// Opens the default-owner delete sheet, selects `replacementName`, confirms
  /// deletion, and returns once the deleted owner is gone and the replacement
  /// carries the Default badge.
  func deleteDefaultOwner(_ name: String, replacementName: String) {
    Trace.record(#function, detail: "name=\(name) replacementName=\(replacementName)")
    guard openActionsMenu(for: name) else { return }
    guard clickOwnerMenuItem(UITestIdentifiers.TaxOwnerSettings.deleteMenuTitle) else { return }

    let picker = app.element(for: UITestIdentifiers.TaxOwnerSettings.replacementPicker)
    if !picker.waitForExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.deleteDefault.replacement did not appear")
      XCTFail("Delete Default Owner replacement picker did not appear within 10s")
      return
    }
    guard selectReplacement(replacementName) else { return }

    let deleteButton = app.element(
      for: UITestIdentifiers.TaxOwnerSettings.deleteDefaultConfirmButton)
    if !deleteButton.waitForExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.deleteDefault.confirm did not appear")
      XCTFail("Delete Default Owner confirmation button did not appear within 10s")
      return
    }
    if !deleteButton.waitUntilHittable(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.deleteDefault.confirm was not hittable")
      XCTFail("Delete Default Owner confirmation button was not hittable within 10s")
      return
    }
    deleteButton.click()

    waitForOwnerNameGone(name)
    waitForDefaultBadge(replacementName)
  }

  // MARK: - Expectations

  func expectOwnerVisible(_ name: String) {
    let ownerName = app.staticText(label: name)
    if !ownerName.waitForExistence(timeout: 10) {
      XCTFail("Tax owner '\(name)' did not appear within 10s")
    }
  }

  func expectOwnerAbsent(_ name: String) {
    let ownerName = app.staticText(label: name)
    if !ownerName.waitForNonExistence(timeout: 2) {
      XCTFail("Tax owner '\(name)' should be absent but is visible")
    }
  }

  func expectDefaultOwner(_ name: String) {
    let badge = app.staticText(
      label: UITestIdentifiers.TaxOwnerSettings.defaultBadgeLabel(ownerName: name))
    if !badge.waitForExistence(timeout: 10) {
      XCTFail("Tax owner '\(name)' did not show the Default badge within 10s")
    }
  }

  // MARK: - Private helpers

  private func openActionsMenu(for name: String) -> Bool {
    Trace.record(#function, detail: "name=\(name)")
    let button = app.element(for: UITestIdentifiers.TaxOwnerSettings.actionsButton(ownerName: name))
    if !button.waitForExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.actions.\(name) did not appear")
      XCTFail("Actions menu for tax owner '\(name)' did not appear within 10s")
      return false
    }
    if !scrollFormUntilHittable(button, timeout: 10) {
      Trace.recordFailure("settings.taxOwner.actions.\(name) was not hittable")
      XCTFail("Actions menu for tax owner '\(name)' was not hittable within 10s")
      return false
    }
    button.click()
    let renameItem = app.menuItem(label: UITestIdentifiers.TaxOwnerSettings.renameMenuTitle)
    if !renameItem.waitForExistence(timeout: 10) {
      Trace.recordFailure("Tax owner actions menu for '\(name)' did not open")
      XCTFail("Actions menu for tax owner '\(name)' did not open within 10s")
      return false
    }
    return true
  }

  private func clickOwnerMenuItem(_ title: String) -> Bool {
    Trace.record(#function, detail: "title=\(title)")
    let item = app.menuItem(label: title)
    if !item.waitForExistence(timeout: 10) {
      Trace.recordFailure("Tax owner menu item '\(title)' did not appear")
      XCTFail("Tax owner menu item '\(title)' did not appear within 10s")
      return false
    }
    item.click()
    if !item.waitForNonExistence(timeout: 10) {
      Trace.recordFailure("Tax owner menu item '\(title)' did not dismiss")
      XCTFail("Tax owner menu item '\(title)' remained visible after click")
      return false
    }
    return true
  }

  private func typeNameInPresentedSheet(_ name: String) -> Bool {
    Trace.record(#function, detail: "name=\(name)")
    let field = app.element(for: UITestIdentifiers.TaxOwnerSettings.editNameField)
    if !field.waitForExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.edit.name did not appear")
      XCTFail("Tax owner name field did not appear within 10s")
      return false
    }
    if !field.waitUntilHittable(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.edit.name was not hittable")
      XCTFail("Tax owner name field was not hittable within 10s")
      return false
    }
    field.click()
    app.pressKeyboardShortcut("a", modifiers: .command)
    field.typeText(name)

    let valuePropagated = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", name as CVarArg),
      object: field
    )
    if XCTWaiter().wait(for: [valuePropagated], timeout: 10) != .completed {
      Trace.recordFailure("settings.taxOwner.edit.name did not reach '\(name)' after typeText")
      XCTFail("Tax owner name field did not show typed value '\(name)'")
      return false
    }
    return true
  }

  private func clickEditConfirmation() -> Bool {
    Trace.record(#function)
    let button = app.element(for: UITestIdentifiers.TaxOwnerSettings.editConfirmButton)
    if !button.waitForExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.edit.confirm did not appear")
      XCTFail("Tax owner edit confirmation button did not appear within 10s")
      return false
    }
    if !button.waitUntilHittable(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.edit.confirm was not hittable")
      XCTFail("Tax owner edit confirmation button was not hittable within 10s")
      return false
    }
    button.click()

    let field = app.element(for: UITestIdentifiers.TaxOwnerSettings.editNameField)
    if !field.waitForNonExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.edit.name remained after confirm")
      XCTFail("Tax owner edit sheet did not dismiss within 10s of confirming")
      return false
    }
    return true
  }

  private func selectReplacement(_ replacementName: String) -> Bool {
    Trace.record(#function, detail: "replacementName=\(replacementName)")
    let picker = app.element(for: UITestIdentifiers.TaxOwnerSettings.replacementPicker)
    if !picker.waitUntilHittable(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.deleteDefault.replacement was not hittable")
      XCTFail("Delete Default Owner replacement picker was not hittable within 10s")
      return false
    }
    picker.click()
    let item = app.menuItem(label: replacementName)
    if !item.waitForExistence(timeout: 10) {
      Trace.recordFailure("replacement menu item '\(replacementName)' did not appear")
      XCTFail("Replacement owner '\(replacementName)' did not appear in picker within 10s")
      return false
    }
    item.click()

    let selected = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", replacementName as CVarArg),
      object: picker
    )
    if XCTWaiter().wait(for: [selected], timeout: 10) != .completed {
      let actual = (picker.value as? String) ?? "<no value>"
      Trace.recordFailure(
        "replacement picker shows '\(actual)', expected '\(replacementName)'")
      XCTFail("Replacement picker shows '\(actual)', expected '\(replacementName)'")
      return false
    }
    return true
  }

  private func waitForOwnerName(_ name: String) {
    let ownerName = app.staticText(label: name)
    if !ownerName.waitForExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.name.\(name) did not appear")
      XCTFail("Tax owner '\(name)' did not appear within 10s")
    }
  }

  private func waitForOwnerNameGone(_ name: String) {
    let ownerName = app.staticText(label: name)
    if !ownerName.waitForNonExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.name.\(name) remained visible")
      XCTFail("Tax owner '\(name)' remained visible after the update")
    }
  }

  private func waitForDefaultBadge(_ name: String) {
    let badge = app.staticText(
      label: UITestIdentifiers.TaxOwnerSettings.defaultBadgeLabel(ownerName: name))
    if !badge.waitForExistence(timeout: 10) {
      Trace.recordFailure("settings.taxOwner.defaultBadge.\(name) did not appear")
      XCTFail("Tax owner '\(name)' did not show the Default badge within 10s")
    }
  }

  private func scrollFormUntilHittable(
    _ element: XCUIElement,
    timeout: TimeInterval
  ) -> Bool {
    if element.isHittable { return true }
    let form = app.settingsScrollView(containing: UITestIdentifiers.TaxOwnerSettings.container)
    let halfway = Date().addingTimeInterval(timeout / 2)
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < halfway {
      form.swipeUp()
      if element.isHittable { return true }
    }
    while Date() < deadline {
      form.swipeDown()
      if element.isHittable { return true }
    }
    return element.isHittable
  }
}
