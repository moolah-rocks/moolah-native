import XCTest

/// Driver for the Crypto tab of the macOS Settings scene
/// (`CryptoSettingsView`). Returned from `MoolahApp.cryptoSettings` or via
/// `SettingsScreen.openCryptoTab()` (after which this screen's root
/// container is guaranteed to be visible).
///
/// Action methods open the embedded `AddTokenSheet` and read the
/// registrations list; the picker that the sheet hosts has its own driver
/// (`AddTokenScreen`).
@MainActor
struct CryptoSettingsScreen {
  let app: MoolahApp

  // MARK: - Actions

  /// Taps the "+" button in the Registered Tokens header to present the
  /// `AddTokenSheet`. Returns once the picker sheet's sentinel
  /// (`instrumentPicker.sheet`) appears in the accessibility tree.
  func tapAddToken() {
    Trace.record(#function)
    let button = app.element(for: UITestIdentifiers.CryptoSettings.addTokenButton)
    if !button.waitForExistence(timeout: 10) {
      Trace.recordFailure("crypto.settings.addToken button did not appear")
      XCTFail("Add Token button did not appear within 10s")
      return
    }
    button.click()
    let sheet = app.element(for: UITestIdentifiers.InstrumentPicker.sheet)
    if !sheet.waitForExistence(timeout: 10) {
      Trace.recordFailure("instrumentPicker.sheet did not appear after Add Token tap")
      XCTFail("AddTokenSheet picker did not appear within 10s of tapping +")
    }
  }

  /// Waits for the registration row whose Instrument id matches
  /// `instrumentId` to appear in the registered-tokens list. The
  /// CryptoTokenStore reloads registrations on the picker's
  /// `onRegistered` callback, so this is the post-condition the
  /// end-to-end test asserts.
  func waitForRegistration(instrumentId: String, timeout: TimeInterval = 10) {
    Trace.record(#function, detail: "instrumentId=\(instrumentId)")
    let row = app.element(
      for: UITestIdentifiers.CryptoSettings.registrationRow(instrumentId))
    if !row.waitForExistence(timeout: timeout) {
      Trace.recordFailure(
        "crypto.settings.registration.\(instrumentId) did not appear within \(timeout)s")
      XCTFail(
        "Crypto registration row for '\(instrumentId)' did not appear within \(timeout)s")
    }
  }

  // MARK: - Custom RPC Endpoints

  /// Types `url` into the Custom RPC Endpoints entry field and taps "Add".
  /// Waits for the field's typed value to propagate (mirroring
  /// `AddTokenScreen.search(_:)`) before tapping Add, then waits for the
  /// new row (keyed by `url`) to appear — the round trip through
  /// `CryptoTokenStore.addRPCEndpoint` and its post-add re-probe.
  func addRPCEndpoint(_ url: String) {
    Trace.record(#function, detail: "url=\(url)")
    let field = app.element(for: UITestIdentifiers.CryptoSettings.rpcEndpointField)
    if !field.waitForExistence(timeout: 10) {
      Trace.recordFailure("crypto.settings.rpc.field did not appear")
      XCTFail("RPC endpoint field did not appear within 10s")
      return
    }
    field.click()
    field.typeText(url)
    let valuePropagated = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "value == %@", url as CVarArg),
      object: field
    )
    if XCTWaiter().wait(for: [valuePropagated], timeout: 10) != .completed {
      Trace.recordFailure("crypto.settings.rpc.field value did not reach '\(url)' after typeText")
      XCTFail("RPC endpoint field did not show typed value '\(url)'")
      return
    }
    let addButton = app.element(for: UITestIdentifiers.CryptoSettings.rpcEndpointAddButton)
    addButton.click()
    let row = app.element(for: UITestIdentifiers.CryptoSettings.rpcEndpointRow(url))
    if !row.waitForExistence(timeout: 10) {
      Trace.recordFailure("crypto.settings.rpc.row.\(url) did not appear after Add")
      XCTFail("RPC endpoint row for '\(url)' did not appear within 10s of tapping Add")
    }
  }

  /// Waits for the endpoint row's status label to show `chainName` (e.g.
  /// "Ethereum") — the reachable-and-resolved badge state
  /// (`RPCEndpointStatus.reachable(chainName:)`). The label starts as
  /// "Not probed" and updates once the section's `.task`-driven
  /// `probeEndpoints()` completes, so this polls rather than asserting
  /// the label's value at first appearance.
  func waitForRPCEndpointStatus(url: String, chainName: String, timeout: TimeInterval = 10) {
    Trace.record(#function, detail: "url=\(url) chainName=\(chainName)")
    let label = app.element(for: UITestIdentifiers.CryptoSettings.rpcEndpointStatusLabel(url))
    if !label.waitForExistence(timeout: timeout) {
      Trace.recordFailure("crypto.settings.rpc.status.\(url) did not appear")
      XCTFail("RPC endpoint status label for '\(url)' did not appear within \(timeout)s")
      return
    }
    let resolved = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "label CONTAINS %@", chainName as CVarArg),
      object: label
    )
    if XCTWaiter().wait(for: [resolved], timeout: timeout) != .completed {
      Trace.recordFailure(
        "crypto.settings.rpc.status.\(url) never resolved to chain '\(chainName)'")
      XCTFail(
        "RPC endpoint status for '\(url)' did not resolve to '\(chainName)' within \(timeout)s")
    }
  }

  /// Taps the "Remove" button on the endpoint row for `url` and waits for
  /// the row to disappear — the round trip through
  /// `CryptoTokenStore.removeRPCEndpoint` and its post-remove re-probe.
  func removeRPCEndpoint(_ url: String, timeout: TimeInterval = 10) {
    Trace.record(#function, detail: "url=\(url)")
    let button = app.element(for: UITestIdentifiers.CryptoSettings.rpcEndpointRemoveButton(url))
    if !button.waitForExistence(timeout: timeout) {
      Trace.recordFailure("crypto.settings.rpc.remove.\(url) did not appear")
      XCTFail("RPC endpoint remove button for '\(url)' did not appear within \(timeout)s")
      return
    }
    button.click()
    let row = app.element(for: UITestIdentifiers.CryptoSettings.rpcEndpointRow(url))
    let gone = XCTNSPredicateExpectation(
      predicate: NSPredicate(format: "exists == false"),
      object: row
    )
    if XCTWaiter().wait(for: [gone], timeout: timeout) != .completed {
      Trace.recordFailure("crypto.settings.rpc.row.\(url) still present after Remove")
      XCTFail("RPC endpoint row for '\(url)' was still present \(timeout)s after tapping Remove")
    }
  }
}
