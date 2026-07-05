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
}
