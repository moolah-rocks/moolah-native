# Handoff Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Apple Handoff (`NSUserActivity` type `com.moolah.continue`) so a user looking at a place in Moolah on iPhone can resume on Mac and vice versa.

**Architecture:** A new `Automation/Handoff/` folder defines the activity-type constant, a `Codable` payload `{ profileID: UUID, destination: NavigationDestination }`, `NSUserActivity` configure/decode helpers, and a `HandoffContinuationHandler` that drives the existing `NavigationBridge`. macOS receives via `NSApplicationDelegate.application(_:continue:restorationHandler:)` after the `WindowGroup` is opted out of SwiftUI's external-event auto-spawn; iOS receives via `.onContinueUserActivity`. Both window roots publish via `.userActivity(...)` keyed on a per-window "current route" derived from existing + new `@FocusedSceneValue`s plus a pure `NavigationDestination.from(...)`.

**Tech Stack:** Swift 6, SwiftUI, AppKit (`NSApplicationDelegate` on macOS), `NSUserActivity` (Foundation), Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`), `swift-format`, SwiftLint, `xcodegen` (project regeneration).

**Spec:** `plans/2026-05-25-handoff-design.md`.

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `Automation/Handoff/HandoffActivity.swift` | Namespace with the activity-type string constant. |
| `Automation/Handoff/HandoffPayload.swift` | `Codable, Equatable, Sendable` payload `{ profileID, destination }`. |
| `Automation/Handoff/NSUserActivity+Handoff.swift` | `configureContinueActivity(_:payload:title:)` and `handoffPayload` getter. |
| `Automation/Handoff/HandoffContinuationHandler.swift` | `@MainActor enum` with `continue(payload:)` that drives `NavigationBridge`. |
| `Automation/Handoff/HandoffTitleProvider.swift` | Pure title producer used by the `.userActivity(...)` closure. |
| `Automation/Navigation/AnalysisRouteParams.swift` | `Hashable, Sendable` struct `{ history: Int?, forecast: Int? }` for the focused-scene value. |
| `Automation/Navigation/ReportsRouteParams.swift` | `Hashable, Sendable` struct `{ from: Date?, to: Date? }` for the focused-scene value. |
| `Automation/Navigation/SidebarSelection+NavigationDestination.swift` | `var navigationDestination: NavigationDestination?` extension. |
| `Automation/Navigation/NavigationDestination+From.swift` | Pure `static func from(sidebar:selectedTransaction:analysis:reports:)`. |
| `MoolahTests/Automation/HandoffPayloadCodableTests.swift` | Round-trip every `NavigationDestination` case. |
| `MoolahTests/Automation/NSUserActivityHandoffTests.swift` | Activity-field stamping + decode round-trip. |
| `MoolahTests/Automation/HandoffContinuationHandlerTests.swift` | Bridge fake → ordering / locator branching. |
| `MoolahTests/Automation/SidebarSelectionRouteTests.swift` | Sidebar → destination mapping. |
| `MoolahTests/Automation/NavigationDestinationFromTests.swift` | Pure `from(...)` precedence rules. |
| `MoolahTests/Automation/HandoffTitleProviderTests.swift` | Title cases (account, earmark, transaction, static). |
| `MoolahTests/Automation/ScriptingBridgeHandoffTests.swift` | Delegate path with real `NSUserActivity` (macOS-guarded). |

### Modified files

| Path | Change |
|---|---|
| `Automation/Navigation/NavigationDestination.swift` | Add `Codable` conformance. |
| `Shared/FocusedValues.swift` | Add `SelectedTransactionIDKey`, `AnalysisRouteKey`, `ReportsRouteKey`. |
| `Automation/AppleScript/ScriptingBridge.swift` | Implement `application(_:continue:restorationHandler:)` (macOS only). |
| `App/MoolahApp.swift` | macOS `WindowGroup` adds `.handlesExternalEvents(matching: [])`. |
| `App/ProfileWindowView.swift` | Add `.userActivity(...)` modifier + handoff helper subview. |
| `App/ProfileRootView.swift` | Add `.userActivity(...)` + `.onContinueUserActivity(...)`. |
| `Features/Analysis/AnalysisView.swift` | Publish `\.analysisRoute`. |
| `Features/Reports/ReportsView.swift` | Publish `\.reportsRoute`. |
| `Features/Transactions/AllTransactionsView.swift` | Publish `\.selectedTransactionID`. |
| `Features/Transactions/UpcomingView.swift` | Publish `\.selectedTransactionID`. |
| Account-detail views (`StandardAccountView`, `InvestmentAccountView`, `CryptoWalletAccountView`, `ExchangeAccountView`) | Publish `\.selectedTransactionID`. |
| `App/Info-iOS.plist`, `App/Info-macOS.plist` | Add `NSUserActivityTypes = ["com.moolah.continue"]`. |
| `project.yml` | New `Automation/Handoff/` folder is picked up automatically by globbed sources; nothing to add. New test files are picked up by `MoolahTests/**/*.swift`; nothing to add. **Verify by running `just generate` after creating new files.** |

### Commit / PR strategy

Tasks 1–6 below are landable PRs. Each ends with a `just format-check && just test-mac && just test-ios` gate (per [[feedback_format_check_per_plan_step]]). Tasks 1, 2, and 5 are pure types / pure logic; tasks 3, 4, and 6 wire UI. The user-visible feature lights up at the end of task 6.

---

## Task 1: Activity types and codec

**Files:**
- Create: `Automation/Handoff/HandoffActivity.swift`
- Create: `Automation/Handoff/HandoffPayload.swift`
- Create: `Automation/Handoff/NSUserActivity+Handoff.swift`
- Modify: `Automation/Navigation/NavigationDestination.swift`
- Create: `MoolahTests/Automation/HandoffPayloadCodableTests.swift`
- Create: `MoolahTests/Automation/NSUserActivityHandoffTests.swift`

### Step 1: Add `Codable` to `NavigationDestination`

- [ ] **Step 1.1: Modify `Automation/Navigation/NavigationDestination.swift`**

Change the enum declaration line from:
```swift
enum NavigationDestination: Sendable, Equatable {
```
to:
```swift
enum NavigationDestination: Sendable, Equatable, Codable {
```

Synthesised `Codable` works because every associated value (`UUID`, `Int?`, `Date?`) is already `Codable`.

- [ ] **Step 1.2: Run `just generate` to ensure the file remains in the project graph**

```bash
just generate
```
Expected: completes without error. (Nothing should change in `Moolah.xcodeproj` because we only edited an existing file.)

### Step 2: Failing test for `HandoffPayload` round-trip

- [ ] **Step 2.1: Create `MoolahTests/Automation/HandoffPayloadCodableTests.swift`**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("HandoffPayload Codable")
struct HandoffPayloadCodableTests {

  private func roundTrip(_ payload: HandoffPayload) throws -> HandoffPayload {
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(HandoffPayload.self, from: data)
  }

  @Test("accounts case round-trips")
  func accountsRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .accounts)
    #expect(try roundTrip(payload) == payload)
  }

  @Test("account(id) case round-trips")
  func accountRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .account(UUID()))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("transaction(id) case round-trips")
  func transactionRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .transaction(UUID()))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("earmarks case round-trips")
  func earmarksRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .earmarks)
    #expect(try roundTrip(payload) == payload)
  }

  @Test("earmark(id) case round-trips")
  func earmarkRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .earmark(UUID()))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("analysis with both params round-trips")
  func analysisWithParamsRoundTrips() throws {
    let payload = HandoffPayload(
      profileID: UUID(),
      destination: .analysis(history: 12, forecast: 6))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("analysis with nil params round-trips")
  func analysisNilParamsRoundTrips() throws {
    let payload = HandoffPayload(
      profileID: UUID(),
      destination: .analysis(history: nil, forecast: nil))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("reports with both params round-trips")
  func reportsWithParamsRoundTrips() throws {
    let from = Date(timeIntervalSince1970: 1_700_000_000)
    let to = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = HandoffPayload(
      profileID: UUID(),
      destination: .reports(from: from, to: to))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("reports with nil params round-trips")
  func reportsNilParamsRoundTrips() throws {
    let payload = HandoffPayload(
      profileID: UUID(),
      destination: .reports(from: nil, to: nil))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("categories case round-trips")
  func categoriesRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .categories)
    #expect(try roundTrip(payload) == payload)
  }

  @Test("upcoming case round-trips")
  func upcomingRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .upcoming)
    #expect(try roundTrip(payload) == payload)
  }
}
```

- [ ] **Step 2.2: Run the test to verify it fails**

```bash
just test-mac HandoffPayloadCodableTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: compile failure on `HandoffPayload` (not yet defined).

### Step 3: Implement `HandoffActivity` and `HandoffPayload`

- [ ] **Step 3.1: Create `Automation/Handoff/HandoffActivity.swift`**

```swift
import Foundation

/// Shared constants for Moolah's Handoff (`NSUserActivity`) integration.
enum HandoffActivity {
  /// The `NSUserActivity.activityType` used for all Handoff continuation
  /// between Moolah devices. Must match the entry in `NSUserActivityTypes`
  /// in `App/Info-iOS.plist` and `App/Info-macOS.plist`.
  static let continueActivityType = "com.moolah.continue"
}
```

- [ ] **Step 3.2: Create `Automation/Handoff/HandoffPayload.swift`**

```swift
import Foundation

/// The payload exchanged between Moolah devices to resume a navigation
/// location via Handoff. Encoded as JSON into
/// `NSUserActivity.userInfo["payload"]`.
struct HandoffPayload: Codable, Equatable, Sendable {
  let profileID: UUID
  let destination: NavigationDestination
}
```

- [ ] **Step 3.3: Run `just generate`**

```bash
just generate
```
Expected: completes without error; new files appear under the `Automation` group in `Moolah.xcodeproj`.

- [ ] **Step 3.4: Re-run the test to verify it passes**

```bash
just test-mac HandoffPayloadCodableTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: all 11 tests pass.

### Step 4: Failing test for `NSUserActivity` extensions

- [ ] **Step 4.1: Create `MoolahTests/Automation/NSUserActivityHandoffTests.swift`**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("NSUserActivity Handoff")
struct NSUserActivityHandoffTests {

  private func samplePayload() -> HandoffPayload {
    HandoffPayload(
      profileID: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
      destination: .account(UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!))
  }

  @Test("configureContinueActivity stamps every required field")
  func configureStampsFields() throws {
    let payload = samplePayload()
    let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
    NSUserActivity.configureContinueActivity(activity, payload: payload, title: "Chase Checking")

    #expect(activity.activityType == HandoffActivity.continueActivityType)
    #expect(activity.title == "Chase Checking")
    #expect(activity.targetContentIdentifier == payload.profileID.uuidString)
    #expect(activity.isEligibleForHandoff)
    #expect(!activity.isEligibleForSearch)
    #expect(!activity.isEligibleForPublicIndexing)
    #expect(activity.requiredUserInfoKeys == ["payload"])
    let payloadData = try #require(activity.userInfo?["payload"] as? Data)
    let decoded = try JSONDecoder().decode(HandoffPayload.self, from: payloadData)
    #expect(decoded == payload)
  }

  @Test("handoffPayload recovers an identical payload")
  func handoffPayloadRoundTrips() throws {
    let payload = samplePayload()
    let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
    NSUserActivity.configureContinueActivity(activity, payload: payload, title: "x")
    let recovered = try #require(activity.handoffPayload)
    #expect(recovered == payload)
  }

  @Test("handoffPayload returns nil when userInfo lacks the payload key")
  func handoffPayloadMissingKey() {
    let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
    activity.userInfo = [:]
    #expect(activity.handoffPayload == nil)
  }

  @Test("handoffPayload returns nil for unparseable payload data")
  func handoffPayloadUnparseable() {
    let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
    activity.userInfo = ["payload": Data([0x00, 0x01, 0x02])]
    #expect(activity.handoffPayload == nil)
  }
}
```

- [ ] **Step 4.2: Run the test to verify it fails**

```bash
just test-mac NSUserActivityHandoffTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: compile failure on `configureContinueActivity` / `handoffPayload` (not yet defined).

### Step 5: Implement `NSUserActivity+Handoff`

- [ ] **Step 5.1: Create `Automation/Handoff/NSUserActivity+Handoff.swift`**

```swift
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "Handoff")

extension NSUserActivity {

  /// Stamps every field required for Moolah's Handoff continuation.
  /// Centralised so the field map in the design doc stays in sync with
  /// the call sites.
  static func configureContinueActivity(
    _ activity: NSUserActivity,
    payload: HandoffPayload,
    title: String
  ) {
    activity.title = title
    activity.targetContentIdentifier = payload.profileID.uuidString
    activity.isEligibleForHandoff = true
    activity.isEligibleForSearch = false
    activity.isEligibleForPublicIndexing = false
    activity.requiredUserInfoKeys = ["payload"]
    do {
      let data = try JSONEncoder().encode(payload)
      activity.userInfo = ["payload": data]
    } catch {
      logger.error("Failed to encode HandoffPayload: \(error.localizedDescription, privacy: .public)")
      activity.userInfo = [:]
    }
  }

  /// Decodes the payload from a continuation activity, or returns `nil`
  /// if the activity is malformed (missing key, unparseable JSON).
  var handoffPayload: HandoffPayload? {
    guard let data = userInfo?["payload"] as? Data else { return nil }
    return try? JSONDecoder().decode(HandoffPayload.self, from: data)
  }
}
```

- [ ] **Step 5.2: Run `just generate`**

```bash
just generate
```

- [ ] **Step 5.3: Re-run the test to verify it passes**

```bash
just test-mac NSUserActivityHandoffTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: all 4 tests pass.

### Step 6: Format-check and commit

- [ ] **Step 6.1: Run format-check**

```bash
just format && just format-check
```
Expected: clean. (If `just format` made changes, they're now applied; `just format-check` confirms the result is acceptable to CI.)

- [ ] **Step 6.2: Commit**

```bash
git -C . add \
  Automation/Navigation/NavigationDestination.swift \
  Automation/Handoff/HandoffActivity.swift \
  Automation/Handoff/HandoffPayload.swift \
  Automation/Handoff/NSUserActivity+Handoff.swift \
  MoolahTests/Automation/HandoffPayloadCodableTests.swift \
  MoolahTests/Automation/NSUserActivityHandoffTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(handoff): payload, activity extensions, Codable NavigationDestination

Adds the foundation for Moolah's Handoff integration: the activity-type
constant, a Codable HandoffPayload, NSUserActivity stamping/decoding
helpers, and Codable conformance on NavigationDestination. No wiring
yet — those slices follow.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 2: `HandoffContinuationHandler`

**Files:**
- Create: `Automation/Handoff/HandoffContinuationHandler.swift`
- Create: `MoolahTests/Automation/HandoffContinuationHandlerTests.swift`

### Step 1: Failing test

- [ ] **Step 1.1: Create `MoolahTests/Automation/HandoffContinuationHandlerTests.swift`**

```swift
#if os(macOS)
  import AppKit
#endif
import Foundation
import Testing

@testable import Moolah

@Suite("HandoffContinuationHandler")
@MainActor
struct HandoffContinuationHandlerTests {

  /// Captures calls into NavigationBridge so we can assert order/arguments
  /// without driving a real scene graph.
  final class BridgeRecorder {
    var openedProfiles: [UUID] = []
    var setNavigations: [PendingNavigation] = []
  }

  /// Installs recorder closures on NavigationBridge for the duration of
  /// the test, restoring the prior closures on tear-down.
  private func withRecorder<R>(_ body: (BridgeRecorder) throws -> R) rethrows -> R {
    let priorOpen = NavigationBridge.openProfile
    let priorSet = NavigationBridge.setPendingNavigation
    defer {
      NavigationBridge.openProfile = priorOpen
      NavigationBridge.setPendingNavigation = priorSet
    }
    let recorder = BridgeRecorder()
    NavigationBridge.openProfile = { recorder.openedProfiles.append($0) }
    NavigationBridge.setPendingNavigation = { recorder.setNavigations.append($0) }
    return try body(recorder)
  }

  private func samplePayload() -> HandoffPayload {
    HandoffPayload(profileID: UUID(), destination: .account(UUID()))
  }

  #if os(macOS)
    @Test("macOS: existing window → openProfile is NOT called, setPendingNavigation IS")
    func macOSExistingWindowSkipsOpen() {
      let payload = samplePayload()
      // Pre-register a window stamped with the locator's identifier so the
      // locator finds it and returns true.
      let window = NSWindow()
      window.identifier = ProfileWindowLocator.identifier(for: payload.profileID)
      NSApp.addWindowsItem(window, title: "test", filename: false)
      defer { NSApp.removeWindowsItem(window) }

      withRecorder { recorder in
        HandoffContinuationHandler.continue(payload: payload)
        #expect(recorder.openedProfiles.isEmpty)
        #expect(recorder.setNavigations.count == 1)
        #expect(recorder.setNavigations.first?.profileId == payload.profileID)
        #expect(recorder.setNavigations.first?.destination == payload.destination)
      }
    }

    @Test("macOS: no window → openProfile then setPendingNavigation, in that order")
    func macOSNoWindowOpensProfileFirst() {
      // Use a fresh UUID nothing is registered for, so the locator returns false.
      let payload = samplePayload()
      withRecorder { recorder in
        HandoffContinuationHandler.continue(payload: payload)
        #expect(recorder.openedProfiles == [payload.profileID])
        #expect(recorder.setNavigations.count == 1)
        #expect(recorder.setNavigations.first?.profileId == payload.profileID)
      }
    }
  #else
    @Test("iOS: openProfile then setPendingNavigation, in that order")
    func iOSAlwaysOpensProfileFirst() {
      let payload = samplePayload()
      withRecorder { recorder in
        HandoffContinuationHandler.continue(payload: payload)
        #expect(recorder.openedProfiles == [payload.profileID])
        #expect(recorder.setNavigations.count == 1)
        #expect(recorder.setNavigations.first?.profileId == payload.profileID)
      }
    }
  #endif
}
```

- [ ] **Step 1.2: Run the test to verify it fails**

```bash
just test-mac HandoffContinuationHandlerTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: compile failure on `HandoffContinuationHandler` (not yet defined).

### Step 2: Implement the handler

- [ ] **Step 2.1: Create `Automation/Handoff/HandoffContinuationHandler.swift`**

```swift
import Foundation
import OSLog

private let logger = Logger(subsystem: "com.moolah.app", category: "Handoff")

/// Single entry point for resuming a Handoff activity. Reuses the existing
/// `NavigationBridge` that AppleScript and App Intents already drive.
///
/// On macOS, the bridge is only called for `openProfile` when no window is
/// already showing the target profile — otherwise `ProfileWindowLocator`
/// brings the existing window forward and we skip straight to setting the
/// pending navigation.
@MainActor
enum HandoffContinuationHandler {

  static func `continue`(payload: HandoffPayload) {
    let nav = PendingNavigation(
      profileId: payload.profileID,
      destination: payload.destination)
    #if os(macOS)
      if !ProfileWindowLocator.activateExistingWindow(for: payload.profileID) {
        guard let opener = NavigationBridge.openProfile else {
          logger.warning("NavigationBridge.openProfile unset — dropping handoff")
          return
        }
        opener(payload.profileID)
      }
    #else
      guard let opener = NavigationBridge.openProfile else {
        logger.warning("NavigationBridge.openProfile unset — dropping handoff")
        return
      }
      opener(payload.profileID)
    #endif

    guard let setter = NavigationBridge.setPendingNavigation else {
      logger.warning("NavigationBridge.setPendingNavigation unset — dropping handoff")
      return
    }
    setter(nav)
  }
}
```

- [ ] **Step 2.2: Run `just generate`**

```bash
just generate
```

- [ ] **Step 2.3: Re-run the test to verify it passes**

```bash
just test-mac HandoffContinuationHandlerTests 2>&1 | tee .agent-tmp/test-output.txt
just test-ios HandoffContinuationHandlerTests 2>&1 | tee .agent-tmp/test-output-ios.txt
```
Expected: all platform-appropriate cases pass.

### Step 3: Format-check and commit

- [ ] **Step 3.1: Format-check**

```bash
just format && just format-check
```

- [ ] **Step 3.2: Commit**

```bash
git -C . add \
  Automation/Handoff/HandoffContinuationHandler.swift \
  MoolahTests/Automation/HandoffContinuationHandlerTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(handoff): HandoffContinuationHandler reuses NavigationBridge

Drives the existing NavigationBridge (also used by AppleScript and
App Intents). On macOS, opens a new window only when the locator finds
no existing window for the target profile.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 3: macOS receiving — delegate + WindowGroup opt-out + Info.plist

**Files:**
- Modify: `Automation/AppleScript/ScriptingBridge.swift`
- Modify: `App/MoolahApp.swift`
- Modify: `App/Info-macOS.plist`
- Create: `MoolahTests/Automation/ScriptingBridgeHandoffTests.swift`

### Step 1: Failing integration test

- [ ] **Step 1.1: Create `MoolahTests/Automation/ScriptingBridgeHandoffTests.swift`**

```swift
#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  @testable import Moolah

  @Suite("ScriptingBridge Handoff")
  @MainActor
  struct ScriptingBridgeHandoffTests {

    final class BridgeRecorder {
      var openedProfiles: [UUID] = []
      var setNavigations: [PendingNavigation] = []
    }

    private func withRecorder<R>(_ body: (BridgeRecorder) throws -> R) rethrows -> R {
      let priorOpen = NavigationBridge.openProfile
      let priorSet = NavigationBridge.setPendingNavigation
      defer {
        NavigationBridge.openProfile = priorOpen
        NavigationBridge.setPendingNavigation = priorSet
      }
      let recorder = BridgeRecorder()
      NavigationBridge.openProfile = { recorder.openedProfiles.append($0) }
      NavigationBridge.setPendingNavigation = { recorder.setNavigations.append($0) }
      return try body(recorder)
    }

    private func makeActivity(_ payload: HandoffPayload) -> NSUserActivity {
      let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
      NSUserActivity.configureContinueActivity(activity, payload: payload, title: "t")
      return activity
    }

    @Test("returns true and drives the bridge for a valid continuation activity")
    func validActivityDrivesBridge() {
      let payload = HandoffPayload(profileID: UUID(), destination: .accounts)
      let bridge = ScriptingBridge()
      let activity = makeActivity(payload)

      withRecorder { recorder in
        let handled = bridge.application(
          NSApp,
          continue: activity,
          restorationHandler: { _ in })
        #expect(handled)
        #expect(recorder.openedProfiles == [payload.profileID])
        #expect(recorder.setNavigations.count == 1)
      }
    }

    @Test("returns false for an activity with the wrong type")
    func wrongTypeReturnsFalse() {
      let activity = NSUserActivity(activityType: "com.example.other")
      let bridge = ScriptingBridge()

      withRecorder { recorder in
        let handled = bridge.application(
          NSApp,
          continue: activity,
          restorationHandler: { _ in })
        #expect(!handled)
        #expect(recorder.openedProfiles.isEmpty)
        #expect(recorder.setNavigations.isEmpty)
      }
    }

    @Test("returns false when the payload is missing")
    func missingPayloadReturnsFalse() {
      let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
      // No userInfo set — handoffPayload returns nil.
      let bridge = ScriptingBridge()

      withRecorder { recorder in
        let handled = bridge.application(
          NSApp,
          continue: activity,
          restorationHandler: { _ in })
        #expect(!handled)
        #expect(recorder.openedProfiles.isEmpty)
        #expect(recorder.setNavigations.isEmpty)
      }
    }

    @Test("returns false when the payload is unparseable")
    func unparseablePayloadReturnsFalse() {
      let activity = NSUserActivity(activityType: HandoffActivity.continueActivityType)
      activity.userInfo = ["payload": Data([0xFF, 0xFE])]
      let bridge = ScriptingBridge()

      withRecorder { recorder in
        let handled = bridge.application(
          NSApp,
          continue: activity,
          restorationHandler: { _ in })
        #expect(!handled)
        #expect(recorder.openedProfiles.isEmpty)
        #expect(recorder.setNavigations.isEmpty)
      }
    }
  }
#endif
```

- [ ] **Step 1.2: Run the test to verify it fails**

```bash
just test-mac ScriptingBridgeHandoffTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: compile failure on `application(_:continue:restorationHandler:)` (not yet implemented on `ScriptingBridge`).

### Step 2: Implement the delegate method

- [ ] **Step 2.1: Modify `Automation/AppleScript/ScriptingBridge.swift`**

Add the following method inside the `class ScriptingBridge` body, immediately after `applicationDidFinishLaunching(_:)`:

```swift
    /// Receives Handoff `NSUserActivity` continuations from the OS. Routes
    /// them through `HandoffContinuationHandler`, which drives the same
    /// `NavigationBridge` that AppleScript and App Intents use. The
    /// `WindowGroup` is opted out of SwiftUI external-event handling (see
    /// `MoolahApp.swift`), so this delegate is the sole entry point on
    /// macOS.
    @MainActor
    func application(_ application: NSApplication,
                     continue userActivity: NSUserActivity,
                     restorationHandler: @escaping ([any NSUserActivityRestoring]) -> Void
    ) -> Bool {
      guard userActivity.activityType == HandoffActivity.continueActivityType,
            let payload = userActivity.handoffPayload
      else {
        logger.warning("Ignoring handoff activity: missing or undecodable payload")
        return false
      }
      HandoffContinuationHandler.continue(payload: payload)
      return true
    }
```

- [ ] **Step 2.2: Run the test to verify it passes**

```bash
just test-mac ScriptingBridgeHandoffTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: all 4 tests pass.

### Step 3: Opt the WindowGroup out of SwiftUI external-event auto-spawn

- [ ] **Step 3.1: Modify `App/MoolahApp.swift`**

Find the macOS `WindowGroup(id: Self.mainWindowID, for: Profile.ID.self)` block (currently around lines 127–159). After the closing brace of the `WindowGroup { … }` block but **before** `.restorationBehavior(...)`, insert:

```swift
      // Opt out of SwiftUI's external-event auto-spawn. Handoff
      // continuations arrive via `ScriptingBridge.application(_:continue:…)`
      // and are routed in-process through `NavigationBridge`. See
      // `plans/2026-05-25-handoff-design.md` and issue #386.
      .handlesExternalEvents(matching: [])
```

The resulting modifier chain order is: `WindowGroup { … } .handlesExternalEvents(matching: []) .restorationBehavior(...) .onChange(of: scenePhase) { … } .commands { … }`.

- [ ] **Step 3.2: Build to confirm SwiftUI still compiles**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
```
Expected: clean build.

### Step 4: Register the activity type in `Info-macOS.plist`

- [ ] **Step 4.1: Modify `App/Info-macOS.plist`**

Add this entry inside the top-level `<dict>` (e.g. right before `</dict>` at the end):

```xml
    <key>NSUserActivityTypes</key>
    <array>
        <string>com.moolah.continue</string>
    </array>
```

- [ ] **Step 4.2: Run `just generate` and rebuild**

```bash
just generate && just build-mac 2>&1 | tee .agent-tmp/build.txt
```
Expected: clean build; the built app's `Info.plist` contains the new key (verifiable via `plutil -p build/Build/Products/Debug/Moolah.app/Contents/Info.plist | grep NSUserActivityTypes` if needed).

### Step 5: Full test sweep + format-check

- [ ] **Step 5.1: Run the full macOS test suite**

```bash
just test-mac 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: 0 failures.

- [ ] **Step 5.2: Run format-check**

```bash
just format && just format-check
```

- [ ] **Step 5.3: Commit**

```bash
git -C . add \
  Automation/AppleScript/ScriptingBridge.swift \
  App/MoolahApp.swift \
  App/Info-macOS.plist \
  MoolahTests/Automation/ScriptingBridgeHandoffTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(handoff): macOS receive via NSApplicationDelegate, WindowGroup opt-out

Adds application(_:continue:restorationHandler:) to ScriptingBridge,
routes through HandoffContinuationHandler. WindowGroup gets
.handlesExternalEvents(matching: []) so the delegate is the sole
external-event entry point (avoids the auto-spawn bug from #386).

Info-macOS.plist registers NSUserActivityTypes = ["com.moolah.continue"].

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 4: iOS receiving — `.onContinueUserActivity` + Info.plist

**Files:**
- Modify: `App/ProfileRootView.swift`
- Modify: `App/Info-iOS.plist`

(No new tests — `HandoffContinuationHandlerTests` already covers the iOS receive branch. The SwiftUI modifier itself is one line and not separately testable without a UI test.)

### Step 1: Add the `.onContinueUserActivity(...)` modifier

- [ ] **Step 1.1: Modify `App/ProfileRootView.swift`**

Add this modifier to the outermost `Group { … }` view, after the existing `.task { … }` modifier (the one that wires `NavigationBridge`):

```swift
      .onContinueUserActivity(HandoffActivity.continueActivityType) { activity in
        guard let payload = activity.handoffPayload else {
          // Logged inside HandoffContinuationHandler / extensions — no
          // need to duplicate here.
          return
        }
        HandoffContinuationHandler.continue(payload: payload)
      }
```

- [ ] **Step 1.2: Build to confirm SwiftUI compiles**

```bash
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```
Expected: clean build.

### Step 2: Register the activity type in `Info-iOS.plist`

- [ ] **Step 2.1: Modify `App/Info-iOS.plist`**

Add this entry inside the top-level `<dict>` (e.g. before `</dict>`):

```xml
    <key>NSUserActivityTypes</key>
    <array>
        <string>com.moolah.continue</string>
    </array>
```

- [ ] **Step 2.2: Regenerate and rebuild**

```bash
just generate && just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```
Expected: clean build.

### Step 3: Full test sweep + format-check

- [ ] **Step 3.1: Full test sweep**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: 0 failures across both platforms.

- [ ] **Step 3.2: Format-check**

```bash
just format && just format-check
```

- [ ] **Step 3.3: Commit**

```bash
git -C . add \
  App/ProfileRootView.swift \
  App/Info-iOS.plist
git -C . commit -m "$(cat <<'EOF'
feat(handoff): iOS receive via .onContinueUserActivity

Adds the SwiftUI continuation modifier on ProfileRootView and registers
NSUserActivityTypes = ["com.moolah.continue"] in Info-iOS.plist.
Routes through the platform-shared HandoffContinuationHandler.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 5: Route assembly — focused-scene values + pure `from(...)`

**Files:**
- Create: `Automation/Navigation/AnalysisRouteParams.swift`
- Create: `Automation/Navigation/ReportsRouteParams.swift`
- Create: `Automation/Navigation/SidebarSelection+NavigationDestination.swift`
- Create: `Automation/Navigation/NavigationDestination+From.swift`
- Modify: `Shared/FocusedValues.swift`
- Modify: `Features/Analysis/AnalysisView.swift`
- Modify: `Features/Reports/ReportsView.swift`
- Modify: `Features/Transactions/AllTransactionsView.swift`
- Modify: `Features/Transactions/UpcomingView.swift`
- Modify: each account-detail view (`Features/Accounts/StandardAccountView.swift`, `Features/Investments/InvestmentAccountView.swift`, `Features/Crypto/CryptoWalletAccountView.swift`, `Features/Exchange/ExchangeAccountView.swift`)
- Create: `MoolahTests/Automation/SidebarSelectionRouteTests.swift`
- Create: `MoolahTests/Automation/NavigationDestinationFromTests.swift`

### Step 1: Failing test — `SidebarSelection.navigationDestination`

- [ ] **Step 1.1: Create `MoolahTests/Automation/SidebarSelectionRouteTests.swift`**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("SidebarSelection → NavigationDestination")
struct SidebarSelectionRouteTests {

  @Test("account selection maps to .account")
  func accountMaps() {
    let id = UUID()
    #expect(SidebarSelection.account(id).navigationDestination == .account(id))
  }

  @Test("earmark selection maps to .earmark")
  func earmarkMaps() {
    let id = UUID()
    #expect(SidebarSelection.earmark(id).navigationDestination == .earmark(id))
  }

  @Test("allTransactions maps to .accounts")
  func allTransactionsMaps() {
    #expect(SidebarSelection.allTransactions.navigationDestination == .accounts)
  }

  @Test("recentlyAdded maps to .accounts")
  func recentlyAddedMaps() {
    #expect(SidebarSelection.recentlyAdded.navigationDestination == .accounts)
  }

  @Test("upcomingTransactions maps to .upcoming")
  func upcomingMaps() {
    #expect(SidebarSelection.upcomingTransactions.navigationDestination == .upcoming)
  }

  @Test("categories maps to .categories")
  func categoriesMaps() {
    #expect(SidebarSelection.categories.navigationDestination == .categories)
  }

  @Test("reports maps to .reports with nil params")
  func reportsMaps() {
    #expect(SidebarSelection.reports.navigationDestination == .reports(from: nil, to: nil))
  }

  @Test("analysis maps to .analysis with nil params")
  func analysisMaps() {
    #expect(SidebarSelection.analysis.navigationDestination == .analysis(history: nil, forecast: nil))
  }
}
```

- [ ] **Step 1.2: Run to verify it fails**

```bash
just test-mac SidebarSelectionRouteTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: compile failure on `.navigationDestination` accessor.

### Step 2: Implement `SidebarSelection.navigationDestination`

- [ ] **Step 2.1: Create `Automation/Navigation/SidebarSelection+NavigationDestination.swift`**

```swift
import Foundation

extension SidebarSelection {

  /// Pure mapping from a sidebar selection to the equivalent
  /// `NavigationDestination`. Used by Handoff (publishing) and by anything
  /// else that needs a route representation of "where the sidebar is."
  ///
  /// `analysis` and `reports` map to their parameterless forms here;
  /// callers that want to overlay the current screen-level state should
  /// use `NavigationDestination.from(sidebar:selectedTransaction:analysis:reports:)`
  /// instead.
  var navigationDestination: NavigationDestination {
    switch self {
    case .account(let id): .account(id)
    case .earmark(let id): .earmark(id)
    case .allTransactions, .recentlyAdded: .accounts
    case .upcomingTransactions: .upcoming
    case .categories: .categories
    case .reports: .reports(from: nil, to: nil)
    case .analysis: .analysis(history: nil, forecast: nil)
    }
  }
}
```

- [ ] **Step 2.2: Run `just generate` and re-test**

```bash
just generate && just test-mac SidebarSelectionRouteTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: all 8 tests pass.

### Step 3: Failing test — `NavigationDestination.from(...)`

- [ ] **Step 3.1: Create `MoolahTests/Automation/NavigationDestinationFromTests.swift`**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("NavigationDestination.from")
struct NavigationDestinationFromTests {

  @Test("nil sidebar produces nil")
  func nilSidebarProducesNil() {
    #expect(NavigationDestination.from(
      sidebar: nil,
      selectedTransaction: nil,
      analysis: nil,
      reports: nil) == nil)
  }

  @Test("transaction selection wins over sidebar")
  func transactionWinsOverSidebar() {
    let txn = UUID()
    let result = NavigationDestination.from(
      sidebar: .allTransactions,
      selectedTransaction: txn,
      analysis: nil,
      reports: nil)
    #expect(result == .transaction(txn))
  }

  @Test("transaction selection wins even with analysis params")
  func transactionWinsOverAnalysis() {
    let txn = UUID()
    let result = NavigationDestination.from(
      sidebar: .analysis,
      selectedTransaction: txn,
      analysis: AnalysisRouteParams(history: 12, forecast: 6),
      reports: nil)
    #expect(result == .transaction(txn))
  }

  @Test("sidebar alone produces the sidebar's destination")
  func sidebarAlone() {
    let acct = UUID()
    let result = NavigationDestination.from(
      sidebar: .account(acct),
      selectedTransaction: nil,
      analysis: nil,
      reports: nil)
    #expect(result == .account(acct))
  }

  @Test("analysis sidebar overlays analysis params")
  func analysisOverlaysParams() {
    let result = NavigationDestination.from(
      sidebar: .analysis,
      selectedTransaction: nil,
      analysis: AnalysisRouteParams(history: 12, forecast: 6),
      reports: nil)
    #expect(result == .analysis(history: 12, forecast: 6))
  }

  @Test("reports sidebar overlays reports params")
  func reportsOverlaysParams() {
    let from = Date(timeIntervalSince1970: 1_700_000_000)
    let to = Date(timeIntervalSince1970: 1_800_000_000)
    let result = NavigationDestination.from(
      sidebar: .reports,
      selectedTransaction: nil,
      analysis: nil,
      reports: ReportsRouteParams(from: from, to: to))
    #expect(result == .reports(from: from, to: to))
  }

  @Test("non-analysis sidebar ignores analysis params")
  func nonAnalysisIgnoresAnalysisParams() {
    let result = NavigationDestination.from(
      sidebar: .categories,
      selectedTransaction: nil,
      analysis: AnalysisRouteParams(history: 12, forecast: 6),
      reports: nil)
    #expect(result == .categories)
  }

  @Test("non-reports sidebar ignores reports params")
  func nonReportsIgnoresReportsParams() {
    let result = NavigationDestination.from(
      sidebar: .categories,
      selectedTransaction: nil,
      analysis: nil,
      reports: ReportsRouteParams(
        from: Date(timeIntervalSince1970: 1_700_000_000),
        to: nil))
    #expect(result == .categories)
  }
}
```

- [ ] **Step 3.2: Run to verify it fails**

```bash
just test-mac NavigationDestinationFromTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: compile failures on `AnalysisRouteParams`, `ReportsRouteParams`, `NavigationDestination.from(...)`.

### Step 4: Implement the route-param structs and the pure function

- [ ] **Step 4.1: Create `Automation/Navigation/AnalysisRouteParams.swift`**

```swift
import Foundation

/// Snapshot of the Analysis view's current parameters, published via a
/// `@FocusedSceneValue` so the Handoff publisher (at the window root)
/// can read them without holding a reference to the view's state.
struct AnalysisRouteParams: Hashable, Sendable {
  let history: Int?
  let forecast: Int?
}
```

- [ ] **Step 4.2: Create `Automation/Navigation/ReportsRouteParams.swift`**

```swift
import Foundation

/// Snapshot of the Reports view's current date range, published via a
/// `@FocusedSceneValue` so the Handoff publisher (at the window root)
/// can read it without holding a reference to the view's state.
struct ReportsRouteParams: Hashable, Sendable {
  let from: Date?
  let to: Date?
}
```

- [ ] **Step 4.3: Create `Automation/Navigation/NavigationDestination+From.swift`**

```swift
import Foundation

extension NavigationDestination {

  /// Assembles a route from the in-window state slices that exist on the
  /// receiving end of `@FocusedSceneValue`. Used by the Handoff publisher
  /// to compute the activity payload.
  ///
  /// Precedence:
  /// 1. If `selectedTransaction` is non-nil, the route is
  ///    `.transaction(id)` regardless of which screen is up.
  /// 2. Otherwise the sidebar's `navigationDestination` is used as the
  ///    base case, with `.analysis` / `.reports` overlaid by their
  ///    params (when supplied).
  /// 3. `nil` sidebar produces `nil` route — no Handoff activity is
  ///    advertised.
  static func from(
    sidebar: SidebarSelection?,
    selectedTransaction: UUID?,
    analysis: AnalysisRouteParams?,
    reports: ReportsRouteParams?
  ) -> NavigationDestination? {
    if let transaction = selectedTransaction {
      return .transaction(transaction)
    }
    guard let sidebar else { return nil }
    switch sidebar {
    case .analysis:
      return .analysis(history: analysis?.history, forecast: analysis?.forecast)
    case .reports:
      return .reports(from: reports?.from, to: reports?.to)
    default:
      return sidebar.navigationDestination
    }
  }
}
```

- [ ] **Step 4.4: Run `just generate` and re-test**

```bash
just generate && just test-mac NavigationDestinationFromTests SidebarSelectionRouteTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: all tests pass.

### Step 5: Add focused-scene value keys

- [ ] **Step 5.1: Modify `Shared/FocusedValues.swift`**

Add these `FocusedValueKey` types (organised alphabetically near the existing keys, e.g. after `SetTransactionTypeActionKey`):

```swift
/// The UUID of the transaction currently selected in whichever
/// transaction list owns the focused window's selection. Read-only;
/// used by the Handoff publisher to compose the current route.
struct SelectedTransactionIDKey: FocusedValueKey {
  typealias Value = UUID
}

/// The Analysis view's current parameters when it is the focused detail
/// view. Read-only; used by the Handoff publisher.
struct AnalysisRouteKey: FocusedValueKey {
  typealias Value = AnalysisRouteParams
}

/// The Reports view's current date range when it is the focused detail
/// view. Read-only; used by the Handoff publisher.
struct ReportsRouteKey: FocusedValueKey {
  typealias Value = ReportsRouteParams
}
```

Add these accessors inside the existing `extension FocusedValues { … }` block, alphabetically near the other accessors:

```swift
  var selectedTransactionID: SelectedTransactionIDKey.Value? {
    get { self[SelectedTransactionIDKey.self] }
    set { self[SelectedTransactionIDKey.self] = newValue }
  }
  var analysisRoute: AnalysisRouteKey.Value? {
    get { self[AnalysisRouteKey.self] }
    set { self[AnalysisRouteKey.self] = newValue }
  }
  var reportsRoute: ReportsRouteKey.Value? {
    get { self[ReportsRouteKey.self] }
    set { self[ReportsRouteKey.self] = newValue }
  }
```

- [ ] **Step 5.2: Build to confirm compile**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
```
Expected: clean build.

### Step 6: Publish from each detail view

For each of these views, add the corresponding modifier (the rule is: publish the value you already hold; do not lift state). Use the existing in-view variable names where they exist.

- [ ] **Step 6.1: Modify `Features/Analysis/AnalysisView.swift`**

Locate the topmost view in `body` and add (the analysis store already exposes `historyMonths` and `forecastMonths`):

```swift
.focusedSceneValue(\.analysisRoute, AnalysisRouteParams(
  history: store.historyMonths,
  forecast: store.forecastMonths))
```

If `historyMonths` / `forecastMonths` are not directly exposed on `AnalysisStore`, use whichever published properties drive the chart — the goal is "what the user is currently looking at on this screen." Apply only if those properties are `Int` or `Int?`; if they're another type, convert at the call site (this is the publish-only side, so a quick `Int(...)` is fine).

- [ ] **Step 6.2: Modify `Features/Reports/ReportsView.swift`**

Locate the topmost view in `body` and add (using whatever `@State` / store-published properties drive the date pickers):

```swift
.focusedSceneValue(\.reportsRoute, ReportsRouteParams(from: from, to: to))
```

Replace `from` and `to` with the actual local variable names. If the view holds a single `dateRange: ClosedRange<Date>?` instead of separate `from`/`to`, split it: `dateRange?.lowerBound` / `dateRange?.upperBound`.

- [ ] **Step 6.3: Modify `Features/Transactions/AllTransactionsView.swift`**

Find the existing `@State` (or store property) that holds the selected transaction id — likely `@State private var selectedTransactionID: UUID?` or `selectedTransaction?.id`. Add:

```swift
.focusedSceneValue(\.selectedTransactionID, selectedTransactionID)
```

If the existing state is a `Binding<Transaction?>` rather than an id, derive the id at the publish site:

```swift
.focusedSceneValue(\.selectedTransactionID, selectedTransaction?.id)
```

- [ ] **Step 6.4: Modify `Features/Transactions/UpcomingView.swift`**

Same as 6.3 against `UpcomingView`'s existing transaction selection state.

- [ ] **Step 6.5: Modify each account-detail view**

Repeat the same pattern in `StandardAccountView`, `InvestmentAccountView`, `CryptoWalletAccountView`, and `ExchangeAccountView`. Each of them owns a transaction-list selection — add `.focusedSceneValue(\.selectedTransactionID, …)` against that.

If a particular account-detail view does not own a transaction selection (some specialised views may not), skip it. The Handoff publisher tolerates `nil` selectedTransactionID — when no list publishes it, the route falls through to the sidebar.

- [ ] **Step 6.6: Build both platforms**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```
Expected: clean.

### Step 7: Format-check and commit

- [ ] **Step 7.1: Full test sweep**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: 0 failures.

- [ ] **Step 7.2: Format-check**

```bash
just format && just format-check
```

- [ ] **Step 7.3: Commit**

```bash
git -C . add \
  Automation/Navigation/AnalysisRouteParams.swift \
  Automation/Navigation/ReportsRouteParams.swift \
  Automation/Navigation/SidebarSelection+NavigationDestination.swift \
  Automation/Navigation/NavigationDestination+From.swift \
  Shared/FocusedValues.swift \
  Features/Analysis/AnalysisView.swift \
  Features/Reports/ReportsView.swift \
  Features/Transactions/AllTransactionsView.swift \
  Features/Transactions/UpcomingView.swift \
  Features/Accounts/StandardAccountView.swift \
  Features/Investments/InvestmentAccountView.swift \
  Features/Crypto/CryptoWalletAccountView.swift \
  Features/Exchange/ExchangeAccountView.swift \
  MoolahTests/Automation/SidebarSelectionRouteTests.swift \
  MoolahTests/Automation/NavigationDestinationFromTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(handoff): route assembly via focused-scene values + pure from(...)

Adds AnalysisRouteParams / ReportsRouteParams structs, focused-scene
value keys for selectedTransactionID / analysisRoute / reportsRoute, a
SidebarSelection → NavigationDestination mapping, and a pure
NavigationDestination.from(...) function that the Handoff publisher
will read on the window root.

Detail views publish their in-screen state via the new focused-scene
values. No consumer yet — that lands with the publisher in the next
commit.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Task 6: Publishing — `.userActivity(...)` + `HandoffTitleProvider`

**Files:**
- Create: `Automation/Handoff/HandoffTitleProvider.swift`
- Modify: `App/ProfileWindowView.swift`
- Modify: `App/ProfileRootView.swift`
- Create: `MoolahTests/Automation/HandoffTitleProviderTests.swift`

### Step 1: Failing test for `HandoffTitleProvider`

- [ ] **Step 1.1: Create `MoolahTests/Automation/HandoffTitleProviderTests.swift`**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("HandoffTitleProvider")
struct HandoffTitleProviderTests {

  // Test doubles for the protocol-shaped store lookups. They expose only
  // the methods HandoffTitleProvider relies on so we don't need to
  // construct real stores.
  struct FakeAccountLookup: HandoffAccountLookup {
    var nameByID: [UUID: String] = [:]
    func displayName(for id: UUID) -> String? { nameByID[id] }
  }
  struct FakeEarmarkLookup: HandoffEarmarkLookup {
    var nameByID: [UUID: String] = [:]
    func displayName(for id: UUID) -> String? { nameByID[id] }
  }

  @Test("account destination returns the account display name")
  func accountTitle() {
    let id = UUID()
    let accounts = FakeAccountLookup(nameByID: [id: "Chase Checking"])
    let title = HandoffTitleProvider.title(
      for: .account(id),
      accounts: accounts,
      earmarks: FakeEarmarkLookup())
    #expect(title == "Chase Checking")
  }

  @Test("account destination falls back to 'Account' when name is unknown")
  func accountTitleFallback() {
    let title = HandoffTitleProvider.title(
      for: .account(UUID()),
      accounts: FakeAccountLookup(),
      earmarks: FakeEarmarkLookup())
    #expect(title == "Account")
  }

  @Test("earmark destination returns the earmark display name")
  func earmarkTitle() {
    let id = UUID()
    let earmarks = FakeEarmarkLookup(nameByID: [id: "Holiday"])
    let title = HandoffTitleProvider.title(
      for: .earmark(id),
      accounts: FakeAccountLookup(),
      earmarks: earmarks)
    #expect(title == "Holiday")
  }

  @Test("earmark destination falls back to 'Earmark' when name is unknown")
  func earmarkTitleFallback() {
    let title = HandoffTitleProvider.title(
      for: .earmark(UUID()),
      accounts: FakeAccountLookup(),
      earmarks: FakeEarmarkLookup())
    #expect(title == "Earmark")
  }

  @Test("transaction destination returns 'Transaction'")
  func transactionTitle() {
    let title = HandoffTitleProvider.title(
      for: .transaction(UUID()),
      accounts: FakeAccountLookup(),
      earmarks: FakeEarmarkLookup())
    #expect(title == "Transaction")
  }

  @Test("static destinations return their static titles")
  func staticTitles() {
    let accounts = FakeAccountLookup()
    let earmarks = FakeEarmarkLookup()
    #expect(HandoffTitleProvider.title(for: .accounts, accounts: accounts, earmarks: earmarks) == "Accounts")
    #expect(HandoffTitleProvider.title(for: .earmarks, accounts: accounts, earmarks: earmarks) == "Earmarks")
    #expect(HandoffTitleProvider.title(for: .reports(from: nil, to: nil), accounts: accounts, earmarks: earmarks) == "Reports")
    #expect(HandoffTitleProvider.title(for: .analysis(history: nil, forecast: nil), accounts: accounts, earmarks: earmarks) == "Analysis")
    #expect(HandoffTitleProvider.title(for: .categories, accounts: accounts, earmarks: earmarks) == "Categories")
    #expect(HandoffTitleProvider.title(for: .upcoming, accounts: accounts, earmarks: earmarks) == "Upcoming")
  }
}
```

- [ ] **Step 1.2: Run to verify it fails**

```bash
just test-mac HandoffTitleProviderTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: compile failure on `HandoffAccountLookup`, `HandoffEarmarkLookup`, `HandoffTitleProvider`.

### Step 2: Implement `HandoffTitleProvider`

- [ ] **Step 2.1: Create `Automation/Handoff/HandoffTitleProvider.swift`**

```swift
import Foundation

/// Read-only window into account display names. Implemented by the real
/// `AccountStore` and by fakes in tests.
protocol HandoffAccountLookup {
  func displayName(for id: UUID) -> String?
}

/// Read-only window into earmark display names. Implemented by the real
/// `EarmarkStore` and by fakes in tests.
protocol HandoffEarmarkLookup {
  func displayName(for id: UUID) -> String?
}

/// Pure function that turns a `NavigationDestination` into the
/// human-readable title that appears in the Handoff badge / Dock icon.
///
/// Lookups are passed in as protocols so the function is testable
/// without standing up a real store. Account / earmark names are looked
/// up by id; missing names fall back to a generic "Account" / "Earmark"
/// rather than embedding the UUID, which would be unhelpful in the UI.
enum HandoffTitleProvider {

  static func title(
    for destination: NavigationDestination,
    accounts: HandoffAccountLookup,
    earmarks: HandoffEarmarkLookup
  ) -> String {
    switch destination {
    case .accounts: "Accounts"
    case .account(let id): accounts.displayName(for: id) ?? "Account"
    case .transaction: "Transaction"
    case .earmarks: "Earmarks"
    case .earmark(let id): earmarks.displayName(for: id) ?? "Earmark"
    case .analysis: "Analysis"
    case .reports: "Reports"
    case .categories: "Categories"
    case .upcoming: "Upcoming"
    }
  }
}
```

- [ ] **Step 2.2: Run `just generate` and re-test**

```bash
just generate && just test-mac HandoffTitleProviderTests 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: all tests pass.

### Step 3: Adopt the lookup protocols on the real stores

- [ ] **Step 3.1: Add `HandoffAccountLookup` conformance to `AccountStore`**

Find the file declaring `AccountStore` (likely `Features/Accounts/AccountStore.swift`). Add a conformance extension at the bottom of the file (one extension per protocol per [[feedback_specs_location]]):

```swift
extension AccountStore: HandoffAccountLookup {
  func displayName(for id: UUID) -> String? {
    accounts.by(id: id)?.label
  }
}
```

(`AccountStore` already has an `accounts` collection with `.by(id:)`; use whatever the existing display-name property is named — likely `label` or `name`. Verify by reading the `Account` model first.)

- [ ] **Step 3.2: Add `HandoffEarmarkLookup` conformance to `EarmarkStore`**

Same pattern in `Features/Earmarks/EarmarkStore.swift`:

```swift
extension EarmarkStore: HandoffEarmarkLookup {
  func displayName(for id: UUID) -> String? {
    earmarks.by(id: id)?.name
  }
}
```

(Verify the actual display-name property on `Earmark` first — likely `name`.)

- [ ] **Step 3.3: Build to verify**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
```
Expected: clean.

### Step 4: Add the publisher modifier on `ProfileWindowView` (macOS)

- [ ] **Step 4.1: Modify `App/ProfileWindowView.swift`**

Inside the `var body: some View` block, after the existing `.task { … }` modifier that wires `NavigationBridge`, add:

```swift
      .modifier(
        HandoffPublisherModifier(
          profileID: resolvedProfile?.id,
          accounts: nil,
          earmarks: nil))
```

(That's a placeholder shape — the actual modifier reads the stores from the environment; passing nils makes the modifier no-op when no profile is resolved. The full implementation is in step 4.2.)

- [ ] **Step 4.2: Define `HandoffPublisherModifier`**

Add this private struct to the bottom of `App/ProfileWindowView.swift` (inside the `#if os(macOS)` block):

```swift
private struct HandoffPublisherModifier: ViewModifier {
  let profileID: UUID?
  // Read live from environment so renames / store reloads update the badge.
  @Environment(AccountStore.self) private var accountStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @FocusedValue(\.sidebarSelection) private var sidebarSelection
  @FocusedValue(\.selectedTransactionID) private var selectedTransactionID
  @FocusedValue(\.analysisRoute) private var analysisRoute
  @FocusedValue(\.reportsRoute) private var reportsRoute

  // `accounts` / `earmarks` params on init are unused in the macOS build —
  // kept on the type so the iOS variant can share the same modifier.
  init(profileID: UUID?, accounts _: Any?, earmarks _: Any?) {
    self.profileID = profileID
  }

  private var route: NavigationDestination? {
    // `sidebarSelection` is `Binding<SidebarSelection?>?`. Chaining
    // `?.wrappedValue` would give `SidebarSelection??`; `flatMap` flattens
    // the outer optional so we pass a single-level `SidebarSelection?`.
    let sidebar = sidebarSelection.flatMap { $0.wrappedValue }
    return NavigationDestination.from(
      sidebar: sidebar,
      selectedTransaction: selectedTransactionID,
      analysis: analysisRoute,
      reports: reportsRoute)
  }

  func body(content: Content) -> some View {
    content.userActivity(
      HandoffActivity.continueActivityType,
      isActive: profileID != nil && route != nil
    ) { activity in
      guard let profileID, let route else { return }
      let payload = HandoffPayload(profileID: profileID, destination: route)
      let title = HandoffTitleProvider.title(
        for: route,
        accounts: accountStore,
        earmarks: earmarkStore)
      NSUserActivity.configureContinueActivity(activity, payload: payload, title: title)
    }
  }
}
```

Then simplify the modifier call at the usage site to:

```swift
      .modifier(HandoffPublisherModifier(profileID: resolvedProfile?.id, accounts: nil, earmarks: nil))
```

(Or drop the unused `accounts:`/`earmarks:` params from the macOS init entirely and remove them from the call site — the iOS variant can carry them if needed. Pick whichever is cleaner once the iOS variant is in place.)

- [ ] **Step 4.3: Build macOS to verify**

```bash
just build-mac 2>&1 | tee .agent-tmp/build.txt
```
Expected: clean.

### Step 5: Add the publisher modifier on `ProfileRootView` (iOS)

- [ ] **Step 5.1: Modify `App/ProfileRootView.swift`**

Define a parallel `HandoffPublisherModifier` private struct at the bottom of `ProfileRootView.swift` (inside the `#if os(iOS)` block). The structure is identical to the macOS variant except for the `profileID` source — on iOS the active profile is `profileStore.activeProfileID`:

```swift
private struct HandoffPublisherModifier: ViewModifier {
  @Environment(ProfileStore.self) private var profileStore
  @Environment(AccountStore.self) private var accountStore
  @Environment(EarmarkStore.self) private var earmarkStore
  @FocusedValue(\.sidebarSelection) private var sidebarSelection
  @FocusedValue(\.selectedTransactionID) private var selectedTransactionID
  @FocusedValue(\.analysisRoute) private var analysisRoute
  @FocusedValue(\.reportsRoute) private var reportsRoute

  private var route: NavigationDestination? {
    // `sidebarSelection` is `Binding<SidebarSelection?>?`. Chaining
    // `?.wrappedValue` would give `SidebarSelection??`; `flatMap` flattens
    // the outer optional so we pass a single-level `SidebarSelection?`.
    let sidebar = sidebarSelection.flatMap { $0.wrappedValue }
    return NavigationDestination.from(
      sidebar: sidebar,
      selectedTransaction: selectedTransactionID,
      analysis: analysisRoute,
      reports: reportsRoute)
  }

  func body(content: Content) -> some View {
    content.userActivity(
      HandoffActivity.continueActivityType,
      isActive: profileStore.activeProfileID != nil && route != nil
    ) { activity in
      guard
        let profileID = profileStore.activeProfileID,
        let route
      else { return }
      let payload = HandoffPayload(profileID: profileID, destination: route)
      let title = HandoffTitleProvider.title(
        for: route,
        accounts: accountStore,
        earmarks: earmarkStore)
      NSUserActivity.configureContinueActivity(activity, payload: payload, title: title)
    }
  }
}
```

Add the modifier on the existing `Group { … }` block, after the existing `.onContinueUserActivity(...)` modifier (so the publisher and the receiver live next to each other):

```swift
      .modifier(HandoffPublisherModifier())
```

- [ ] **Step 5.2: Build iOS to verify**

```bash
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```
Expected: clean.

### Step 6: Full test sweep, manual smoke, commit

- [ ] **Step 6.1: Full test sweep**

```bash
just test 2>&1 | tee .agent-tmp/test-output.txt
```
Expected: 0 failures across both platforms.

- [ ] **Step 6.2: Format-check**

```bash
just format && just format-check
```

- [ ] **Step 6.3: Manual smoke test**

Build and install Moolah on both an iPhone and a Mac signed into the same iCloud account. Enable Handoff in both devices' system settings (iOS: Settings → General → AirDrop & Handoff; macOS: System Settings → General → AirDrop & Handoff).

Run the *Manual verification checklist* from the design doc (`plans/2026-05-25-handoff-design.md` § Testing § Manual verification checklist):

1. Same-profile, profile already open on Mac → Mac window comes forward, navigates to the right place; no second window.
2. Same-profile, profile not open on Mac → Mac opens the profile and navigates.
3. Activity for a profile UUID not present in destination → Handoff badge appears but tap is a no-op; warning logged.
4. iPhone → Mac for each destination type (`.accounts`, `.account`, `.transaction`, `.earmarks`, `.earmark`, `.analysis`, `.reports`, `.categories`, `.upcoming`).
5. Mac → iPhone for the same set.
6. Switch active profile on the sender while the receiver's Handoff badge is visible → badge updates or disappears.

Log inspection on the receiver: `log stream --predicate 'subsystem == "com.moolah.app" AND category == "Handoff"' --info` should show the activity flow.

If any step fails, fix the underlying issue (do not amend a previous commit — open a follow-up). Likely failure modes are: missing or duplicate `.focusedSceneValue` publisher on a detail view, a store conformance returning the wrong property, or an environment object not in scope inside `HandoffPublisherModifier`.

- [ ] **Step 6.4: Commit**

```bash
git -C . add \
  Automation/Handoff/HandoffTitleProvider.swift \
  App/ProfileWindowView.swift \
  App/ProfileRootView.swift \
  Features/Accounts/AccountStore.swift \
  Features/Earmarks/EarmarkStore.swift \
  MoolahTests/Automation/HandoffTitleProviderTests.swift
git -C . commit -m "$(cat <<'EOF'
feat(handoff): publish per-window NSUserActivity from window roots

Adds HandoffTitleProvider + HandoffPublisherModifier on both window
roots. Publisher reads sidebar / selected transaction / analysis /
reports state from focused-scene values, composes a NavigationDestination
via the pure from(...), and stamps the activity through the
NSUserActivity extension.

Handoff is now live end-to-end. The manual smoke test in the design
doc's verification checklist is the user-facing acceptance gate.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review notes (already applied)

- **Spec coverage:** Every requirement in the design's Goals / Architecture / Where the current route comes from / Publishing / Receiving (macOS) / Receiving (iOS) / Failure handling / Testing sections has a corresponding task above. The single non-test deliverable that lacked a task was the `NavigationBridge.openProfile` nil-guard logging — folded into Task 2 step 2.1.
- **Placeholder scan:** No "TBD" / "implement appropriate" / unreferenced types. The one "verify the actual property name" note (in Task 6 step 3) is a documented inspection step, not a missing detail — the reader will see the existing property when they open the file.
- **Type consistency:** `HandoffPayload`, `HandoffActivity.continueActivityType`, `NavigationDestination.from(sidebar:selectedTransaction:analysis:reports:)`, `AnalysisRouteParams`, `ReportsRouteParams`, `HandoffAccountLookup.displayName(for:)`, `HandoffEarmarkLookup.displayName(for:)`, `HandoffTitleProvider.title(for:accounts:earmarks:)`, and `HandoffContinuationHandler.continue(payload:)` all use the same signatures across every task that references them.
