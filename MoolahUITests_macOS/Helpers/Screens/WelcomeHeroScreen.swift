import XCTest

/// Driver for the first-run hero surface (`WelcomeHero`). Covers both the
/// standard "checking" state and the downloading state shown while iCloud
/// data is arriving in the background.
///
/// Returned from `MoolahApp.welcomeHero`.
@MainActor
struct WelcomeHeroScreen {
  let app: MoolahApp

  // MARK: - Expectations

  /// Asserts that the "Create a new profile" alternate CTA is visible.
  /// This button is only rendered in the `.heroDownloading` state.
  func expectCreateNewButtonVisible() {
    Trace.record(#function)
    let element = app.element(for: UITestIdentifiers.Welcome.heroCreateNewButton)
    if !element.waitForExistence(timeout: 10) {
      Trace.recordFailure("'Create a new profile' button did not appear")
      XCTFail("'Create a new profile' button did not appear within 10s")
    }
  }

  /// Asserts that the downloading-status line is visible and its label
  /// contains the expected `receivedText` fragment (e.g. "1,234").
  func expectDownloadingStatus(containing receivedText: String) {
    Trace.record(#function, detail: "receivedText=\(receivedText)")
    let element = app.element(for: UITestIdentifiers.Welcome.heroDownloadingStatus)
    if !element.waitForExistence(timeout: 10) {
      Trace.recordFailure("downloading status line did not appear")
      XCTFail("Downloading-status line did not appear within 10s")
      return
    }
    let label = element.label
    if !label.contains(receivedText) {
      Trace.recordFailure(
        "status label '\(label)' did not contain expected text '\(receivedText)'"
      )
      XCTFail(
        "Expected downloading-status label to contain '\(receivedText)'; got '\(label)'"
      )
    }
  }

  /// Asserts that the background-download footnote is visible below the CTA.
  func expectDownloadFootnoteVisible() {
    Trace.record(#function)
    let element = app.element(for: UITestIdentifiers.Welcome.heroDownloadFootnote)
    if !element.waitForExistence(timeout: 10) {
      Trace.recordFailure("download footnote did not appear")
      XCTFail("Download footnote did not appear within 10s")
    }
  }
}
