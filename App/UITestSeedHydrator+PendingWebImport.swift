import Foundation
import ImportExtensionKit

// Pending-web-import seed helpers for `UITestSeedHydrator`. Owns the
// fixture inbox write the `.pendingWebImportOneChaseInbox` seed needs;
// kept in a sibling file so the main hydrator enum body stays under
// SwiftLint's `type_body_length` threshold as more seeds are added.
@MainActor
extension UITestSeedHydrator {

  /// Writes the deterministic Chase-shaped `ImportPayload` for the
  /// `.pendingWebImportOneChaseInbox` seed into the fallback inbox
  /// directory pointed at by `UITestEnvironment.inboxDirectory`. The
  /// banner reads that file at first paint and reports the single
  /// pending import — the contract the harness test asserts on.
  ///
  /// A missing env var is a fatal error: the seed exists exclusively to
  /// drive the inbox→review handoff XCUITest and is unusable without
  /// the directory wired through `launchEnvironment`.
  static func seedPendingWebImportInbox() throws {
    let env = ProcessInfo.processInfo.environment
    guard let dir = env[UITestEnvironment.inboxDirectory], !dir.isEmpty else {
      fatalError(
        "\(UITestEnvironment.inboxDirectory) must be set by the UI test harness when "
          + "selecting the .pendingWebImportOneChaseInbox seed."
      )
    }
    let fixtures = UITestFixtures.PendingWebImportOneChaseInbox.self
    let writer = InboxWriter(rootDirectory: URL(fileURLWithPath: dir))
    let payload = ImportPayload(
      schemaVersion: 1,
      sourceHost: fixtures.sourceHost,
      sourceURL: fixtures.sourceURL,
      capturedAt: fixtures.capturedAt,
      accountHint: fixtures.accountHint,
      currencyHint: fixtures.currencyHint,
      rows: [
        ImportPayloadRow(
          date: "2026-04-14",
          amount: "-42.17",
          description: "WHOLE FOODS MARKET",
          balance: "1234.56",
          reference: "REF123"),
        ImportPayloadRow(
          date: "2026-04-12",
          amount: "1500.00",
          description: "PAYROLL DEPOSIT",
          balance: "1276.73",
          reference: nil),
      ])
    try writer.write(payload, id: fixtures.payloadId)
  }
}
