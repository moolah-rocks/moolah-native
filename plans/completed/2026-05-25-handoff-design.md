# Handoff (NSUserActivity) between iOS and macOS — Design

**Date:** 2026-05-25
**Status:** Design — pending plan
**Author:** Adrian Sutton (with Claude)
**Related:** issues [#378](https://github.com/moolah-rocks/moolah-native/pull/378) and [#386](https://github.com/moolah-rocks/moolah-native/issues/386) (URL-scheme auto-spawn — closed), `Automation/Navigation/NavigationBridge.swift`, `Automation/Navigation/NavigationDestination.swift`, `App/ProfileWindowLocator.swift`.

## Summary

Add Apple Handoff so a user looking at "a place" in Moolah on iPhone can pick up at the same place on Mac (and vice versa). Implemented via `NSUserActivity` with type `com.moolah.continue`, carrying a profile UUID plus a `NavigationDestination`. Routing on the receiving device reuses the existing in-process `NavigationBridge` that already serves AppleScript and App Intents. On macOS, the `WindowGroup` is opted out of SwiftUI's external-event auto-spawn (the cause of [#386](https://github.com/moolah-rocks/moolah-native/issues/386)) and an `NSApplicationDelegate` callback is the sole entry point.

## Goals

- A user viewing a place on one device can resume at the same place on the other device's Handoff badge (Dock on macOS, lock-screen / multitasking switcher on iOS).
- "Place" covers everything `NavigationDestination` already models: `.accounts`, `.account(id)`, `.transaction(id)`, `.earmarks`, `.earmark(id)`, `.analysis(history:forecast:)`, `.reports(from:to:)`, `.categories`, `.upcoming`.
- If the destination device already has a window open for the activity's profile, that existing window is brought forward — no duplicate windows (the [#378](https://github.com/moolah-rocks/moolah-native/pull/378) / [#386](https://github.com/moolah-rocks/moolah-native/issues/386) class of bug).
- If the destination device does not currently have the activity's profile open, it opens the profile (same code path as picking it from the profile list) and then applies the destination.
- Bidirectional: iOS↔macOS, symmetric.

## Non-goals

- iPad Stage Manager / multi-window dedup. iOS uses a single `WindowGroup`; same as the existing AppleScript / App Intents path.
- Spotlight indexing of activities (`isEligibleForSearch = false`).
- Siri / Shortcuts integration via activities (App Intents already cover that surface).
- Reviving the `moolah://` URL scheme. Issue [#386](https://github.com/moolah-rocks/moolah-native/issues/386) remains closed-as-rejected.
- Transferring ephemeral view state (in-progress new-transaction form drafts, scroll position, search/filter strings). Strictly "which place are you in."
- Cross-iCloud-account Handoff. The profile UUID space is per iCloud account; activities only resolve when both devices have the matching profile synced.
- App-level Handoff toggle. Users disable Handoff system-wide if they don't want it.
- Adopting the new `HandoffContinuationHandler` in `NavigateCommand` / `OpenAccountIntent` to eliminate the small duplication that exists there. Can land as a separate refactor.

## Background

Two prior incidents shape this design:

- **#378** — Opening a `moolah://<profile>` URL while a window for that profile was already open spawned a second window. Fix [PR #380](https://github.com/moolah-rocks/moolah-native/pull/380) made AppleScript / App Intents drive the UI in-process via `NavigationBridge`, bypassing the URL event entirely.
- **#386** — Spun out of #378. SwiftUI's `WindowGroup(for: Profile.ID.self)` auto-spawns a window on any URL / activity arrival, independent of `.onOpenURL`. The new window gets a `nil` binding because the URL did not decode to a `Profile.ID`. Closed without re-introducing the URL scheme; the design conclusion was that OS-event routing into a multi-window-per-profile app must not rely on `WindowGroup(for:)` auto-spawn.

Handoff is an OS event we cannot avoid, so we must solve the auto-spawn problem this time rather than route around it. The chosen mechanism is `Scene.handlesExternalEvents(matching: [])`, which opts the `WindowGroup` out of external-event handling entirely, plus an `NSApplicationDelegate` callback as the single explicit entry point.

## Architecture

### New types (under `Automation/Handoff/`)

- **`HandoffActivity`** — namespace with the activity-type string constant:
  ```swift
  enum HandoffActivity {
    static let continueActivityType = "com.moolah.continue"
  }
  ```
- **`HandoffPayload`** — `Codable, Equatable, Sendable` struct:
  ```swift
  struct HandoffPayload: Codable, Equatable, Sendable {
    let profileID: UUID
    let destination: NavigationDestination
  }
  ```
  Requires adding `Codable` conformance to `NavigationDestination` (currently `Sendable, Equatable`; synthesised conformance works).
- **`NSUserActivity` extensions** — `configureContinueActivity(_:payload:title:)` and a `handoffPayload` getter. Single point that stamps every required activity field; see *Activity field map* below.
- **`HandoffContinuationHandler`** — `@MainActor` static `continue(payload:)`:
  ```swift
  @MainActor
  enum HandoffContinuationHandler {
    static func `continue`(payload: HandoffPayload) {
      let nav = PendingNavigation(profileId: payload.profileID, destination: payload.destination)
      #if os(macOS)
      if !ProfileWindowLocator.activateExistingWindow(for: payload.profileID) {
        NavigationBridge.openProfile?(payload.profileID)
      }
      #else
      NavigationBridge.openProfile?(payload.profileID)
      #endif
      NavigationBridge.setPendingNavigation?(nav)
    }
  }
  ```

### Modified files

- `App/MoolahApp.swift` — macOS `WindowGroup(id:, for: Profile.ID.self)` adds `.handlesExternalEvents(matching: [])` to opt out of SwiftUI auto-spawn on external events. Existing in-process `openWindow(value:)` callers (`ProfileCommands`, `ProfileFormView`, `ExportImportButtons`, `UITestingLauncherView`) are unaffected — those are not external events.
- `App/ProfileWindowView.swift` (macOS) — adds the `.userActivity(...)` publisher modifier (see *Publishing*).
- `App/ProfileRootView.swift` (iOS) — adds the `.userActivity(...)` publisher and an `.onContinueUserActivity(HandoffActivity.continueActivityType) { … }` receiver.
- `Automation/AppleScript/ScriptingBridge.swift` (macOS) — implements `application(_:continue:restorationHandler:)`.
- `App/Info-iOS.plist` and `App/Info-macOS.plist` — add `NSUserActivityTypes = ["com.moolah.continue"]`.

### Existing infrastructure reused

- **`NavigationBridge.openProfile`** and **`setPendingNavigation`** — already populated by `ProfileRootView` (iOS) and `ProfileWindowView` (macOS); already invoked by AppleScript and App Intents. Handoff is a third caller.
- **`ProfileWindowLocator`** — already locates an open `NSWindow` for a profile UUID via a stamped `NSUserInterfaceItemIdentifier` ("moolah.profile.<uuid>") and activates it; identical use case to AppleScript and App Intents.
- **`PendingNavigation`** — already the bridge object that `ContentView` consumes on its next render.
- **`NavigationDestination`** — already the route abstraction; covers every place we want to hand off.

## Where the "current route" comes from

The publisher needs a single `NavigationDestination?` per window to advertise. Inputs:

- **Sidebar selection** — `SidebarView` already publishes `.focusedSceneValue(\.sidebarSelection, $selection)`. A new pure mapping `extension SidebarSelection { var navigationDestination: NavigationDestination? }` converts it.
- **Selected transaction** — not currently a focused-scene value. We add `\.selectedTransactionID: UUID?` (read-only), populated by whichever list view owns the selection (AllTransactions / Account detail / Upcoming).
- **Analysis history / forecast** — currently local `@State` / `@AppStorage` in the Analysis view. Expose via a new `\.analysisRoute: AnalysisRouteParams` focused-scene value, where `AnalysisRouteParams` is a small `Hashable, Sendable` struct `{ history: Int?, forecast: Int? }` (`@FocusedValue` requires `Hashable`, so the raw tuple shape won't compile).
- **Reports date range** — same shape: `\.reportsRoute: ReportsRouteParams`, where `ReportsRouteParams` is `Hashable, Sendable` with `{ from: Date?, to: Date? }`.

The window-root view reads these `@FocusedValue`s and computes the route using a pure function:

```swift
extension NavigationDestination {
  static func from(
    sidebar: SidebarSelection?,
    selectedTransaction: UUID?,
    analysis: AnalysisRouteParams?,
    reports: ReportsRouteParams?
  ) -> NavigationDestination? { … }
}
```

Priority: if `selectedTransaction != nil` → `.transaction(id)`. Otherwise the sidebar selection determines the case, overlaid with the analysis/reports params when on those screens. If no sidebar selection (e.g., on the profile picker before any profile is open), the route is `nil` and the publisher's `isActive` is `false`.

## Publishing (sender)

`ProfileWindowView` (macOS) and `ProfileRootView` (iOS) each add:

```swift
.userActivity(HandoffActivity.continueActivityType, isActive: route != nil) { activity in
  guard let route else { return }
  let payload = HandoffPayload(profileID: profileID, destination: route)
  NSUserActivity.configureContinueActivity(
    activity,
    payload: payload,
    title: HandoffTitleProvider.title(for: route, in: profileID)
  )
}
```

`HandoffTitleProvider.title(for:in:)` is a pure function that returns the human-readable title shown in the Handoff badge:

- `.account(id)` → the account's display name (looked up via `AccountStore`).
- `.earmark(id)` → the earmark's display name (via `EarmarkStore`).
- `.transaction(id)` → "Transaction" (no shorter name is reliably available; intentionally generic).
- `.accounts`, `.earmarks`, `.reports`, `.analysis`, `.categories`, `.upcoming` → static localised strings ("Accounts", "Earmarks", "Reports", "Analysis", "Categories", "Upcoming").

### Activity field map

`NSUserActivity.configureContinueActivity(_:payload:title:)` stamps:

| Field | Value | Notes |
|---|---|---|
| `activityType` | `HandoffActivity.continueActivityType` | Matches `Info.plist`. |
| `title` | from `HandoffTitleProvider` | Shown in Handoff badge / Dock icon. |
| `targetContentIdentifier` | `payload.profileID.uuidString` | Apple-standard hint for activity continuation; useful diagnostic in `NSUserActivity` dumps. Note: actual window dedup is performed by `ProfileWindowLocator` in `HandoffContinuationHandler`, not by SwiftUI's external-event matching (which is disabled — see *Receiving — macOS*). |
| `isEligibleForHandoff` | `true` | The point of the feature. |
| `isEligibleForSearch` | `false` | No Spotlight indexing. |
| `isEligibleForPublicIndexing` | `false` | Not a public web resource. |
| `requiredUserInfoKeys` | `["payload"]` | Apple uses this to know what to round-trip. |
| `userInfo` | `["payload": JSON-encoded HandoffPayload]` | The only payload. |
| `webpageURL` | unset | No public URL today. |

### Lifecycle

- When `route` changes, SwiftUI re-invokes the closure and the activity is updated in place; the OS rebroadcasts.
- When `route` becomes `nil` (profile switch, window close), `isActive: false` resigns the activity.
- The activity is per-window: each open profile window broadcasts its own current location independently. The destination side disambiguates via `targetContentIdentifier`.

## Receiving — macOS (AppKit delegate)

```swift
extension ScriptingBridge {
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
}
```

`WindowGroup.handlesExternalEvents(matching: [])` ensures the delegate is the only entry point. The continuation handler:

1. Calls `ProfileWindowLocator.activateExistingWindow(for: profileID)` — focuses the existing window if any.
2. If no window exists, calls `NavigationBridge.openProfile?(profileID)` — same code path as picking the profile from the list.
3. Calls `NavigationBridge.setPendingNavigation?(...)` — `ContentView` consumes it on the next render.

## Receiving — iOS (SwiftUI modifier)

```swift
.onContinueUserActivity(HandoffActivity.continueActivityType) { activity in
  guard let payload = activity.handoffPayload else {
    logger.warning("Ignoring handoff activity: missing or undecodable payload")
    return
  }
  HandoffContinuationHandler.continue(payload: payload)
}
```

No multi-window dedup needed on iOS. `NavigationBridge.openProfile` on iOS is `store.setActiveProfile(id)` — single window, single active profile.

## Failure handling

- **Activity payload missing / undecodable** → handler returns `false` (macOS) or no-ops (iOS); OS shows its standard "couldn't continue" UI. Logged at `warning`.
- **Profile UUID unknown on destination** — `NavigationBridge.openProfile` silently no-ops (the UUID isn't in the profile list); `setPendingNavigation` is consumed by the next render but no window matches, so it's dropped. Logged at `warning` ("Handoff received for unknown profile <id>"). Expected outcome when CloudKit hasn't synced the profile list yet.
- **Destination entity doesn't exist locally yet** (e.g., `.account(UUID)` for an unsynced account) — `ContentView` applies the pending nav best-effort; falls back to default sidebar if the entity isn't in the store. Same behaviour as AppleScript / App Intents today. Logged at `warning`.
- **Profile is locked / requires auth** — out of scope for v1; whatever gate the profile session imposes still applies.

All Handoff logging goes to a new logger category `Handoff` under the existing `com.moolah.app` subsystem.

## Privacy

- `isEligibleForHandoff = true`, `isEligibleForSearch = false`, `isEligibleForPublicIndexing = false`. Handoff stays on the user's devices via Bluetooth + Apple's iCloud Handoff transport; nothing is indexed in Spotlight or published.
- `userInfo` payload contains only UUIDs and (for `.analysis`/`.reports`) numeric/date parameters — no balances, amounts, names, category labels.
- `activity.title` (Handoff badge text) does contain a human-readable display name (e.g. an account or earmark name). This is the only user-readable PII in the activity and is consistent with how Safari / Mail use `title`. Documented here so it's not later mis-classified.

## Testing

### Unit tests (`MoolahTests`)

- `HandoffPayloadCodableTests` — round-trip every `NavigationDestination` case through `JSONEncoder` / `JSONDecoder`. Includes non-nil and nil parameters for `.analysis` and `.reports`.
- `NSUserActivityHandoffTests` — `configureContinueActivity` stamps every required field (per the *Activity field map* table). `handoffPayload` recovers an identical `HandoffPayload`; returns `nil` for a malformed `userInfo`, a wrong `activityType`, or a missing `payload` key.
- `HandoffContinuationHandlerTests` — install fakes on `NavigationBridge.openProfile` / `setPendingNavigation`; assert ordering and arguments.
  - macOS: existing-window case (`ProfileWindowLocator.activateExistingWindow` returns `true`) → `openProfile` is **not** called; `setPendingNavigation` is called.
  - macOS: no-window case → `openProfile` is called before `setPendingNavigation`.
  - iOS: `openProfile` is always called before `setPendingNavigation`.
- `SidebarSelectionRouteTests` — every `SidebarSelection` case maps to the right `NavigationDestination` (or `nil` where appropriate).
- `NavigationDestinationFromTests` — the pure `from(sidebar:selectedTransaction:analysis:reports:)` function: transaction selection wins over sidebar; sidebar wins otherwise; `nil` inputs produce `nil`.
- `HandoffTitleProviderTests` — covers account/earmark name lookup and the static-string fallback for parameterless destinations.

### Integration test (macOS, `MoolahTests_macOS`)

- `ScriptingBridgeHandoffTests` — construct a real `NSUserActivity` with a valid payload, invoke the delegate method directly, assert the bridge fakes recorded the right calls and the method returned `true`. Invoke with a malformed activity (wrong type, missing payload, unparseable JSON) and assert the method returns `false` and no bridge calls happen.

### Not covered by automated tests

- End-to-end Handoff between two devices (requires hardware).
- SwiftUI's external-event auto-spawn behaviour with `.handlesExternalEvents(matching: [])` (we accept Apple's documented behaviour). Covered by the manual smoke test.

### Manual verification checklist

1. Same-profile, profile already open on Mac → Mac window comes forward and navigates to the right place; no second window.
2. Same-profile, profile not open on Mac → Mac opens the profile and navigates.
3. Activity for a profile UUID not present in destination's list → Handoff badge appears but tap is a no-op; warning logged.
4. iPhone → Mac for each destination type (`.accounts`, `.account`, `.transaction`, `.earmarks`, `.earmark`, `.analysis`, `.reports`, `.categories`, `.upcoming`).
5. Mac → iPhone for the same set.
6. Switch the active profile on the sending device while the receiving device's Handoff badge is visible → badge updates to the new destination (or disappears).

## Open questions

None at this time. The design has been reviewed section-by-section and approved.

## Plan deliverables

A subsequent implementation plan will break the work into landable PRs. Anticipated slicing:

1. `NavigationDestination: Codable` + `HandoffActivity` + `HandoffPayload` + `NSUserActivity` extensions (+ unit tests).
2. `HandoffContinuationHandler` + tests; no UI wiring yet.
3. macOS receiving: `ScriptingBridge` delegate method + `WindowGroup.handlesExternalEvents(matching: [])` + `ScriptingBridgeHandoffTests`.
4. iOS receiving: `.onContinueUserActivity` modifier on `ProfileRootView`.
5. Route assembly: focused-scene values for selected transaction / analysis / reports, plus the pure `NavigationDestination.from(...)` function (+ unit tests).
6. Publishing: `.userActivity(...)` modifier on both window roots + `HandoffTitleProvider` (+ unit tests).
7. `Info-iOS.plist` / `Info-macOS.plist` update + manual smoke test.
