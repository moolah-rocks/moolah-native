import AppKit
import XCTest

/// Failure-artefact collection for `MoolahUITestCase`. Split out so the
/// base class itself stays close to the public driver primitives that
/// individual tests use; the reader doesn't need to scroll past the
/// fixture-formatting helpers to find them.
///
/// `collectFailureArtefacts(for:succeeded:)` is the only entry point —
/// invoked from the base class's `tearDown` — every other helper here
/// is private to this file.
extension MoolahUITestCase {

  // MARK: - Driver-callable: in-flight failure snapshot

  /// Counter so each `captureFailureSnapshot` call writes to a distinct
  /// filename (`failure-1-<reason>.png/.txt`, `failure-2-...`). Reset
  /// implicitly per test by `setUp` reassigning the case instance.
  private static let failureSnapshotCounters = NSMapTable<XCTestCase, NSNumber>
    .weakToStrongObjects()

  /// Captures an immediate screenshot + accessibility-tree dump at the
  /// point a driver action determined it could not proceed (e.g.
  /// `tap()` clicked at the field's coordinates but no element ever
  /// reported `hasKeyboardFocus`).
  ///
  /// Drivers call this **before** `XCTFail` so the snapshot reflects the
  /// pixels that were on screen at the failure point — by the time the
  /// `tearDown` snapshot fires, dropdowns may have dismissed, the form
  /// may have scrolled, and the screen no longer reflects what the user
  /// would have seen at the moment the action gave up.
  ///
  /// Files land under the test's failure-artefact directory using a
  /// per-test counter so multiple captures in the same test do not
  /// overwrite each other.
  func captureFailureSnapshot(reason: String) {
    guard let app = lastApp else { return }
    let dir = artefactDirectory(for: name)
    do {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    } catch {
      add(XCTAttachment(string: "Failed to create snapshot dir: \(error)"))
      return
    }
    print("[MoolahUITestCase] ARTEFACT_DIR \(dir.path)")
    let counter = nextSnapshotCounter()
    let safeReason =
      reason
      .replacingOccurrences(of: "/", with: "_")
      .replacingOccurrences(of: " ", with: "_")
    let basename = "failure-\(counter)-\(safeReason)"
    // Take the screenshot first — `XCUIApplication.frame` triggers a full
    // accessibility snapshot and has been observed to hang for tens of
    // seconds in the failure path on slow runners. The screenshot
    // doesn't, so it's our priority artefact.
    let png = app.application.screenshot().pngRepresentation
    let pngURL = dir.appendingPathComponent("\(basename).png")
    do { try png.write(to: pngURL) } catch {
      add(XCTAttachment(string: "Failed to write \(pngURL.lastPathComponent): \(error)"))
    }
    let attachment = XCTAttachment(data: png, uniformTypeIdentifier: "public.png")
    attachment.lifetime = .keepAlways
    attachment.name = "\(basename).png"
    add(attachment)
    let screenSize = NSScreen.main?.frame.size ?? .zero
    print(
      "[MoolahUITestCase] CAPTURE \(basename) "
        + "screen=\(Int(screenSize.width))x\(Int(screenSize.height))"
    )
  }

  private func nextSnapshotCounter() -> Int {
    let table = Self.failureSnapshotCounters
    let next = ((table.object(forKey: self)?.intValue) ?? 0) + 1
    table.setObject(NSNumber(value: next), forKey: self)
    return next
  }

  // MARK: - Internal: artefact collection

  func collectFailureArtefacts(for app: MoolahApp, succeeded: Bool) {
    if succeeded { return }

    let dir = artefactDirectory(for: name)
    do {
      try FileManager.default.createDirectory(
        at: dir, withIntermediateDirectories: true)
    } catch {
      // Recording the failure to attach is itself best-effort; keep going.
      add(XCTAttachment(string: "Failed to create artefact dir: \(error)"))
      return
    }

    // Print the path so `scripts/test-ui.sh` can grep it out and copy the
    // artefacts back into `.agent-tmp/`, and attach an XCTAttachment so the
    // test navigator surfaces it.
    print("[MoolahUITestCase] ARTEFACT_DIR \(dir.path)")
    add(XCTAttachment(string: "ui-fail artefacts written to: \(dir.path)\n"))

    write(treeText(for: app), to: dir.appendingPathComponent("tree.txt"))
    write(seedText(for: app), to: dir.appendingPathComponent("seed.txt"))
    write(Trace.render(succeeded: false), to: dir.appendingPathComponent("trace.txt"))
    captureScreenshot(for: app, to: dir.appendingPathComponent("screenshot.png"))

    attachArtefacts(in: dir)
  }

  /// Resolves `<runner tmpdir>/MoolahUITests/ui-fail-<TestName>/`.
  ///
  /// The XCUITest runner runs in a stricter sandbox than the app: writes
  /// to `/private/tmp/` fail with "Operation not permitted" on current
  /// macOS. `FileManager.default.temporaryDirectory` resolves to the
  /// runner's own per-process tmpdir under `/var/folders/.../T/` which
  /// the runner can freely create inside and the developer's shell can
  /// still read (same uid) without TCC prompts. `scripts/test-ui.sh`
  /// greps the `[MoolahUITestCase] ARTEFACT_DIR` lines out of
  /// xcodebuild's stdout and copies each artefact dir back into
  /// `<repo-root>/.agent-tmp/` after `xcodebuild test` exits.
  private func artefactDirectory(for testName: String) -> URL {
    let cleanName =
      testName
      .replacingOccurrences(of: "-", with: "_")
      .replacingOccurrences(of: "[", with: "")
      .replacingOccurrences(of: "]", with: "")
      .replacingOccurrences(of: " ", with: "_")
    return FileManager.default.temporaryDirectory
      .appendingPathComponent("MoolahUITests", isDirectory: true)
      .appendingPathComponent("ui-fail-\(cleanName)", isDirectory: true)
  }

  // MARK: - Artefact contents

  private func treeText(for app: MoolahApp) -> String {
    var lines: [String] = []
    lines.append("# accessibility tree (identifier | type | label | value | frame)")
    let screenSize = NSScreen.main?.frame.size ?? .zero
    lines.append(
      "# screen size: \(Int(screenSize.width))x\(Int(screenSize.height))"
    )
    if let focusedIdentifier = currentFocusedIdentifier(in: app) {
      lines.append("# focused element: \(focusedIdentifier)")
    } else {
      lines.append("# focused element: (none — no element has keyboard focus)")
    }
    lines.append(
      "# (per-element focus is omitted — `XCUIElementSnapshot` does not expose it.)")
    lines.append("")
    let snapshot = try? app.application.snapshot()
    if let snapshot { appendTreeSnapshot(snapshot: snapshot, depth: 0, into: &lines) }
    return lines.joined(separator: "\n") + "\n"
  }

  /// Walks the live element tree once to find the currently focused
  /// element, returning its identifier (or label / type if no identifier
  /// is set). At most one element has keyboard focus at a time.
  private func currentFocusedIdentifier(in app: MoolahApp) -> String? {
    let elements = app.application.descendants(matching: .any).allElementsBoundByIndex
    for element in elements where (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false {
      if !element.identifier.isEmpty { return element.identifier }
      if !element.label.isEmpty { return "(label: \(element.label))" }
      return "(\(element.elementType))"
    }
    return nil
  }

  private func appendTreeSnapshot(
    snapshot: XCUIElementSnapshot, depth: Int, into lines: inout [String]
  ) {
    let indent = String(repeating: "  ", count: depth)
    let identifier = snapshot.identifier.isEmpty ? "—" : snapshot.identifier
    let type = String(describing: snapshot.elementType)
    let label =
      snapshot.label.isEmpty ? "—" : snapshot.label.replacingOccurrences(of: "\n", with: " ")
    let value = (snapshot.value as? String).map { $0.isEmpty ? "—" : $0 } ?? "—"
    let frame = snapshot.frame
    let frameStr =
      "(\(Int(frame.origin.x)),\(Int(frame.origin.y)) \(Int(frame.size.width))x\(Int(frame.size.height)))"
    lines.append(
      "\(indent)\(identifier) | \(type) | \(label) | \(value) | \(frameStr)"
    )
    for child in snapshot.children {
      appendTreeSnapshot(snapshot: child, depth: depth + 1, into: &lines)
    }
  }

  private func seedText(for app: MoolahApp) -> String {
    var lines: [String] = []
    lines.append("seed: \(app.seed.rawValue)")
    lines.append("")
    appendFixtures(for: app.seed, into: &lines)
    return lines.joined(separator: "\n") + "\n"
  }

  // swiftlint:disable cyclomatic_complexity
  /// Per-seed fixture-text dispatch, factored out of `seedText(for:)` so
  /// the top-level helper stays manageable as new seeds are added. Welcome
  /// seeds share one sub-dispatch and sidebar-footer seeds share one
  /// helper so each adds only a single case to the outer switch.
  private func appendFixtures(for seed: UITestSeed, into lines: inout [String]) {
    switch seed {
    case .tradeBaseline:
      appendTradeBaselineFixtures(into: &lines)
    case .welcomeEmpty, .welcomeSingleCloudProfile,
      .welcomeMultipleCloudProfiles, .welcomeDownloading:
      appendWelcomeFixtures(seed: seed, into: &lines)
    case .sidebarFooterUpToDate, .sidebarFooterReceiving, .sidebarFooterSending:
      appendSidebarFooterFixtures(seed: seed, into: &lines)
    case .cryptoCatalogPreloaded:
      appendCryptoCatalogPreloadedFixtures(into: &lines)
    case .tradeReady:
      appendTradeReadyFixtures(into: &lines)
    case .incompatibleProfile:
      appendIncompatibleProfileFixtures(into: &lines)
    case .transferDetectionBaseline:
      appendTransferDetectionFixtures(into: &lines)
    case .pendingWebImportOneChaseInbox:
      appendPendingWebImportFixtures(into: &lines)
    case .insightsForYouBaseline:
      appendInsightsForYouFixtures(into: &lines)
    case .groupFilterScope:
      appendGroupFilterScopeFixtures(into: &lines)
    case .walletHeaderSyncError:
      appendWalletHeaderFixtures(into: &lines)
    }
  }
  // swiftlint:enable cyclomatic_complexity

  /// Sub-dispatch for the four `welcomeXxx` seeds so the outer switch
  /// only consumes one cyclomatic-complexity unit for the whole family.
  private func appendWelcomeFixtures(seed: UITestSeed, into lines: inout [String]) {
    switch seed {
    case .welcomeEmpty:
      lines.append("# fixtures — empty index, no profiles")
    case .welcomeSingleCloudProfile:
      appendWelcomeSingleProfileFixtures(into: &lines)
    case .welcomeMultipleCloudProfiles:
      appendWelcomeMultipleProfileFixtures(into: &lines)
    case .welcomeDownloading:
      lines.append("# SyncProgress driven to .receiving with recordsReceivedThisSession=1234")
      lines.append("# WelcomeView resolves to .heroDownloading(count: 1234)")
    default:
      break  // unreachable — caller filters to welcome seeds
    }
  }

  // Per-seed `appendXxxFixtures` helpers live in
  // `MoolahUITestCase+SeedFixturesText.swift` so this file stays focused
  // on the artefact-collection plumbing and the per-seed fixture mirror
  // can grow independently per `guides/CODE_GUIDE.md` §10.

  private func captureScreenshot(for app: MoolahApp, to url: URL) {
    let screenshot = app.application.screenshot()
    do {
      try screenshot.pngRepresentation.write(to: url)
    } catch {
      add(XCTAttachment(string: "Failed to write screenshot: \(error)"))
    }
  }

  private func write(_ text: String, to url: URL) {
    do {
      try text.write(to: url, atomically: true, encoding: .utf8)
    } catch {
      add(XCTAttachment(string: "Failed to write \(url.lastPathComponent): \(error)"))
    }
  }

  private func attachArtefacts(in dir: URL) {
    let fileManager = FileManager.default
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: dir, includingPropertiesForKeys: nil)
    else { return }
    for url in entries {
      let attachment = XCTAttachment(contentsOfFile: url)
      attachment.lifetime = .keepAlways
      attachment.name = url.lastPathComponent
      add(attachment)
    }
  }
}
