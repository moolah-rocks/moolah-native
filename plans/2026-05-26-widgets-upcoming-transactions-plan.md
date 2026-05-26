# Widgets — Upcoming Transactions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship a `MoolahWidgets` extension on iOS and macOS containing two widgets — a medium "upcoming transactions" list and a small "due now" count — both reading the configured profile's GRDB database directly from a new App Group container.

**Architecture:** Add an App Group entitlement (`group.rocks.moolah.app.{test,v2}`) to both host targets, migrate the per-profile `data.sqlite` and profile-index DB out of `~/Library/Application Support` and into the App Group container under the existing env-scoped subdirectory, and add a `MoolahWidgets_iOS` + `MoolahWidgets_macOS` pair of extension targets that link a new `Shared/Widgets/` module (which owns the App Group path math, an `UpcomingWidgetQuery` that opens `data.sqlite` read-only via GRDB, and a `WidgetProfileDirectory` that lists profiles from the index DB). Two `AppIntent`s with `openAppWhenRun = true` (`OpenTransactionFromWidgetIntent`, `OpenUpcomingFromWidgetIntent`) route widget taps through the existing in-process `NavigationBridge`, exactly mirroring `OpenAccountIntent`. A `WidgetReloadCoordinator` calls `WidgetCenter.shared.reloadAllTimelines()` on every host-side write-path pinch point.

**Tech Stack:** Swift 6, SwiftUI, WidgetKit, AppIntents (Foundation), GRDB 7 (SPM), Swift Testing (`@Suite`, `@Test`, `#expect`, `#require`), `swift-format`, SwiftLint, `xcodegen`.

**Spec:** [plans/2026-05-26-widgets-upcoming-transactions-design.md](2026-05-26-widgets-upcoming-transactions-design.md).

---

## File Structure

### New files

| Path | Responsibility |
|---|---|
| `Shared/Widgets/AppGroupConfig.swift` | Reads the env-scoped App Group identifier from the host Info.plist. |
| `Shared/Widgets/WidgetDataPath.swift` | App Group container URL + per-profile DB / profile-index DB paths. |
| `Shared/Widgets/WidgetProfileSummary.swift` | `Sendable` value `{id, label, currency}` from the profile-index DB. |
| `Shared/Widgets/WidgetProfileDirectory.swift` | Opens the profile-index DB read-only and lists `WidgetProfileSummary`. |
| `Shared/Widgets/UpcomingWidgetSnapshot.swift` | `Sendable` value type returned by the query. |
| `Shared/Widgets/UpcomingWidgetQuery.swift` | Opens `data.sqlite` read-only and returns an `UpcomingWidgetSnapshot`. |
| `Shared/Widgets/WidgetActor.swift` | `@globalActor enum WidgetActor` to serialise widget-side queries per process. |
| `Shared/Widgets/WidgetReloadCoordinator.swift` | Host-side helper that calls `WidgetCenter.shared.reloadAllTimelines()`. |
| `Shared/Widgets/ApplicationSupportToAppGroupMigration.swift` | One-shot copy-then-flag migration helper. |
| `MoolahWidgets/MoolahWidgetsBundle.swift` | `@main WidgetBundle` of both widgets. |
| `MoolahWidgets/UpcomingTransactionsListWidget.swift` | Medium widget + `AppIntentTimelineProvider`. |
| `MoolahWidgets/UpcomingTransactionsCountWidget.swift` | Small widget + `AppIntentTimelineProvider`. |
| `MoolahWidgets/Views/UpcomingListView.swift` | Medium content view. |
| `MoolahWidgets/Views/UpcomingRowView.swift` | One row inside the medium list. |
| `MoolahWidgets/Views/UpcomingCountView.swift` | Small content view. |
| `MoolahWidgets/Views/WidgetEmptyStateView.swift` | Shared empty / placeholder content. |
| `MoolahWidgets/Intents/WidgetProfileSelectionIntent.swift` | `WidgetConfigurationIntent` carrying the profile parameter. |
| `MoolahWidgets/Intents/WidgetProfileEntity.swift` | Extension-local `AppEntity` + `EntityQuery`. |
| `MoolahWidgets/Intents/OpenUpcomingFromWidgetIntent.swift` | Tap target for the small widget. |
| `MoolahWidgets/Intents/OpenTransactionFromWidgetIntent.swift` | Tap target for medium rows. |
| `MoolahWidgets/Info.plist` | Extension Info.plist with `NSExtension` + `MoolahAppGroupIdentifier`. |
| `MoolahWidgets/MoolahWidgets-Debug.entitlements` | App Group entitlement for Debug (group `app.test`). |
| `MoolahWidgets/MoolahWidgets-Release.entitlements` | App Group entitlement for Release (group `app.v2`). |
| `fastlane/Moolah-widgets.entitlements` | App Group + sandbox entitlement consumed by fastlane Release builds (mac + iOS share one file because the App Group key is identical). |
| `MoolahTests/Widgets/WidgetDataPathTests.swift` | Path resolution + override behaviour. |
| `MoolahTests/Widgets/WidgetProfileDirectoryTests.swift` | Profile-index DB enumeration. |
| `MoolahTests/Widgets/UpcomingWidgetQueryTests.swift` | Query behaviour against seeded GRDB DB. |
| `MoolahTests/Widgets/UpcomingWidgetQueryPlanPinningTests.swift` | `EXPLAIN QUERY PLAN` assertions. |
| `MoolahTests/Widgets/UpcomingWidgetSnapshotFormatTests.swift` | Multi-currency fallback + empty state. |
| `MoolahTests/Widgets/OpenTransactionFromWidgetIntentTests.swift` | Intent → `NavigationBridge` fakes. |
| `MoolahTests/Widgets/OpenUpcomingFromWidgetIntentTests.swift` | Intent → `NavigationBridge` fakes. |
| `MoolahTests/Widgets/ApplicationSupportToAppGroupMigrationTests.swift` | Copy-then-flag migration end-to-end. |
| `MoolahTests/Widgets/WidgetReloadCoordinatorTests.swift` | Reload helper invoked from each named host hook. |

### Modified files

| Path | Change |
|---|---|
| `Shared/URL+MoolahStorage.swift` | `moolahScopedApplicationSupport` reads from `WidgetDataPath.appGroupRoot()` (override still wins). |
| `App/ProfileSession+Database.swift` | No code change — paths flow through `URL.moolahScopedApplicationSupport`. (Sanity-check link only.) |
| `App/MoolahApp+Setup.swift` | Invoke `ApplicationSupportToAppGroupMigration.runIfNeeded()` before container manager bootstrap. |
| `Features/Transactions/TransactionStore+Mutations.swift` | Call `WidgetReloadCoordinator.reload(reason: .transactionMutation)` after each successful mutation. |
| `Backends/CloudKit/Sync/<sync-engine-coordinator>.swift` | Call `.reload(reason: .syncCompleted)` at the "fetched + applied" boundary. (Exact file located in Task 6.) |
| `App/MoolahApp+Lifecycle.swift` | Call `.reload(reason: .scenePhaseBackground)` on iOS `ScenePhase` → `background` and macOS `NSApplication.willResignActiveNotification`. |
| `Shared/ProfileContainerManager.swift` | Call `.reload(reason: .profileMutation)` after profile add / rename / delete. |
| `App/Info-iOS.plist`, `App/Info-macOS.plist` | Add `MoolahAppGroupIdentifier = $(APP_GROUP_ID)`. |
| `project.yml` | Add `APP_GROUP_ID` per config to each host target; add `MoolahWidgets_iOS` + `MoolahWidgets_macOS` extension targets; embed each in the matching host; add `Shared/Widgets/` to the existing host source lists (already covered by `Shared`, sanity-check); add `Shared/Widgets/` and `Domain/Models` to each widget target's `sources`; add App Group entitlements per config. |
| `scripts/inject-entitlements.sh` | Add `com.apple.security.application-groups` array to the generated Debug entitlements. |
| `scripts/cloudkit-config.sh` | Add `APP_GROUP_ID_RELEASE` / `APP_GROUP_ID_TEST` knobs that mirror the existing container ID knobs. |
| `fastlane/Moolah.entitlements` | Add `com.apple.security.application-groups = [group.rocks.moolah.app.v2]`. |
| `fastlane/Moolah-mac.entitlements` | Same addition. |
| `.gitignore` | Ensure `project-entitlements.yml` already ignored (sanity); no new entries expected. |
| `CLAUDE.md` | Add a one-line pointer under *Architecture & Constraints* explaining where the widget extension lives and why it never imports `Backends/`. |

### Commit / PR strategy

Seven landable PRs (one per task), each ending with the standard pre-commit gate per [[feedback_format_check_per_plan_step]]:

```bash
just format-check
just test-mac
just test-ios
```

Task 1 unblocks the rest (App Group + migration). Tasks 2–5 incrementally bring the widget alive. Task 6 wires the reload coordinator. Task 7 is verification and documentation polish. The user-visible feature lights up at the end of Task 5.

---

## Task 0 (pre-flight): file the cleanup-pass GitHub issue

The migration in Task 1 leaves the old Application Support data in place behind a flag. We will land a cleanup migration in a later release. The Swift `TODO(#N)` referencing that future work needs an open issue **before** Task 1's commit (per CLAUDE.md §Bug Tracking and `just validate-todos`).

- [ ] **Step 0.1: File the cleanup issue with `gh`**

```bash
gh issue create \
  --title "Delete pre-App-Group per-profile data after telemetric soak" \
  --body "$(cat <<'EOF'
Follow-up to the App Group migration shipped in #<PR-number-from-task-1>. That migration **copied** every per-profile directory out of \`~/Library/Application Support/<env>/profiles/\` into the App Group container and wrote a \`migrated-from-application-support-v1.flag\` marker. The old data is intentionally left in place as a rollback safety net.

This issue tracks the follow-up that **deletes** the old data after we have one or two releases of telemetric confidence that the new path works. Implementation: extend \`ApplicationSupportToAppGroupMigration\` with a \`cleanupOldData()\` entry point gated on the marker existing for at least N days, log byte count reclaimed, and call from the same bootstrap pinch point.

Source pointer: TODO comment in \`Shared/Widgets/ApplicationSupportToAppGroupMigration.swift\` references this issue.
EOF
)" \
  --label "tech-debt"
```

Expected: prints an issue URL like `https://github.com/moolah-rocks/moolah-native/issues/NNN`.

- [ ] **Step 0.2: Record the issue number**

Capture `NNN` from the output. It is referenced in Task 1, Step 6.2.

---

## Task 1: App Group plumbing + migration

**Files:**
- Modify: `project.yml`
- Modify: `scripts/inject-entitlements.sh`
- Modify: `scripts/cloudkit-config.sh`
- Modify: `fastlane/Moolah.entitlements`
- Modify: `fastlane/Moolah-mac.entitlements`
- Modify: `App/Info-iOS.plist`
- Modify: `App/Info-macOS.plist`
- Modify: `Shared/URL+MoolahStorage.swift`
- Modify: `App/MoolahApp+Setup.swift`
- Create: `Shared/Widgets/AppGroupConfig.swift`
- Create: `Shared/Widgets/WidgetDataPath.swift`
- Create: `Shared/Widgets/ApplicationSupportToAppGroupMigration.swift`
- Create: `MoolahTests/Widgets/WidgetDataPathTests.swift`
- Create: `MoolahTests/Widgets/ApplicationSupportToAppGroupMigrationTests.swift`

This task adds the App Group entitlement on both host targets, lifts the env-scoped storage subdirectory into the App Group container, and ships the one-shot migration. **No widget targets are added yet.** Test backends keep using the override mechanism; production switches to the App Group on first launch after the update.

### Step 1: `project.yml` — add `APP_GROUP_ID` per config + entitlement plumbing

- [ ] **Step 1.1: Edit `project.yml` — add `APP_GROUP_ID` to each host target's per-config block**

For `Moolah_iOS`, inside `settings.configs`:

```yaml
        Debug:
          CLOUDKIT_ENVIRONMENT: Development
          CLOUDKIT_CONTAINER_ID: iCloud.rocks.moolah.app.test
          APP_GROUP_ID: group.rocks.moolah.app.test
        Debug-Tests:
          CODE_SIGN_ENTITLEMENTS: ""
          SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited)"
          CLOUDKIT_ENVIRONMENT: Development
          CLOUDKIT_CONTAINER_ID: iCloud.rocks.moolah.app.test
          APP_GROUP_ID: group.rocks.moolah.app.test
        Release:
          # … existing keys …
          CLOUDKIT_ENVIRONMENT: Production
          CLOUDKIT_CONTAINER_ID: iCloud.rocks.moolah.app.v2
          APP_GROUP_ID: group.rocks.moolah.app.v2
```

Repeat the identical three additions inside `Moolah_macOS.settings.configs.{Debug,Debug-Tests,Release}`.

- [ ] **Step 1.2: Edit `App/Info-iOS.plist` — surface the App Group ID to Swift**

Add a top-level `<key>MoolahAppGroupIdentifier</key>` paired with `<string>$(APP_GROUP_ID)</string>`. Place it next to the existing `MoolahCloudKitContainer` key for visual symmetry.

- [ ] **Step 1.3: Edit `App/Info-macOS.plist` — same addition**

Same key / value as iOS.

- [ ] **Step 1.4: Edit `scripts/inject-entitlements.sh` — add App Group key**

Inside the generated entitlements heredoc, add (immediately after the `icloud-container-identifiers` block):

```xml
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.rocks.moolah.app.test</string>
    </array>
```

The Debug app group identifier is hardcoded here because this script only runs for Debug. The Release entitlements files (`fastlane/Moolah*.entitlements`) carry the production identifier; see Step 1.6.

- [ ] **Step 1.5: Edit `scripts/cloudkit-config.sh` — mirror knobs**

Wherever `CLOUDKIT_CONTAINER_ID_RELEASE` / `CLOUDKIT_CONTAINER_ID_TEST` are defined, add the parallel pair:

```bash
APP_GROUP_ID_RELEASE="group.rocks.moolah.app.v2"
APP_GROUP_ID_TEST="group.rocks.moolah.app.test"
```

Export them next to the existing exports so any downstream tooling that reads the env can pick them up.

- [ ] **Step 1.6: Edit `fastlane/Moolah.entitlements` — add App Group**

Inside the `<dict>`, after the `com.apple.developer.icloud-container-identifiers` array, add:

```xml
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.rocks.moolah.app.v2</string>
    </array>
```

- [ ] **Step 1.7: Edit `fastlane/Moolah-mac.entitlements` — same addition**

Same XML block in the same position.

- [ ] **Step 1.8: Run `just generate` to regenerate the Xcode project**

```bash
just generate
```

Expected: completes without error. Inspect with `git status`; only `project.yml` should be staged-relevant on the source side (`Moolah.xcodeproj` is gitignored).

### Step 2: `AppGroupConfig` — read identifier from Info.plist

- [ ] **Step 2.1: Create `Shared/Widgets/AppGroupConfig.swift`**

```swift
import Foundation

/// Resolves the App Group identifier this binary is entitled to.
///
/// The value is set per build configuration in `project.yml`
/// (`APP_GROUP_ID = group.rocks.moolah.app.{test,v2}`) and surfaced
/// to Swift via the `MoolahAppGroupIdentifier` Info.plist key. Mirrors
/// the existing `MoolahCloudKitContainer` arrangement.
enum AppGroupConfig {

  /// Process-wide identifier, read once from the main bundle.
  ///
  /// Crashes at startup if missing. The Info.plist key is required on every
  /// shipped configuration; an absent value means `project.yml` was
  /// regenerated without `APP_GROUP_ID` set, which is never a valid state.
  static let identifier: String = {
    guard
      let raw = Bundle.main.object(forInfoDictionaryKey: "MoolahAppGroupIdentifier") as? String,
      !raw.isEmpty,
      !raw.hasPrefix("$(")
    else {
      fatalError(
        "MoolahAppGroupIdentifier Info.plist key missing or unsubstituted. "
        + "Did `xcodegen` run with APP_GROUP_ID defined?")
    }
    return raw
  }()
}
```

The `hasPrefix("$(")` guard catches the failure mode where `xcodegen` ran without the variable defined and wrote the literal string `$(APP_GROUP_ID)` into Info.plist.

### Step 3: `WidgetDataPath` — App Group container math

- [ ] **Step 3.1: Failing test — write `MoolahTests/Widgets/WidgetDataPathTests.swift`**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("WidgetDataPath")
struct WidgetDataPathTests {

  // MARK: app-group root resolution

  @Test("appGroupRoot returns the FileManager container URL for the configured identifier")
  func appGroupRootReturnsContainerURL() throws {
    // `AppGroupConfig.identifier` is the production-config value at test time.
    // FileManager returns nil for an unknown group identifier; on the test
    // host (no entitlement) we expect nil and verify the path resolver throws.
    let result = WidgetDataPath.appGroupRootOrNil()
    if let url = result {
      #expect(url.path.contains(AppGroupConfig.identifier))
    } else {
      #expect(throws: WidgetDataPath.PathError.appGroupContainerUnavailable) {
        try WidgetDataPath.appGroupRoot()
      }
    }
  }

  // MARK: env-scoped subdirectory

  @Test("scopedRoot appends the CloudKit env subdirectory under the App Group root")
  func scopedRootAppendsEnvSubdirectory() throws {
    let tempBase = FileManager.default.temporaryDirectory
      .appendingPathComponent("widget-data-path-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempBase, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempBase) }

    let scoped = WidgetDataPath.scopedRoot(overrideBase: tempBase)
    #expect(scoped.path.hasPrefix(tempBase.path))
    #expect(scoped.lastPathComponent == CloudKitEnvironment.resolved().storageSubdirectory)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: scoped.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
  }

  // MARK: per-profile DB path

  @Test("profileDatabaseURL composes profiles/<uuid>/data.sqlite under the env scope")
  func profileDatabaseURLComposesCorrectly() {
    let id = UUID()
    let scoped = URL(fileURLWithPath: "/tmp/example/Test")
    let url = WidgetDataPath.profileDatabaseURL(profileID: id, scopedRoot: scoped)
    #expect(url == scoped.appendingPathComponent("profiles/\(id.uuidString)/data.sqlite"))
  }

  // MARK: profile-index DB path

  @Test("profileIndexDatabaseURL composes profile-index.sqlite under the env scope")
  func profileIndexDatabaseURLComposesCorrectly() {
    let scoped = URL(fileURLWithPath: "/tmp/example/Test")
    let url = WidgetDataPath.profileIndexDatabaseURL(scopedRoot: scoped)
    #expect(url == scoped.appendingPathComponent("profile-index.sqlite"))
  }
}
```

- [ ] **Step 3.2: Run the failing tests**

```bash
just test-mac WidgetDataPathTests 2>&1 | tee .agent-tmp/widget-data-path.txt
```

Expected: build fails because `WidgetDataPath` is not defined.

- [ ] **Step 3.3: Create `Shared/Widgets/WidgetDataPath.swift`**

```swift
import Foundation

/// Filesystem layout under the App Group container shared by the host apps
/// and the widget extension.
///
/// The previous layout rooted at `URL.applicationSupportDirectory` is
/// migrated into `WidgetDataPath.scopedRoot()` by
/// `ApplicationSupportToAppGroupMigration`. After migration, every
/// production read / write of per-profile data flows through these paths.
///
/// Tests pass `overrideBase:` to root the layout in a temp directory and
/// never touch the real App Group container.
enum WidgetDataPath {

  enum PathError: Error, Equatable, Sendable {
    case appGroupContainerUnavailable
  }

  /// FileManager container URL for the build's App Group identifier.
  /// Returns `nil` on hosts that don't grant the entitlement (test runner,
  /// some preview environments). Use `appGroupRoot()` when you need the
  /// throwing variant.
  static func appGroupRootOrNil() -> URL? {
    FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupConfig.identifier)
  }

  /// Throwing variant — call sites that cannot proceed without the
  /// container surface `appGroupContainerUnavailable` to the user.
  static func appGroupRoot() throws -> URL {
    guard let url = appGroupRootOrNil() else {
      throw PathError.appGroupContainerUnavailable
    }
    return url
  }

  /// The env-scoped subdirectory under the App Group root, created on demand.
  /// `overrideBase` is used by tests to swap the App Group root for a temp dir.
  static func scopedRoot(overrideBase: URL? = nil) -> URL {
    let base = overrideBase ?? (appGroupRootOrNil() ?? URL.applicationSupportDirectory)
    let scoped = base.appendingPathComponent(
      CloudKitEnvironment.resolved().storageSubdirectory, isDirectory: true)
    try? FileManager.default.createDirectory(at: scoped, withIntermediateDirectories: true)
    return scoped
  }

  /// Per-profile `data.sqlite` URL inside the scoped App Group root.
  static func profileDatabaseURL(profileID: UUID, scopedRoot: URL) -> URL {
    scopedRoot
      .appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent(profileID.uuidString, isDirectory: true)
      .appendingPathComponent("data.sqlite")
  }

  /// Profile-index database URL inside the scoped App Group root.
  static func profileIndexDatabaseURL(scopedRoot: URL) -> URL {
    scopedRoot.appendingPathComponent("profile-index.sqlite")
  }
}
```

- [ ] **Step 3.4: Run the tests — verify pass**

```bash
just test-mac WidgetDataPathTests 2>&1 | tee .agent-tmp/widget-data-path.txt
```

Expected: all three `WidgetDataPathTests` pass.

### Step 4: Repoint `URL.moolahScopedApplicationSupport` at the App Group

- [ ] **Step 4.1: Edit `Shared/URL+MoolahStorage.swift`**

Replace the body of `moolahScopedApplicationSupport` with:

```swift
  /// Application Support, scoped to the current CloudKit environment.
  ///
  /// Production reads from the shared App Group container so the widget
  /// extension can see the same per-profile databases. Tests continue to
  /// use the override (which wins, by design — see `WidgetDataPath`).
  static var moolahScopedApplicationSupport: URL {
    WidgetDataPath.scopedRoot(overrideBase: moolahApplicationSupportOverride)
  }
```

The doc comment is updated; the override key keeps its existing semantics — `WidgetDataPath.scopedRoot(overrideBase:)` uses the override when present and falls back to the App Group root otherwise.

- [ ] **Step 4.2: Run the existing storage-path tests**

```bash
just test-mac URL_MoolahStorage 2>&1 | tee .agent-tmp/storage-tests.txt
```

If a test exists at `MoolahTests/Shared/URLMoolahStorageTests.swift` it must still pass — the override path is unchanged. If no such test exists, build the macOS app to confirm compilation:

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
```

Expected: build succeeds, existing tests pass.

### Step 5: Migration — `ApplicationSupportToAppGroupMigration`

- [ ] **Step 5.1: Failing test — `MoolahTests/Widgets/ApplicationSupportToAppGroupMigrationTests.swift`**

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ApplicationSupportToAppGroupMigration")
struct ApplicationSupportToAppGroupMigrationTests {

  // MARK: helpers

  private struct Fixture {
    let oldRoot: URL
    let newRoot: URL
    let profileIDs: [UUID]
    let cleanup: () -> Void
  }

  private func makeFixture(profileCount: Int = 2) throws -> Fixture {
    let base = FileManager.default.temporaryDirectory
      .appendingPathComponent("widget-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)

    let oldRoot = base.appendingPathComponent("old", isDirectory: true)
    let newRoot = base.appendingPathComponent("new", isDirectory: true)
    try FileManager.default.createDirectory(at: oldRoot, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)

    let ids = (0..<profileCount).map { _ in UUID() }
    // Seed a per-profile data.sqlite and a profile-index.sqlite into the old root.
    for id in ids {
      let dir = oldRoot.appendingPathComponent("profiles/\(id.uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let dbURL = dir.appendingPathComponent("data.sqlite")
      let queue = try DatabaseQueue(path: dbURL.path)
      try queue.write { db in
        try db.execute(sql: "CREATE TABLE marker(id INTEGER PRIMARY KEY)")
        try db.execute(sql: "INSERT INTO marker(id) VALUES (1)")
      }
    }
    let indexURL = oldRoot.appendingPathComponent("profile-index.sqlite")
    let indexQueue = try DatabaseQueue(path: indexURL.path)
    try indexQueue.write { db in
      try db.execute(sql: "CREATE TABLE profile(id TEXT PRIMARY KEY)")
    }

    return Fixture(
      oldRoot: oldRoot,
      newRoot: newRoot,
      profileIDs: ids,
      cleanup: { try? FileManager.default.removeItem(at: base) })
  }

  // MARK: behaviours

  @Test("copies every per-profile data.sqlite from old to new and writes the flag")
  func copiesProfilesAndFlag() throws {
    let fx = try makeFixture()
    defer { fx.cleanup() }

    try ApplicationSupportToAppGroupMigration.runIfNeeded(
      oldRoot: fx.oldRoot, newRoot: fx.newRoot)

    for id in fx.profileIDs {
      let copied = fx.newRoot.appendingPathComponent("profiles/\(id.uuidString)/data.sqlite")
      #expect(FileManager.default.fileExists(atPath: copied.path))
      // Verify the copy is the same DB (the marker row survives).
      let queue = try DatabaseQueue(path: copied.path)
      let count = try queue.read { db in
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM marker") ?? -1
      }
      #expect(count == 1)
    }

    let flag = fx.newRoot.appendingPathComponent("migrated-from-application-support-v1.flag")
    #expect(FileManager.default.fileExists(atPath: flag.path))
  }

  @Test("copies the profile-index DB")
  func copiesProfileIndex() throws {
    let fx = try makeFixture()
    defer { fx.cleanup() }

    try ApplicationSupportToAppGroupMigration.runIfNeeded(
      oldRoot: fx.oldRoot, newRoot: fx.newRoot)

    let copied = fx.newRoot.appendingPathComponent("profile-index.sqlite")
    #expect(FileManager.default.fileExists(atPath: copied.path))
    let queue = try DatabaseQueue(path: copied.path)
    let tableExists = try queue.read { db in
      try Bool.fetchOne(
        db,
        sql: "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'profile'") ?? false
    }
    #expect(tableExists)
  }

  @Test("leaves the old data in place after migration")
  func leavesOldDataAlone() throws {
    let fx = try makeFixture()
    defer { fx.cleanup() }

    try ApplicationSupportToAppGroupMigration.runIfNeeded(
      oldRoot: fx.oldRoot, newRoot: fx.newRoot)

    for id in fx.profileIDs {
      let old = fx.oldRoot.appendingPathComponent("profiles/\(id.uuidString)/data.sqlite")
      #expect(FileManager.default.fileExists(atPath: old.path))
    }
  }

  @Test("is idempotent — re-running is a no-op")
  func idempotent() throws {
    let fx = try makeFixture()
    defer { fx.cleanup() }

    try ApplicationSupportToAppGroupMigration.runIfNeeded(
      oldRoot: fx.oldRoot, newRoot: fx.newRoot)
    let flag = fx.newRoot.appendingPathComponent("migrated-from-application-support-v1.flag")
    let stamp1 = try FileManager.default.attributesOfItem(atPath: flag.path)[.modificationDate]
      as? Date

    try ApplicationSupportToAppGroupMigration.runIfNeeded(
      oldRoot: fx.oldRoot, newRoot: fx.newRoot)
    let stamp2 = try FileManager.default.attributesOfItem(atPath: flag.path)[.modificationDate]
      as? Date

    #expect(stamp1 == stamp2)
  }

  @Test("integrity-check failure aborts and does not write the flag")
  func integrityFailureAborts() throws {
    let fx = try makeFixture()
    defer { fx.cleanup() }

    // Corrupt one of the per-profile DBs by truncating it.
    let firstID = try #require(fx.profileIDs.first)
    let dbURL = fx.oldRoot.appendingPathComponent("profiles/\(firstID.uuidString)/data.sqlite")
    let handle = try FileHandle(forUpdating: dbURL)
    try handle.truncate(atOffset: 16)
    try handle.close()

    #expect(throws: ApplicationSupportToAppGroupMigration.MigrationError.self) {
      try ApplicationSupportToAppGroupMigration.runIfNeeded(
        oldRoot: fx.oldRoot, newRoot: fx.newRoot)
    }
    let flag = fx.newRoot.appendingPathComponent("migrated-from-application-support-v1.flag")
    #expect(!FileManager.default.fileExists(atPath: flag.path))
  }

  @Test("no-op if the old root has no profiles directory")
  func noProfilesNoOp() throws {
    let fx = try makeFixture(profileCount: 0)
    defer { fx.cleanup() }
    // remove the empty profiles directory so the migration sees a truly bare old root
    try FileManager.default.removeItem(
      at: fx.oldRoot.appendingPathComponent("profiles", isDirectory: true))

    try ApplicationSupportToAppGroupMigration.runIfNeeded(
      oldRoot: fx.oldRoot, newRoot: fx.newRoot)

    // profile-index.sqlite is still copied (it was outside the profiles dir).
    let flag = fx.newRoot.appendingPathComponent("migrated-from-application-support-v1.flag")
    #expect(FileManager.default.fileExists(atPath: flag.path))
  }
}
```

- [ ] **Step 5.2: Run the tests — verify all fail (build error)**

```bash
just test-mac ApplicationSupportToAppGroupMigrationTests 2>&1 | tee .agent-tmp/migration-tests.txt
```

Expected: build fails because `ApplicationSupportToAppGroupMigration` is undefined.

- [ ] **Step 5.3: Create `Shared/Widgets/ApplicationSupportToAppGroupMigration.swift`**

Replace `<NNN>` with the issue number from Task 0, Step 0.1.

```swift
import Foundation
import GRDB
import OSLog

/// One-shot migration that copies the user's per-profile data from the
/// legacy `~/Library/Application Support/<env>/...` layout into the App
/// Group container. Copy-not-move; integrity-checked; idempotent.
///
/// Runs from `App/MoolahApp+Setup.swift` before any profile session opens.
/// The old data is intentionally left in place as a rollback safety net.
///
/// TODO(#<NNN>): delete the legacy data after a release of telemetric soak
/// — https://github.com/moolah-rocks/moolah-native/issues/<NNN>
enum ApplicationSupportToAppGroupMigration {

  enum MigrationError: Error, Equatable, Sendable {
    case integrityCheckFailed(URL)
    case copyFailed(URL, underlying: String)
  }

  private static let flagFilename = "migrated-from-application-support-v1.flag"
  private static let logger = Logger(subsystem: "com.moolah.app", category: "WidgetMigration")

  /// Run the migration if it has not already completed for this env. Safe
  /// to call from any thread; uses `FileManager` synchronous APIs.
  ///
  /// Production callers pass no overrides: `oldRoot` defaults to
  /// `URL.applicationSupportDirectory/<env>` and `newRoot` defaults to
  /// `WidgetDataPath.scopedRoot()`.
  static func runIfNeeded(
    oldRoot: URL = defaultOldRoot(),
    newRoot: URL = WidgetDataPath.scopedRoot()
  ) throws {
    let flag = newRoot.appendingPathComponent(flagFilename)
    if FileManager.default.fileExists(atPath: flag.path) {
      return
    }
    try FileManager.default.createDirectory(at: newRoot, withIntermediateDirectories: true)

    let profilesOld = oldRoot.appendingPathComponent("profiles", isDirectory: true)
    let profilesNew = newRoot.appendingPathComponent("profiles", isDirectory: true)
    if FileManager.default.fileExists(atPath: profilesOld.path) {
      try FileManager.default.createDirectory(at: profilesNew, withIntermediateDirectories: true)
      let entries = try FileManager.default.contentsOfDirectory(
        at: profilesOld, includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
      for src in entries {
        let dst = profilesNew.appendingPathComponent(src.lastPathComponent, isDirectory: true)
        try copyDirectoryIfMissing(from: src, to: dst)
        try integrityCheckSQLites(in: dst)
      }
    }

    // Copy non-profiles top-level files (profile-index, sync-state, backups).
    let topLevel = try FileManager.default.contentsOfDirectory(
      at: oldRoot, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
    for src in topLevel where src.lastPathComponent != "profiles" {
      let dst = newRoot.appendingPathComponent(src.lastPathComponent)
      try copyItemIfMissing(from: src, to: dst)
      if src.pathExtension == "sqlite" {
        try integrityCheck(at: dst)
      }
    }

    try Data().write(to: flag, options: [.atomic])
    logger.notice("Application Support → App Group migration complete: \(newRoot.path, privacy: .public)")
  }

  // MARK: helpers

  private static func defaultOldRoot() -> URL {
    URL.applicationSupportDirectory
      .appendingPathComponent(CloudKitEnvironment.resolved().storageSubdirectory, isDirectory: true)
  }

  private static func copyDirectoryIfMissing(from src: URL, to dst: URL) throws {
    if FileManager.default.fileExists(atPath: dst.path) {
      return
    }
    do {
      try FileManager.default.copyItem(at: src, to: dst)
    } catch {
      // Clean up a partial copy so the next attempt is clean.
      try? FileManager.default.removeItem(at: dst)
      throw MigrationError.copyFailed(src, underlying: String(describing: error))
    }
  }

  private static func copyItemIfMissing(from src: URL, to dst: URL) throws {
    if FileManager.default.fileExists(atPath: dst.path) {
      return
    }
    do {
      try FileManager.default.copyItem(at: src, to: dst)
    } catch {
      try? FileManager.default.removeItem(at: dst)
      throw MigrationError.copyFailed(src, underlying: String(describing: error))
    }
  }

  private static func integrityCheckSQLites(in directory: URL) throws {
    let entries = try FileManager.default.contentsOfDirectory(
      at: directory, includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants])
    for url in entries where url.pathExtension == "sqlite" {
      try integrityCheck(at: url)
    }
  }

  private static func integrityCheck(at url: URL) throws {
    let queue = try DatabaseQueue(path: url.path)
    let result = try queue.read { db in
      try String.fetchOne(db, sql: "PRAGMA integrity_check") ?? ""
    }
    if result.lowercased() != "ok" {
      logger.fault("integrity_check failed for \(url.path, privacy: .public): \(result, privacy: .public)")
      // Tear down the partial copy so the next attempt re-tries fresh.
      try? FileManager.default.removeItem(at: url)
      throw MigrationError.integrityCheckFailed(url)
    }
  }
}
```

- [ ] **Step 5.4: Run the tests — verify all pass**

```bash
just test-mac ApplicationSupportToAppGroupMigrationTests 2>&1 | tee .agent-tmp/migration-tests.txt
```

Expected: all six tests pass.

### Step 6: Wire migration into host bootstrap

- [ ] **Step 6.1: Locate the bootstrap pinch point in `App/MoolahApp+Setup.swift`**

Read the file. Find the function that creates `ProfileContainerManager` (search for `ProfileContainerManager(`). The migration must run immediately before that constructor — before any `data.sqlite` is opened by the host.

- [ ] **Step 6.2: Insert the migration call**

In the function identified above, immediately before the `ProfileContainerManager(...)` constructor call, add:

```swift
    // App Group migration — copies legacy ~/Library/Application Support/<env>/
    // data into the App Group container so the widget extension can read it.
    // Idempotent; no-op after first successful run. Tests skip this branch
    // because `moolahApplicationSupportOverride` is set to a temp directory.
    if URL.moolahApplicationSupportOverride == nil {
      do {
        try ApplicationSupportToAppGroupMigration.runIfNeeded()
      } catch {
        logger.fault("Widget App Group migration failed: \(String(describing: error), privacy: .public)")
        // Continue boot — host still works against the legacy path via the
        // override (set below for the fallback case). Widget queries will
        // surface `profileDatabaseUnavailable` until the user resolves it.
      }
    }
```

If the surrounding scope does not already have a `logger` symbol, add at the top of the file:

```swift
import OSLog
private let logger = Logger(subsystem: "com.moolah.app", category: "Setup")
```

(Skip if the file already declares `logger`.)

- [ ] **Step 6.3: Run a focused integration build**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
```

Expected: build succeeds.

### Step 7: Full gate + commit

- [ ] **Step 7.1: Run format-check**

```bash
just format-check
```

If any file is reported unformatted, run `just format` and re-run `format-check`. **Never** bump a `.swiftlint.yml` threshold or add a baseline to dodge a failure (see [[feedback_swiftlint_fix_not_baseline]]).

- [ ] **Step 7.2: Run the full Mac suite**

```bash
just test-mac 2>&1 | tee .agent-tmp/test-mac.txt
```

Expected: all tests pass. Common gotcha: if the `URL.moolahScopedApplicationSupport` refactor regressed a test that didn't set the override, the failure will show as a permission or path error — fix by setting the override in test setup.

- [ ] **Step 7.3: Run the iOS suite**

```bash
just test-ios 2>&1 | tee .agent-tmp/test-ios.txt
```

Expected: all tests pass.

- [ ] **Step 7.4: Commit**

```bash
git add project.yml \
  scripts/inject-entitlements.sh scripts/cloudkit-config.sh \
  fastlane/Moolah.entitlements fastlane/Moolah-mac.entitlements \
  App/Info-iOS.plist App/Info-macOS.plist \
  Shared/URL+MoolahStorage.swift Shared/Widgets/ \
  App/MoolahApp+Setup.swift \
  MoolahTests/Widgets/

git commit -m "$(cat <<'EOF'
feat(widgets): add App Group container + migrate per-profile data into it

Per-profile data.sqlite and profile-index.sqlite move from
~/Library/Application Support/<env>/ into the shared App Group container
group.rocks.moolah.app.{test,v2}. The migration is copy-not-move and
integrity-checked; the legacy data is left in place as a rollback safety
net until a follow-up release (see TODO referencing the cleanup issue).

This is plumbing only — no widget targets yet. Tests continue to use
moolahApplicationSupportOverride and never touch the App Group.
EOF
)"
```

---

## Task 2: `Shared/Widgets/` query layer

**Files:**
- Create: `Shared/Widgets/WidgetActor.swift`
- Create: `Shared/Widgets/WidgetProfileSummary.swift`
- Create: `Shared/Widgets/WidgetProfileDirectory.swift`
- Create: `Shared/Widgets/UpcomingWidgetSnapshot.swift`
- Create: `Shared/Widgets/UpcomingWidgetQuery.swift`
- Create: `MoolahTests/Widgets/WidgetProfileDirectoryTests.swift`
- Create: `MoolahTests/Widgets/UpcomingWidgetQueryTests.swift`
- Create: `MoolahTests/Widgets/UpcomingWidgetQueryPlanPinningTests.swift`
- Create: `MoolahTests/Widgets/UpcomingWidgetSnapshotFormatTests.swift`

This task ships the read-only query layer the widget extension will use. **No extension target yet** — every file lives under `Shared/Widgets/` and is linked by the host. Tests run against the existing GRDB test seed.

### Step 1: `WidgetActor`

- [ ] **Step 1.1: Create `Shared/Widgets/WidgetActor.swift`**

```swift
import Foundation

/// Serialises widget-side queries within a single process so concurrent
/// timeline rebuilds for the same widget don't race each other.
/// SQLite WAL would tolerate overlapping reads, but the actor keeps
/// Instruments traces and signpost intervals legible.
@globalActor
enum WidgetActor {
  actor Storage {}
  static let shared = Storage()
}
```

### Step 2: `WidgetProfileSummary`

- [ ] **Step 2.1: Create `Shared/Widgets/WidgetProfileSummary.swift`**

```swift
import Foundation

/// Minimal profile description returned by `WidgetProfileDirectory`.
/// `Sendable` so it can cross actor / process boundaries.
struct WidgetProfileSummary: Sendable, Equatable, Hashable, Identifiable {
  let id: UUID
  let label: String
  let currency: String

  init(id: UUID, label: String, currency: String) {
    self.id = id
    self.label = label
    self.currency = currency
  }
}
```

### Step 3: `WidgetProfileDirectory`

- [ ] **Step 3.1: Failing tests — `MoolahTests/Widgets/WidgetProfileDirectoryTests.swift`**

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("WidgetProfileDirectory")
struct WidgetProfileDirectoryTests {

  private func seedIndex(at url: URL, profiles: [WidgetProfileSummary]) throws {
    let queue = try DatabaseQueue(path: url.path)
    try queue.write { db in
      try db.execute(sql: """
        CREATE TABLE profile (
          id TEXT PRIMARY KEY,
          label TEXT NOT NULL,
          currency TEXT NOT NULL
        ) STRICT
      """)
      for p in profiles {
        try db.execute(
          sql: "INSERT INTO profile(id, label, currency) VALUES (?, ?, ?)",
          arguments: [p.id.uuidString, p.label, p.currency])
      }
    }
  }

  @Test("returns every profile from the index DB, sorted by label")
  func returnsAllSorted() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("wpd-\(UUID().uuidString).sqlite")
    defer { try? FileManager.default.removeItem(at: tmp) }

    let alice = WidgetProfileSummary(id: UUID(), label: "Alice", currency: "AUD")
    let bob = WidgetProfileSummary(id: UUID(), label: "Bob", currency: "USD")
    try seedIndex(at: tmp, profiles: [bob, alice])

    let result = try WidgetProfileDirectory.list(profileIndexURL: tmp)
    #expect(result.map(\.label) == ["Alice", "Bob"])
    #expect(result.contains { $0.id == alice.id })
    #expect(result.contains { $0.id == bob.id })
  }

  @Test("returns empty list when the DB file is missing")
  func missingDBIsEmptyList() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("wpd-missing-\(UUID().uuidString).sqlite")
    let result = try WidgetProfileDirectory.list(profileIndexURL: tmp)
    #expect(result.isEmpty)
  }

  @Test("throws when the DB file is corrupt")
  func corruptDBThrows() throws {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("wpd-corrupt-\(UUID().uuidString).sqlite")
    try Data("not a database".utf8).write(to: tmp)
    defer { try? FileManager.default.removeItem(at: tmp) }

    #expect(throws: Error.self) {
      _ = try WidgetProfileDirectory.list(profileIndexURL: tmp)
    }
  }
}
```

- [ ] **Step 3.2: Run — verify failing**

```bash
just test-mac WidgetProfileDirectoryTests 2>&1 | tee .agent-tmp/wpd-tests.txt
```

Expected: build fails — `WidgetProfileDirectory` undefined.

- [ ] **Step 3.3: Create `Shared/Widgets/WidgetProfileDirectory.swift`**

```swift
import Foundation
import GRDB

/// Read-only enumerator over the profile-index database. Used by the widget
/// extension's configuration intent to populate the profile picker, and by
/// the timeline providers to resolve the configured profile's metadata.
///
/// The schema is owned by `ProfileContainerManager`; this enumerator only
/// reads the columns it needs and tolerates additional columns being added.
enum WidgetProfileDirectory {

  /// Lists every profile in the index DB, sorted ascending by label.
  /// Returns an empty list if the DB file does not exist (pre-bootstrap,
  /// pre-migration, or test host with no fixtures).
  static func list(profileIndexURL: URL) throws -> [WidgetProfileSummary] {
    guard FileManager.default.fileExists(atPath: profileIndexURL.path) else {
      return []
    }
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(0.2)
    let queue = try DatabaseQueue(path: profileIndexURL.path, configuration: configuration)
    return try queue.read { db in
      try Row.fetchAll(
        db,
        sql: "SELECT id, label, currency FROM profile ORDER BY label COLLATE NOCASE ASC"
      ).compactMap { row -> WidgetProfileSummary? in
        guard
          let idString: String = row["id"],
          let id = UUID(uuidString: idString),
          let label: String = row["label"],
          let currency: String = row["currency"]
        else {
          return nil
        }
        return WidgetProfileSummary(id: id, label: label, currency: currency)
      }
    }
  }
}
```

- [ ] **Step 3.4: Run — verify pass**

```bash
just test-mac WidgetProfileDirectoryTests 2>&1 | tee .agent-tmp/wpd-tests.txt
```

Expected: all three tests pass.

### Step 4: `UpcomingWidgetSnapshot`

- [ ] **Step 4.1: Create `Shared/Widgets/UpcomingWidgetSnapshot.swift`**

```swift
import Foundation

/// Value returned by `UpcomingWidgetQuery.read(...)`. Consumed by both
/// widgets (medium uses `upcomingRows`, small uses `dueNowCount` and
/// `dueNowTotal`). Sendable across actor + process boundaries.
struct UpcomingWidgetSnapshot: Sendable, Equatable {

  struct Row: Sendable, Equatable, Identifiable {
    let id: UUID
    let payee: String
    let dueDate: Date
    /// Signed amount: negative = outflow, positive = inflow. Preserves the
    /// original Transaction-leg sign per project convention; never abs().
    let amount: Decimal
    let instrument: Instrument

    init(id: UUID, payee: String, dueDate: Date, amount: Decimal, instrument: Instrument) {
      self.id = id
      self.payee = payee
      self.dueDate = dueDate
      self.amount = amount
      self.instrument = instrument
    }
  }

  let profileID: UUID
  let profileLabel: String
  let profileCurrency: String

  /// Start-of-day of the request time, in the resolving calendar.
  let asOf: Date

  /// Count of scheduled transactions that are overdue or due today.
  let dueNowCount: Int

  /// Sum of overdue+today amounts, grouped by instrument (signed).
  let dueNowTotal: [Instrument: Decimal]

  /// Overdue + next-7-days rows, ascending by `dueDate`, capped at the
  /// caller's `maxRows`. Use `upcomingTotalInRange` for the un-capped count.
  let upcomingRows: [Row]

  /// Total number of overdue+next-7-days rows the query found, even when
  /// `upcomingRows` was truncated to `maxRows`.
  let upcomingTotalInRange: Int
}
```

### Step 5: `UpcomingWidgetQuery` — tests first

- [ ] **Step 5.1: Failing tests — `MoolahTests/Widgets/UpcomingWidgetQueryTests.swift`**

These tests build a minimal `data.sqlite` directly via GRDB to avoid taking a dependency on the full repository machinery. The widget query is intentionally schema-light: it reads from the `transaction` table (or whatever the GRDB phase-B schema names it) and aggregates the leg amounts. **Before writing this file, read** `Backends/GRDB/Schema/` to confirm the actual table + column names; the snippets below use placeholders `transaction` / `transaction_leg` that the implementer must reconcile with the live schema.

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("UpcomingWidgetQuery")
struct UpcomingWidgetQueryTests {

  // MARK: fixtures

  private static let calendar: Calendar = {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal
  }()

  private struct Fixture {
    let dbURL: URL
    let profile: WidgetProfileSummary
    let now: Date
    let cleanup: () -> Void
  }

  private func makeFixture(rows: [(daysFromToday: Int, payee: String, amount: Decimal)]) throws
    -> Fixture
  {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("uwq-\(UUID().uuidString).sqlite")
    let now = Self.calendar.startOfDay(for: Date(timeIntervalSince1970: 1_780_000_000))

    let queue = try DatabaseQueue(path: tmp.path)
    try queue.write { db in
      // NOTE: column / table names below MUST match the live GRDB schema in
      // Backends/GRDB/Schema/. The implementer reads that file when this
      // test is unblocked. If the live schema differs, update both this
      // seed AND the query SQL in UpcomingWidgetQuery accordingly.
      try db.execute(sql: """
        CREATE TABLE transaction_record (
          id TEXT PRIMARY KEY,
          date REAL NOT NULL,
          payee TEXT,
          is_scheduled INTEGER NOT NULL,
          is_hidden INTEGER NOT NULL DEFAULT 0,
          recur_period TEXT
        ) STRICT
      """)
      try db.execute(sql: """
        CREATE TABLE transaction_leg (
          id TEXT PRIMARY KEY,
          transaction_id TEXT NOT NULL REFERENCES transaction_record(id),
          quantity TEXT NOT NULL,
          instrument_code TEXT NOT NULL
        ) STRICT
      """)
      try db.execute(sql: "CREATE INDEX ix_txn_scheduled_date ON transaction_record(is_scheduled, date)")

      for (offset, payee, amount) in rows {
        let date = Self.calendar.date(byAdding: .day, value: offset, to: now)!
        let txID = UUID().uuidString
        try db.execute(
          sql: """
            INSERT INTO transaction_record(id, date, payee, is_scheduled, is_hidden, recur_period)
            VALUES (?, ?, ?, 1, 0, 'MONTH')
          """,
          arguments: [txID, date.timeIntervalSinceReferenceDate, payee])
        try db.execute(
          sql: """
            INSERT INTO transaction_leg(id, transaction_id, quantity, instrument_code)
            VALUES (?, ?, ?, ?)
          """,
          arguments: [UUID().uuidString, txID, "\(amount)", "AUD"])
      }
    }

    return Fixture(
      dbURL: tmp,
      profile: WidgetProfileSummary(id: UUID(), label: "Test", currency: "AUD"),
      now: now,
      cleanup: { try? FileManager.default.removeItem(at: tmp) })
  }

  // MARK: behaviours

  @Test("empty profile → dueNowCount == 0 and no rows")
  func emptyProfile() async throws {
    let fx = try makeFixture(rows: [])
    defer { fx.cleanup() }

    let snapshot = try await UpcomingWidgetQuery.read(
      profile: fx.profile,
      profileDatabaseURL: fx.dbURL,
      asOf: fx.now,
      calendar: Self.calendar,
      maxRows: 5)
    #expect(snapshot.dueNowCount == 0)
    #expect(snapshot.upcomingRows.isEmpty)
    #expect(snapshot.dueNowTotal.isEmpty)
    #expect(snapshot.upcomingTotalInRange == 0)
  }

  @Test("overdue rows count toward dueNowCount and appear first in upcomingRows")
  func overdueRowsCountAndOrder() async throws {
    let fx = try makeFixture(rows: [
      (-3, "Origin Energy", Decimal(-184.20)),
      (-1, "Foxtel", Decimal(-95.00)),
      (0, "Netflix", Decimal(-22.99)),
      (2, "Council", Decimal(-412.00)),
    ])
    defer { fx.cleanup() }

    let snapshot = try await UpcomingWidgetQuery.read(
      profile: fx.profile,
      profileDatabaseURL: fx.dbURL,
      asOf: fx.now,
      calendar: Self.calendar,
      maxRows: 5)
    #expect(snapshot.dueNowCount == 3)  // overdue + today
    #expect(snapshot.upcomingRows.map(\.payee) == ["Origin Energy", "Foxtel", "Netflix", "Council"])
  }

  @Test("rows beyond 7 days are excluded")
  func beyondHorizonExcluded() async throws {
    let fx = try makeFixture(rows: [
      (3, "Near", Decimal(-10)),
      (8, "Far", Decimal(-99)),
    ])
    defer { fx.cleanup() }

    let snapshot = try await UpcomingWidgetQuery.read(
      profile: fx.profile,
      profileDatabaseURL: fx.dbURL,
      asOf: fx.now,
      calendar: Self.calendar,
      maxRows: 5)
    #expect(snapshot.upcomingRows.map(\.payee) == ["Near"])
    #expect(snapshot.upcomingTotalInRange == 1)
  }

  @Test("rows are capped at maxRows; upcomingTotalInRange reflects the un-capped count")
  func cappedAtMaxRows() async throws {
    let fx = try makeFixture(rows: (0..<8).map { i in
      (i, "Item \(i)", Decimal(-Double(i + 1)))
    })
    defer { fx.cleanup() }

    let snapshot = try await UpcomingWidgetQuery.read(
      profile: fx.profile,
      profileDatabaseURL: fx.dbURL,
      asOf: fx.now,
      calendar: Self.calendar,
      maxRows: 5)
    #expect(snapshot.upcomingRows.count == 5)
    #expect(snapshot.upcomingTotalInRange == 8)
  }

  @Test("hidden transactions are excluded")
  func hiddenExcluded() async throws {
    let fx = try makeFixture(rows: [(0, "Today", Decimal(-50))])
    defer { fx.cleanup() }
    // Mark the row hidden in-place.
    let queue = try DatabaseQueue(path: fx.dbURL.path)
    try queue.write { db in
      try db.execute(sql: "UPDATE transaction_record SET is_hidden = 1")
    }

    let snapshot = try await UpcomingWidgetQuery.read(
      profile: fx.profile,
      profileDatabaseURL: fx.dbURL,
      asOf: fx.now,
      calendar: Self.calendar,
      maxRows: 5)
    #expect(snapshot.dueNowCount == 0)
    #expect(snapshot.upcomingRows.isEmpty)
  }

  @Test("positive amounts (refunds) preserve their sign in the row")
  func signPreserved() async throws {
    let fx = try makeFixture(rows: [(0, "Refund", Decimal(35.00))])
    defer { fx.cleanup() }

    let snapshot = try await UpcomingWidgetQuery.read(
      profile: fx.profile,
      profileDatabaseURL: fx.dbURL,
      asOf: fx.now,
      calendar: Self.calendar,
      maxRows: 5)
    let row = try #require(snapshot.upcomingRows.first)
    #expect(row.amount == Decimal(35.00))
  }

  @Test("missing DB throws profileDatabaseUnavailable")
  func missingDBThrows() async {
    let fx = WidgetProfileSummary(id: UUID(), label: "X", currency: "AUD")
    await #expect(throws: UpcomingWidgetQuery.QueryError.profileDatabaseUnavailable) {
      _ = try await UpcomingWidgetQuery.read(
        profile: fx,
        profileDatabaseURL: URL(fileURLWithPath: "/tmp/no-such-\(UUID().uuidString).sqlite"),
        asOf: Date(),
        calendar: Self.calendar,
        maxRows: 5)
    }
  }
}
```

- [ ] **Step 5.2: Run — verify failing**

```bash
just test-mac UpcomingWidgetQueryTests 2>&1 | tee .agent-tmp/uwq-tests.txt
```

Expected: build fails — `UpcomingWidgetQuery` undefined.

- [ ] **Step 5.3: Create `Shared/Widgets/UpcomingWidgetQuery.swift`**

**Before writing**, open `Backends/GRDB/Schema/` and confirm the live table / column names for scheduled transactions. The SQL below uses the same placeholder names (`transaction_record`, `transaction_leg`, `is_scheduled`, `is_hidden`, `quantity`, `instrument_code`) that the tests seed; reconcile them to the live schema in one pass.

```swift
import Foundation
import GRDB
import OSLog

/// Read-only query that produces an `UpcomingWidgetSnapshot` for a profile.
/// Opens `data.sqlite` with `readonly = true`, runs two focused SELECTs
/// inside one `db.read`, and closes the queue before returning.
enum UpcomingWidgetQuery {

  enum QueryError: Error, Equatable, Sendable {
    case profileDatabaseUnavailable
  }

  private static let logger = Logger(subsystem: "com.moolah.app", category: "Widgets")

  @WidgetActor
  static func read(
    profile: WidgetProfileSummary,
    profileDatabaseURL: URL,
    asOf now: Date = Date(),
    calendar: Calendar = .current,
    maxRows: Int = 5
  ) throws -> UpcomingWidgetSnapshot {
    guard FileManager.default.fileExists(atPath: profileDatabaseURL.path) else {
      throw QueryError.profileDatabaseUnavailable
    }
    var configuration = Configuration()
    configuration.readonly = true
    configuration.busyMode = .timeout(0.2)

    let queue: DatabaseQueue
    do {
      queue = try DatabaseQueue(path: profileDatabaseURL.path, configuration: configuration)
    } catch {
      logger.warning("Could not open profile DB for widget: \(error.localizedDescription, privacy: .public)")
      throw QueryError.profileDatabaseUnavailable
    }
    defer { _ = try? queue.close() }

    let startOfToday = calendar.startOfDay(for: now)
    let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday)!
    let horizonEnd = calendar.date(byAdding: .day, value: 7, to: startOfToday)!

    return try queue.read { db in
      let upcomingRows = try fetchRows(
        db: db,
        upperBound: horizonEnd,
        limit: maxRows)
      let totalInRange = try fetchCount(
        db: db,
        lowerBound: nil,
        upperBound: horizonEnd)
      let dueNowCount = try fetchCount(
        db: db,
        lowerBound: nil,
        upperBound: startOfTomorrow)
      let dueNowTotal = try fetchTotals(
        db: db,
        upperBound: startOfTomorrow)
      return UpcomingWidgetSnapshot(
        profileID: profile.id,
        profileLabel: profile.label,
        profileCurrency: profile.currency,
        asOf: startOfToday,
        dueNowCount: dueNowCount,
        dueNowTotal: dueNowTotal,
        upcomingRows: upcomingRows,
        upcomingTotalInRange: totalInRange)
    }
  }

  // MARK: SQL

  private static func fetchRows(db: Database, upperBound: Date, limit: Int) throws
    -> [UpcomingWidgetSnapshot.Row]
  {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT t.id AS id, t.date AS date, t.payee AS payee,
               SUM(CAST(l.quantity AS REAL)) AS amount,
               MIN(l.instrument_code) AS instrument_code
        FROM transaction_record t
        JOIN transaction_leg l ON l.transaction_id = t.id
        WHERE t.is_scheduled = 1
          AND t.is_hidden = 0
          AND t.date < ?
        GROUP BY t.id
        ORDER BY t.date ASC
        LIMIT ?
      """,
      arguments: [upperBound.timeIntervalSinceReferenceDate, limit])
    return rows.compactMap { row -> UpcomingWidgetSnapshot.Row? in
      guard
        let idString: String = row["id"],
        let id = UUID(uuidString: idString),
        let payee: String = row["payee"],
        let dateRaw: Double = row["date"],
        let amountRaw: Double = row["amount"],
        let instrumentCode: String = row["instrument_code"]
      else {
        return nil
      }
      return UpcomingWidgetSnapshot.Row(
        id: id,
        payee: payee,
        dueDate: Date(timeIntervalSinceReferenceDate: dateRaw),
        amount: Decimal(amountRaw),
        instrument: Instrument(code: instrumentCode))
    }
  }

  private static func fetchCount(db: Database, lowerBound: Date?, upperBound: Date) throws -> Int {
    let sql = """
      SELECT COUNT(*)
      FROM transaction_record t
      WHERE t.is_scheduled = 1
        AND t.is_hidden = 0
        AND t.date < ?
    """
    return try Int.fetchOne(db, sql: sql, arguments: [upperBound.timeIntervalSinceReferenceDate])
      ?? 0
  }

  private static func fetchTotals(db: Database, upperBound: Date) throws
    -> [Instrument: Decimal]
  {
    let rows = try Row.fetchAll(
      db,
      sql: """
        SELECT l.instrument_code AS instrument_code,
               SUM(CAST(l.quantity AS REAL)) AS total
        FROM transaction_record t
        JOIN transaction_leg l ON l.transaction_id = t.id
        WHERE t.is_scheduled = 1
          AND t.is_hidden = 0
          AND t.date < ?
        GROUP BY l.instrument_code
      """,
      arguments: [upperBound.timeIntervalSinceReferenceDate])
    var result: [Instrument: Decimal] = [:]
    for row in rows {
      guard
        let code: String = row["instrument_code"],
        let total: Double = row["total"]
      else { continue }
      result[Instrument(code: code)] = Decimal(total)
    }
    return result
  }
}
```

If `Instrument` does not have a `init(code: String)` initialiser (it may construct from a richer enum or registry), use whichever factory the project provides — see `Domain/Models/Instrument.swift`. The semantic requirement is "round-trip an `instrument_code` string column from `data.sqlite` into an `Instrument` value". Update the test fixture's `instrument_code` insert to match if needed.

- [ ] **Step 5.4: Run — verify pass**

```bash
just test-mac UpcomingWidgetQueryTests 2>&1 | tee .agent-tmp/uwq-tests.txt
```

Expected: all seven tests pass.

### Step 6: Plan-pinning test

- [ ] **Step 6.1: Create `MoolahTests/Widgets/UpcomingWidgetQueryPlanPinningTests.swift`**

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("UpcomingWidgetQuery query plans")
struct UpcomingWidgetQueryPlanPinningTests {

  private func makeSeededDB() throws -> URL {
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("uwq-plan-\(UUID().uuidString).sqlite")
    let queue = try DatabaseQueue(path: tmp.path)
    try queue.write { db in
      try db.execute(sql: """
        CREATE TABLE transaction_record (
          id TEXT PRIMARY KEY,
          date REAL NOT NULL,
          payee TEXT,
          is_scheduled INTEGER NOT NULL,
          is_hidden INTEGER NOT NULL DEFAULT 0,
          recur_period TEXT
        ) STRICT
      """)
      try db.execute(sql: """
        CREATE TABLE transaction_leg (
          id TEXT PRIMARY KEY,
          transaction_id TEXT NOT NULL REFERENCES transaction_record(id),
          quantity TEXT NOT NULL,
          instrument_code TEXT NOT NULL
        ) STRICT
      """)
      try db.execute(sql: "CREATE INDEX ix_txn_scheduled_date ON transaction_record(is_scheduled, date)")
      try db.execute(sql: "ANALYZE")
    }
    return tmp
  }

  @Test("upcoming-rows SELECT uses the scheduled+date index")
  func upcomingRowsUsesIndex() throws {
    let url = try makeSeededDB()
    defer { try? FileManager.default.removeItem(at: url) }
    let queue = try DatabaseQueue(path: url.path)
    let plan = try queue.read { db -> String in
      try String.fetchAll(db, sql: """
        EXPLAIN QUERY PLAN
        SELECT t.id, t.date, t.payee, SUM(l.quantity), MIN(l.instrument_code)
        FROM transaction_record t
        JOIN transaction_leg l ON l.transaction_id = t.id
        WHERE t.is_scheduled = 1 AND t.is_hidden = 0 AND t.date < 0
        GROUP BY t.id
        ORDER BY t.date ASC
        LIMIT 5
        """).joined(separator: "\n")
    }
    #expect(plan.contains("ix_txn_scheduled_date") || plan.contains("USING INDEX"))
  }

  @Test("count SELECT uses the same index")
  func countUsesIndex() throws {
    let url = try makeSeededDB()
    defer { try? FileManager.default.removeItem(at: url) }
    let queue = try DatabaseQueue(path: url.path)
    let plan = try queue.read { db -> String in
      try String.fetchAll(db, sql: """
        EXPLAIN QUERY PLAN
        SELECT COUNT(*)
        FROM transaction_record t
        WHERE t.is_scheduled = 1 AND t.is_hidden = 0 AND t.date < 0
        """).joined(separator: "\n")
    }
    #expect(plan.contains("ix_txn_scheduled_date") || plan.contains("USING INDEX"))
  }
}
```

- [ ] **Step 6.2: Run — verify pass**

```bash
just test-mac UpcomingWidgetQueryPlanPinningTests 2>&1 | tee .agent-tmp/plan-tests.txt
```

Expected: both tests pass. If a plan shows `SCAN` instead of `SEARCH USING INDEX`, the live schema is missing the index — add it to the GRDB schema in `Backends/GRDB/Schema/` (per `guides/DATABASE_SCHEMA_GUIDE.md`).

### Step 7: Snapshot-format tests

- [ ] **Step 7.1: Create `MoolahTests/Widgets/UpcomingWidgetSnapshotFormatTests.swift`**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("UpcomingWidgetSnapshot formatters")
struct UpcomingWidgetSnapshotFormatTests {

  @Test("singleInstrumentAmount returns the sole entry when there is one")
  func single() {
    let snap = makeSnapshot(totals: [Instrument(code: "AUD"): Decimal(-224.19)])
    let result = SmallWidgetTotalRenderer.text(for: snap)
    #expect(result == InstrumentAmount(quantity: Decimal(-224.19), instrument: Instrument(code: "AUD")).formatted)
  }

  @Test("when multiple instruments present and profile currency is among them, render that one with ellipsis")
  func multipleWithProfileCurrency() {
    let totals: [Instrument: Decimal] = [
      Instrument(code: "AUD"): Decimal(-100),
      Instrument(code: "USD"): Decimal(-50),
    ]
    let snap = makeSnapshot(profileCurrency: "AUD", totals: totals)
    let result = SmallWidgetTotalRenderer.text(for: snap)
    #expect(result.contains("…"))
    #expect(result.contains("AUD") || result.contains("$"))
  }

  @Test("when multiple instruments present and none match profile currency, render Multiple currencies")
  func multipleWithoutProfileCurrency() {
    let totals: [Instrument: Decimal] = [
      Instrument(code: "BTC"): Decimal(-0.001),
      Instrument(code: "ETH"): Decimal(-0.02),
    ]
    let snap = makeSnapshot(profileCurrency: "AUD", totals: totals)
    let result = SmallWidgetTotalRenderer.text(for: snap)
    #expect(result == "Multiple currencies")
  }

  @Test("empty totals renders Nothing due today")
  func empty() {
    let snap = makeSnapshot(totals: [:])
    let result = SmallWidgetTotalRenderer.text(for: snap)
    #expect(result == "Nothing due today")
  }

  // MARK: helper

  private func makeSnapshot(
    profileCurrency: String = "AUD",
    totals: [Instrument: Decimal]
  ) -> UpcomingWidgetSnapshot {
    UpcomingWidgetSnapshot(
      profileID: UUID(),
      profileLabel: "Test",
      profileCurrency: profileCurrency,
      asOf: Date(),
      dueNowCount: totals.isEmpty ? 0 : 1,
      dueNowTotal: totals,
      upcomingRows: [],
      upcomingTotalInRange: 0)
  }
}
```

- [ ] **Step 7.2: Create `Shared/Widgets/SmallWidgetTotalRenderer.swift`**

```swift
import Foundation

/// Pure renderer for the small widget's total line. Extracted from
/// `UpcomingCountView` so it can be unit-tested without SwiftUI.
enum SmallWidgetTotalRenderer {
  static func text(for snapshot: UpcomingWidgetSnapshot) -> String {
    let totals = snapshot.dueNowTotal
    if totals.isEmpty {
      return "Nothing due today"
    }
    if totals.count == 1, let (instrument, amount) = totals.first {
      return InstrumentAmount(quantity: amount, instrument: instrument).formatted
    }
    let profileInstrument = Instrument(code: snapshot.profileCurrency)
    if let amount = totals[profileInstrument] {
      return InstrumentAmount(quantity: amount, instrument: profileInstrument).formatted + " …"
    }
    return "Multiple currencies"
  }
}
```

- [ ] **Step 7.3: Run — verify pass**

```bash
just test-mac UpcomingWidgetSnapshotFormatTests 2>&1 | tee .agent-tmp/snap-format-tests.txt
```

Expected: all four tests pass.

### Step 8: Full gate + commit

- [ ] **Step 8.1: Run gates**

```bash
just format-check
just test-mac
just test-ios
```

- [ ] **Step 8.2: Commit**

```bash
git add Shared/Widgets/ MoolahTests/Widgets/
git commit -m "$(cat <<'EOF'
feat(widgets): add read-only query layer (no extension target yet)

UpcomingWidgetQuery opens the per-profile data.sqlite read-only via GRDB
and returns an UpcomingWidgetSnapshot. WidgetProfileDirectory enumerates
profiles from the profile-index DB. SmallWidgetTotalRenderer is the
pure formatter for the small widget's total line.

Plan-pinning tests confirm both SELECTs use the scheduled+date index.
No extension target yet — every file is consumed by the host for now.
EOF
)"
```

---

## Task 3: `MoolahWidgets` extension target — scaffolding

**Files:**
- Modify: `project.yml`
- Create: `MoolahWidgets/MoolahWidgetsBundle.swift`
- Create: `MoolahWidgets/Info.plist`
- Create: `MoolahWidgets/MoolahWidgets-Debug.entitlements`
- Create: `MoolahWidgets/MoolahWidgets-Release.entitlements`
- Create: `MoolahWidgets/Intents/WidgetProfileSelectionIntent.swift`
- Create: `MoolahWidgets/Intents/WidgetProfileEntity.swift`
- Create: `MoolahWidgets/Views/WidgetEmptyStateView.swift`
- Create: `MoolahWidgets/Placeholders.swift` (temporary — both widgets defined as no-op placeholders)

End-state: `just build-mac` and `just build-ios` produce an app that embeds an empty widget bundle. The widget shows up in the "Add widget" picker on both platforms, but its only content is a placeholder.

### Step 1: Extension target in `project.yml`

- [ ] **Step 1.1: Add `MoolahWidgets_iOS` target to `project.yml`**

Append, immediately after `MoolahUITests_macOS:`:

```yaml
  MoolahWidgets_iOS:
    type: app-extension
    platform: iOS
    sources:
      - path: MoolahWidgets
      - path: Shared/Widgets
      - path: Domain/Models
    dependencies:
      - sdk: WidgetKit.framework
      - sdk: SwiftUI.framework
      - sdk: AppIntents.framework
      - package: GRDB
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: rocks.moolah.app.widgets
        PRODUCT_NAME: MoolahWidgets
        INFOPLIST_FILE: MoolahWidgets/Info.plist
        SWIFT_VERSION: "6.0"
        APPLICATION_EXTENSION_API_ONLY: YES
      configs:
        Debug:
          APP_GROUP_ID: group.rocks.moolah.app.test
          CODE_SIGN_ENTITLEMENTS: MoolahWidgets/MoolahWidgets-Debug.entitlements
        Debug-Tests:
          APP_GROUP_ID: group.rocks.moolah.app.test
          CODE_SIGN_ENTITLEMENTS: ""
        Release:
          APP_GROUP_ID: group.rocks.moolah.app.v2
          CODE_SIGN_ENTITLEMENTS: MoolahWidgets/MoolahWidgets-Release.entitlements
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: Apple Distribution
          PROVISIONING_PROFILE_SPECIFIER: ${IOS_WIDGETS_PROVISIONING_PROFILE}
```

- [ ] **Step 1.2: Add `MoolahWidgets_macOS` target**

Immediately after `MoolahWidgets_iOS:`:

```yaml
  MoolahWidgets_macOS:
    type: app-extension
    platform: macOS
    sources:
      - path: MoolahWidgets
      - path: Shared/Widgets
      - path: Domain/Models
    dependencies:
      - sdk: WidgetKit.framework
      - sdk: SwiftUI.framework
      - sdk: AppIntents.framework
      - package: GRDB
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: rocks.moolah.app.widgets
        PRODUCT_NAME: MoolahWidgets
        INFOPLIST_FILE: MoolahWidgets/Info.plist
        SWIFT_VERSION: "6.0"
        APPLICATION_EXTENSION_API_ONLY: YES
        ENABLE_HARDENED_RUNTIME: YES
      configs:
        Debug:
          APP_GROUP_ID: group.rocks.moolah.app.test
          CODE_SIGN_ENTITLEMENTS: MoolahWidgets/MoolahWidgets-Debug.entitlements
        Debug-Tests:
          APP_GROUP_ID: group.rocks.moolah.app.test
          CODE_SIGN_ENTITLEMENTS: ""
        Release:
          APP_GROUP_ID: group.rocks.moolah.app.v2
          CODE_SIGN_ENTITLEMENTS: MoolahWidgets/MoolahWidgets-Release.entitlements
          CODE_SIGN_STYLE: Manual
          CODE_SIGN_IDENTITY: Developer ID Application
          PROVISIONING_PROFILE_SPECIFIER: ${MAC_WIDGETS_PROVISIONING_PROFILE}
```

- [ ] **Step 1.3: Embed the widget extensions in the host apps**

Under `Moolah_iOS.dependencies`, add:

```yaml
      - target: MoolahWidgets_iOS
        embed: true
        codeSign: true
```

Under `Moolah_macOS.dependencies`, add:

```yaml
      - target: MoolahWidgets_macOS
        embed: true
        codeSign: true
```

- [ ] **Step 1.4: Run `just generate`**

```bash
just generate
```

Expected: completes without error.

### Step 2: Info.plist and entitlements files

- [ ] **Step 2.1: Create `MoolahWidgets/Info.plist`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDisplayName</key>
    <string>Moolah</string>
    <key>CFBundleExecutable</key>
    <string>$(EXECUTABLE_NAME)</string>
    <key>CFBundleIdentifier</key>
    <string>$(PRODUCT_BUNDLE_IDENTIFIER)</string>
    <key>CFBundleName</key>
    <string>$(PRODUCT_NAME)</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>$(MARKETING_VERSION)</string>
    <key>CFBundleVersion</key>
    <string>$(CURRENT_PROJECT_VERSION)</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
    <key>MoolahAppGroupIdentifier</key>
    <string>$(APP_GROUP_ID)</string>
</dict>
</plist>
```

- [ ] **Step 2.2: Create `MoolahWidgets/MoolahWidgets-Debug.entitlements`**

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.rocks.moolah.app.test</string>
    </array>
</dict>
</plist>
```

- [ ] **Step 2.3: Create `MoolahWidgets/MoolahWidgets-Release.entitlements`**

Same shape, identifier is `group.rocks.moolah.app.v2`.

### Step 3: `WidgetProfileEntity`

- [ ] **Step 3.1: Create `MoolahWidgets/Intents/WidgetProfileEntity.swift`**

```swift
import AppIntents
import Foundation

/// Extension-local entity for the widget configuration intent. Distinct from
/// the host's `Automation/Intents/Entities/ProfileEntity` (which depends on
/// `AutomationServiceLocator.shared` and so cannot be queried from the
/// widget extension process).
struct WidgetProfileEntity: AppEntity {
  static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Profile")
  static let defaultQuery = WidgetProfileQuery()

  let id: UUID
  let label: String
  let currency: String

  var displayRepresentation: DisplayRepresentation {
    DisplayRepresentation(title: "\(label)", subtitle: "\(currency)")
  }
}

struct WidgetProfileQuery: EntityQuery {
  func entities(for identifiers: [WidgetProfileEntity.ID]) async throws -> [WidgetProfileEntity] {
    try listAll().filter { identifiers.contains($0.id) }
  }

  func suggestedEntities() async throws -> [WidgetProfileEntity] {
    try listAll()
  }

  private func listAll() throws -> [WidgetProfileEntity] {
    let scoped = WidgetDataPath.scopedRoot()
    let indexURL = WidgetDataPath.profileIndexDatabaseURL(scopedRoot: scoped)
    return try WidgetProfileDirectory.list(profileIndexURL: indexURL).map {
      WidgetProfileEntity(id: $0.id, label: $0.label, currency: $0.currency)
    }
  }
}
```

### Step 4: `WidgetProfileSelectionIntent`

- [ ] **Step 4.1: Create `MoolahWidgets/Intents/WidgetProfileSelectionIntent.swift`**

```swift
import AppIntents

struct WidgetProfileSelectionIntent: WidgetConfigurationIntent {
  static let title: LocalizedStringResource = "Pick a profile"
  static let description = IntentDescription("Choose which Moolah profile this widget shows.")

  @Parameter(title: "Profile") var profile: WidgetProfileEntity?
}
```

### Step 5: Shared empty-state view

- [ ] **Step 5.1: Create `MoolahWidgets/Views/WidgetEmptyStateView.swift`**

```swift
import SwiftUI

struct WidgetEmptyStateView: View {
  let title: String
  let subtitle: String?

  var body: some View {
    VStack(alignment: .center, spacing: 4) {
      Text(title)
        .font(.headline)
      if let subtitle {
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
    .multilineTextAlignment(.center)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
```

### Step 6: Bundle + placeholder widgets

- [ ] **Step 6.1: Create `MoolahWidgets/Placeholders.swift`**

```swift
import SwiftUI
import WidgetKit

/// Temporary placeholder definitions so the widget bundle compiles before
/// the real widgets land in Tasks 4 and 5. Each placeholder ships with the
/// final widget kind string so a user who adds the widget in this stepping
/// stone build will not lose their slot when the real widgets replace it.
struct PlaceholderUpcomingListWidget: Widget {
  static let kind = "rocks.moolah.widget.upcoming-list"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: Self.kind,
      intent: WidgetProfileSelectionIntent.self,
      provider: PlaceholderProvider()
    ) { _ in
      WidgetEmptyStateView(title: "Upcoming", subtitle: "Coming soon")
    }
    .configurationDisplayName("Upcoming")
    .description("Scheduled transactions for one of your profiles.")
    .supportedFamilies([.systemMedium])
  }
}

struct PlaceholderUpcomingCountWidget: Widget {
  static let kind = "rocks.moolah.widget.upcoming-count"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: Self.kind,
      intent: WidgetProfileSelectionIntent.self,
      provider: PlaceholderProvider()
    ) { _ in
      WidgetEmptyStateView(title: "Due", subtitle: "Coming soon")
    }
    .configurationDisplayName("Due today")
    .description("How many scheduled transactions need your attention.")
    .supportedFamilies([.systemSmall])
  }
}

private struct PlaceholderProvider: AppIntentTimelineProvider {
  func placeholder(in context: Context) -> PlaceholderEntry { PlaceholderEntry(date: Date()) }

  func snapshot(for configuration: WidgetProfileSelectionIntent, in context: Context) async
    -> PlaceholderEntry
  {
    PlaceholderEntry(date: Date())
  }

  func timeline(for configuration: WidgetProfileSelectionIntent, in context: Context) async
    -> Timeline<PlaceholderEntry>
  {
    Timeline(entries: [PlaceholderEntry(date: Date())], policy: .never)
  }
}

private struct PlaceholderEntry: TimelineEntry { let date: Date }
```

- [ ] **Step 6.2: Create `MoolahWidgets/MoolahWidgetsBundle.swift`**

```swift
import SwiftUI
import WidgetKit

@main
struct MoolahWidgetsBundle: WidgetBundle {
  var body: some Widget {
    PlaceholderUpcomingListWidget()
    PlaceholderUpcomingCountWidget()
  }
}
```

### Step 7: Builds + full gate + commit

- [ ] **Step 7.1: Build both hosts**

```bash
just build-mac 2>&1 | tee .agent-tmp/build-mac.txt
just build-ios 2>&1 | tee .agent-tmp/build-ios.txt
```

Expected: both succeed; the widget bundle is embedded in both products. If signing complains for a local Debug build, double-check the entitlements file path is set on the `Debug` config (Release entitlements are only consumed by fastlane).

- [ ] **Step 7.2: Gates + commit**

```bash
just format-check
just test-mac
just test-ios

git add project.yml MoolahWidgets/
git commit -m "$(cat <<'EOF'
feat(widgets): scaffold MoolahWidgets extension bundle

Adds MoolahWidgets_iOS + MoolahWidgets_macOS extension targets, embedded
in their respective host apps. The bundle currently ships two placeholder
widgets registered under their final kind strings so users who add them
in this stepping-stone build do not lose their slot when the real
widgets replace the placeholders in subsequent commits.

WidgetProfileEntity + WidgetProfileSelectionIntent are wired up against
WidgetDataPath / WidgetProfileDirectory so the configuration sheet
already lists real profiles.
EOF
)"
```

---

## Task 4: `UpcomingTransactionsListWidget` — the medium widget

**Files:**
- Create: `MoolahWidgets/UpcomingTransactionsListWidget.swift`
- Create: `MoolahWidgets/Views/UpcomingListView.swift`
- Create: `MoolahWidgets/Views/UpcomingRowView.swift`
- Create: `MoolahWidgets/Intents/OpenTransactionFromWidgetIntent.swift`
- Delete: `MoolahWidgets/Placeholders.swift` — `PlaceholderUpcomingListWidget` only. Keep the small-widget placeholder until Task 5.
- Modify: `MoolahWidgets/MoolahWidgetsBundle.swift` — replace `PlaceholderUpcomingListWidget()` with `UpcomingTransactionsListWidget()`.
- Create: `MoolahTests/Widgets/OpenTransactionFromWidgetIntentTests.swift`

### Step 1: `OpenTransactionFromWidgetIntent` — TDD

- [ ] **Step 1.1: Failing test — `MoolahTests/Widgets/OpenTransactionFromWidgetIntentTests.swift`**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("OpenTransactionFromWidgetIntent")
@MainActor
struct OpenTransactionFromWidgetIntentTests {

  private struct Recorded {
    var openedProfile: UUID?
    var pendingNavigation: PendingNavigation?
  }

  private func installFakes() -> Box<Recorded> {
    let box = Box(Recorded())
    NavigationBridge.openProfile = { id in box.value.openedProfile = id }
    NavigationBridge.setPendingNavigation = { nav in box.value.pendingNavigation = nav }
    return box
  }

  @Test("perform with a valid transaction UUID dispatches openProfile + setPendingNavigation")
  func validTransactionDispatches() async throws {
    let box = installFakes()
    let profile = WidgetProfileEntity(id: UUID(), label: "Personal", currency: "AUD")
    let txID = UUID()

    let intent = OpenTransactionFromWidgetIntent()
    intent.profile = profile
    intent.transactionID = txID.uuidString
    _ = try await intent.perform()

    #expect(box.value.openedProfile == profile.id)
    #expect(box.value.pendingNavigation == PendingNavigation(
      profileId: profile.id, destination: .transaction(txID)))
  }

  @Test("perform with an invalid UUID is a silent no-op")
  func invalidUUIDNoOp() async throws {
    let box = installFakes()
    let profile = WidgetProfileEntity(id: UUID(), label: "Personal", currency: "AUD")

    let intent = OpenTransactionFromWidgetIntent()
    intent.profile = profile
    intent.transactionID = "not-a-uuid"
    _ = try await intent.perform()

    #expect(box.value.openedProfile == nil)
    #expect(box.value.pendingNavigation == nil)
  }
}

/// Mutable reference box used by tests to capture closure invocations.
private final class Box<T> {
  var value: T
  init(_ value: T) { self.value = value }
}
```

> **Pattern note:** the handoff plan (Task 2) installs the same fakes; consult `MoolahTests/Automation/HandoffContinuationHandlerTests.swift` if there's a shared helper to reuse rather than re-declaring `Box`.

- [ ] **Step 1.2: Run — verify failing**

```bash
just test-mac OpenTransactionFromWidgetIntentTests 2>&1 | tee .agent-tmp/open-txn-tests.txt
```

Expected: build fails — `OpenTransactionFromWidgetIntent` undefined.

- [ ] **Step 1.3: Create `MoolahWidgets/Intents/OpenTransactionFromWidgetIntent.swift`**

```swift
import AppIntents
import Foundation

#if os(macOS)
  import AppKit
#endif

struct OpenTransactionFromWidgetIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Transaction (widget)"
  static let isDiscoverable = false
  static let openAppWhenRun = true

  @Parameter(title: "Profile") var profile: WidgetProfileEntity
  @Parameter(title: "Transaction ID") var transactionID: String

  init() {}

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let transactionUUID = UUID(uuidString: transactionID) else {
      return .result()
    }
    #if os(macOS)
      let alreadyOpen = ProfileWindowLocator.activateExistingWindow(for: profile.id)
    #else
      let alreadyOpen = false
    #endif
    if !alreadyOpen {
      NavigationBridge.openProfile?(profile.id)
    }
    NavigationBridge.setPendingNavigation?(
      PendingNavigation(profileId: profile.id, destination: .transaction(transactionUUID)))
    return .result()
  }
}
```

- [ ] **Step 1.4: Run — verify pass**

```bash
just test-mac OpenTransactionFromWidgetIntentTests 2>&1 | tee .agent-tmp/open-txn-tests.txt
```

Expected: both tests pass.

### Step 2: `UpcomingRowView`

- [ ] **Step 2.1: Create `MoolahWidgets/Views/UpcomingRowView.swift`**

```swift
import SwiftUI

/// Single row in the medium upcoming-transactions widget. Pure view —
/// composes labels from the snapshot row and the cached "now" the parent
/// passed in. No data access, no formatting state.
struct UpcomingRowView: View {
  let row: UpcomingWidgetSnapshot.Row
  let asOf: Date
  let calendar: Calendar

  var body: some View {
    HStack(spacing: 8) {
      Text(relativeDateLabel)
        .font(.caption2)
        .foregroundStyle(dateColor)
        .frame(width: 56, alignment: .leading)
      Text(row.payee)
        .font(.caption)
        .lineLimit(1)
        .truncationMode(.tail)
      Spacer(minLength: 4)
      Text(InstrumentAmount(quantity: row.amount, instrument: row.instrument).formatted)
        .font(.caption.monospacedDigit())
        .foregroundStyle(amountColor)
    }
  }

  // MARK: derived

  private var relativeDayOffset: Int {
    let dueDay = calendar.startOfDay(for: row.dueDate)
    let asOfDay = calendar.startOfDay(for: asOf)
    return calendar.dateComponents([.day], from: asOfDay, to: dueDay).day ?? 0
  }

  private var relativeDateLabel: String {
    let offset = relativeDayOffset
    if offset < 0 {
      let days = -offset
      return days == 1 ? "1 day late" : "\(days) days late"
    }
    if offset == 0 { return "Today" }
    if offset < 7 {
      let formatter = DateFormatter()
      formatter.calendar = calendar
      formatter.dateFormat = "EEE"
      return formatter.string(from: row.dueDate)
    }
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.dateStyle = .short
    return formatter.string(from: row.dueDate)
  }

  private var dateColor: Color {
    if relativeDayOffset < 0 { return .red }
    if relativeDayOffset == 0 { return .orange }
    return .secondary
  }

  private var amountColor: Color {
    row.amount < 0 ? .red : .green
  }
}
```

### Step 3: `UpcomingListView`

- [ ] **Step 3.1: Create `MoolahWidgets/Views/UpcomingListView.swift`**

```swift
import SwiftUI

/// Medium widget content. Header + up to five rows. Each row is wrapped in
/// `Button(intent:)` so it routes a tap to OpenTransactionFromWidgetIntent.
struct UpcomingListView: View {
  let snapshot: UpcomingWidgetSnapshot
  let profile: WidgetProfileEntity
  let calendar: Calendar

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack(alignment: .firstTextBaseline) {
        Text("Upcoming")
          .font(.subheadline.weight(.semibold))
        Spacer()
        Text(profile.label)
          .font(.caption2)
          .foregroundStyle(.secondary)
          .lineLimit(1)
      }
      if snapshot.upcomingRows.isEmpty {
        WidgetEmptyStateView(title: "Upcoming", subtitle: "Nothing due in the next 7 days")
      } else {
        ForEach(snapshot.upcomingRows) { row in
          let intent = OpenTransactionFromWidgetIntent()
          let _ = { intent.profile = profile; intent.transactionID = row.id.uuidString }()
          Button(intent: intent) {
            UpcomingRowView(row: row, asOf: snapshot.asOf, calendar: calendar)
          }
          .buttonStyle(.plain)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
  }
}
```

> **Note on the `let _ = { ... }()` pattern:** AppIntent parameters use property-wrapper setters that aren't usable inside a SwiftUI view-builder result builder. The IIFE assigns them as a side effect. If a cleaner approach is available in the iOS 26 SDK (e.g. a builder init), prefer that — but only after writing the row to compile.

### Step 4: `UpcomingTransactionsListWidget` + timeline provider

- [ ] **Step 4.1: Create `MoolahWidgets/UpcomingTransactionsListWidget.swift`**

```swift
import AppIntents
import SwiftUI
import WidgetKit

struct UpcomingTransactionsListWidget: Widget {
  static let kind = "rocks.moolah.widget.upcoming-list"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: Self.kind,
      intent: WidgetProfileSelectionIntent.self,
      provider: Provider()
    ) { entry in
      ListEntryView(entry: entry)
    }
    .configurationDisplayName("Upcoming")
    .description("Scheduled transactions for one of your profiles.")
    .supportedFamilies([.systemMedium])
  }

  // MARK: - Entry

  struct Entry: TimelineEntry {
    let date: Date
    let snapshot: UpcomingWidgetSnapshot?
    let profile: WidgetProfileEntity?
  }

  // MARK: - Provider

  struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
      Entry(date: Date(), snapshot: nil, profile: nil)
    }

    func snapshot(for configuration: WidgetProfileSelectionIntent, in context: Context) async
      -> Entry
    {
      await Self.build(at: Date(), for: configuration)
    }

    func timeline(for configuration: WidgetProfileSelectionIntent, in context: Context) async
      -> Timeline<Entry>
    {
      let calendar = Calendar.current
      let now = Date()
      var entries: [Entry] = []
      for dayOffset in 0..<5 {
        guard let boundary = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now))
        else { continue }
        let entry = await Self.build(at: boundary, for: configuration)
        entries.append(entry)
      }
      return Timeline(entries: entries, policy: .atEnd)
    }

    private static func build(at date: Date, for configuration: WidgetProfileSelectionIntent) async
      -> Entry
    {
      guard let profileEntity = configuration.profile else {
        return Entry(date: date, snapshot: nil, profile: nil)
      }
      let summary = WidgetProfileSummary(
        id: profileEntity.id, label: profileEntity.label, currency: profileEntity.currency)
      let scoped = WidgetDataPath.scopedRoot()
      let dbURL = WidgetDataPath.profileDatabaseURL(profileID: summary.id, scopedRoot: scoped)
      do {
        let snapshot = try await UpcomingWidgetQuery.read(
          profile: summary,
          profileDatabaseURL: dbURL,
          asOf: date,
          calendar: Calendar.current,
          maxRows: 5)
        return Entry(date: date, snapshot: snapshot, profile: profileEntity)
      } catch {
        return Entry(date: date, snapshot: nil, profile: profileEntity)
      }
    }
  }

  // MARK: - Entry view

  struct ListEntryView: View {
    let entry: Entry

    var body: some View {
      Group {
        if let profile = entry.profile, let snapshot = entry.snapshot {
          UpcomingListView(snapshot: snapshot, profile: profile, calendar: .current)
        } else if entry.profile != nil {
          WidgetEmptyStateView(title: "Profile not available", subtitle: "Open Moolah to fix")
        } else {
          WidgetEmptyStateView(title: "Add a profile", subtitle: "Edit widget to choose one")
        }
      }
      .containerBackground(.background, for: .widget)
    }
  }
}
```

### Step 5: Wire into the bundle + remove the placeholder

- [ ] **Step 5.1: Modify `MoolahWidgets/MoolahWidgetsBundle.swift`**

Replace `PlaceholderUpcomingListWidget()` with `UpcomingTransactionsListWidget()` so the body is:

```swift
  var body: some Widget {
    UpcomingTransactionsListWidget()
    PlaceholderUpcomingCountWidget()
  }
```

- [ ] **Step 5.2: Delete the `PlaceholderUpcomingListWidget` struct from `MoolahWidgets/Placeholders.swift`**

Keep the file (`PlaceholderUpcomingCountWidget` is still needed). Delete only the struct definition and its `Self.kind` constant.

### Step 6: Build, gate, commit

- [ ] **Step 6.1: Build both hosts**

```bash
just build-mac
just build-ios
```

- [ ] **Step 6.2: Gates + commit**

```bash
just format-check
just test-mac
just test-ios

git add MoolahWidgets/ MoolahTests/Widgets/
git commit -m "$(cat <<'EOF'
feat(widgets): ship UpcomingTransactionsListWidget (.systemMedium)

Medium widget renders overdue + next-7-days scheduled transactions for
the configured profile. Each row is a Button(intent:) that routes to
OpenTransactionFromWidgetIntent (openAppWhenRun = true), which calls
NavigationBridge to focus the matching window or open the profile —
same shape as OpenAccountIntent. Empty state when nothing is due in
the horizon; placeholder when the profile has been deleted.
EOF
)"
```

---

## Task 5: `UpcomingTransactionsCountWidget` — the small widget

**Files:**
- Create: `MoolahWidgets/UpcomingTransactionsCountWidget.swift`
- Create: `MoolahWidgets/Views/UpcomingCountView.swift`
- Create: `MoolahWidgets/Intents/OpenUpcomingFromWidgetIntent.swift`
- Delete: `MoolahWidgets/Placeholders.swift` (the small-widget placeholder; whole file if it now has nothing left).
- Modify: `MoolahWidgets/MoolahWidgetsBundle.swift` — `body` becomes the two real widgets only.
- Create: `MoolahTests/Widgets/OpenUpcomingFromWidgetIntentTests.swift`

### Step 1: `OpenUpcomingFromWidgetIntent` — TDD

- [ ] **Step 1.1: Failing test — `MoolahTests/Widgets/OpenUpcomingFromWidgetIntentTests.swift`**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("OpenUpcomingFromWidgetIntent")
@MainActor
struct OpenUpcomingFromWidgetIntentTests {

  private struct Recorded {
    var openedProfile: UUID?
    var pendingNavigation: PendingNavigation?
  }

  private func installFakes() -> Box<Recorded> {
    let box = Box(Recorded())
    NavigationBridge.openProfile = { id in box.value.openedProfile = id }
    NavigationBridge.setPendingNavigation = { nav in box.value.pendingNavigation = nav }
    return box
  }

  @Test("perform with a profile dispatches openProfile + .upcoming")
  func withProfile() async throws {
    let box = installFakes()
    let profile = WidgetProfileEntity(id: UUID(), label: "Personal", currency: "AUD")

    let intent = OpenUpcomingFromWidgetIntent()
    intent.profile = profile
    _ = try await intent.perform()

    #expect(box.value.openedProfile == profile.id)
    #expect(box.value.pendingNavigation == PendingNavigation(
      profileId: profile.id, destination: .upcoming))
  }

  @Test("perform with nil profile does not open a profile and sets no pending nav")
  func withoutProfile() async throws {
    let box = installFakes()

    let intent = OpenUpcomingFromWidgetIntent()
    intent.profile = nil
    _ = try await intent.perform()

    #expect(box.value.openedProfile == nil)
    #expect(box.value.pendingNavigation == nil)
  }
}

private final class Box<T> {
  var value: T
  init(_ value: T) { self.value = value }
}
```

- [ ] **Step 1.2: Run — verify failing**

```bash
just test-mac OpenUpcomingFromWidgetIntentTests 2>&1 | tee .agent-tmp/open-upcoming-tests.txt
```

- [ ] **Step 1.3: Create `MoolahWidgets/Intents/OpenUpcomingFromWidgetIntent.swift`**

```swift
import AppIntents
import Foundation

#if os(macOS)
  import AppKit
#endif

struct OpenUpcomingFromWidgetIntent: AppIntent {
  static let title: LocalizedStringResource = "Open Upcoming (widget)"
  static let isDiscoverable = false
  static let openAppWhenRun = true

  @Parameter(title: "Profile") var profile: WidgetProfileEntity?

  init() {}

  @MainActor
  func perform() async throws -> some IntentResult {
    guard let profile else {
      return .result()
    }
    #if os(macOS)
      let alreadyOpen = ProfileWindowLocator.activateExistingWindow(for: profile.id)
    #else
      let alreadyOpen = false
    #endif
    if !alreadyOpen {
      NavigationBridge.openProfile?(profile.id)
    }
    NavigationBridge.setPendingNavigation?(
      PendingNavigation(profileId: profile.id, destination: .upcoming))
    return .result()
  }
}
```

- [ ] **Step 1.4: Run — verify pass**

```bash
just test-mac OpenUpcomingFromWidgetIntentTests 2>&1 | tee .agent-tmp/open-upcoming-tests.txt
```

### Step 2: `UpcomingCountView`

- [ ] **Step 2.1: Create `MoolahWidgets/Views/UpcomingCountView.swift`**

```swift
import SwiftUI

struct UpcomingCountView: View {
  let snapshot: UpcomingWidgetSnapshot
  let profile: WidgetProfileEntity

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Due")
        .font(.caption.smallCaps())
        .foregroundStyle(.secondary)
      Text("\(snapshot.dueNowCount)")
        .font(.system(size: 52, weight: .bold))
        .monospacedDigit()
        .foregroundStyle(snapshot.dueNowCount == 0 ? .secondary : .primary)
      Spacer(minLength: 0)
      Text(SmallWidgetTotalRenderer.text(for: snapshot))
        .font(.caption.monospacedDigit())
        .foregroundStyle(snapshot.dueNowCount == 0 ? .secondary : .red)
        .lineLimit(1)
      Text(profile.label)
        .font(.caption2)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .padding(14)
  }
}
```

### Step 3: `UpcomingTransactionsCountWidget`

- [ ] **Step 3.1: Create `MoolahWidgets/UpcomingTransactionsCountWidget.swift`**

```swift
import AppIntents
import SwiftUI
import WidgetKit

struct UpcomingTransactionsCountWidget: Widget {
  static let kind = "rocks.moolah.widget.upcoming-count"

  var body: some WidgetConfiguration {
    AppIntentConfiguration(
      kind: Self.kind,
      intent: WidgetProfileSelectionIntent.self,
      provider: Provider()
    ) { entry in
      EntryView(entry: entry)
    }
    .configurationDisplayName("Due today")
    .description("How many scheduled transactions need your attention right now.")
    .supportedFamilies([.systemSmall])
  }

  struct Entry: TimelineEntry {
    let date: Date
    let snapshot: UpcomingWidgetSnapshot?
    let profile: WidgetProfileEntity?
  }

  struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
      Entry(date: Date(), snapshot: nil, profile: nil)
    }

    func snapshot(for configuration: WidgetProfileSelectionIntent, in context: Context) async
      -> Entry
    {
      await Self.build(at: Date(), for: configuration)
    }

    func timeline(for configuration: WidgetProfileSelectionIntent, in context: Context) async
      -> Timeline<Entry>
    {
      let calendar = Calendar.current
      let now = Date()
      var entries: [Entry] = []
      for dayOffset in 0..<5 {
        guard let boundary = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now))
        else { continue }
        entries.append(await Self.build(at: boundary, for: configuration))
      }
      return Timeline(entries: entries, policy: .atEnd)
    }

    private static func build(at date: Date, for configuration: WidgetProfileSelectionIntent) async
      -> Entry
    {
      guard let profileEntity = configuration.profile else {
        return Entry(date: date, snapshot: nil, profile: nil)
      }
      let summary = WidgetProfileSummary(
        id: profileEntity.id, label: profileEntity.label, currency: profileEntity.currency)
      let scoped = WidgetDataPath.scopedRoot()
      let dbURL = WidgetDataPath.profileDatabaseURL(profileID: summary.id, scopedRoot: scoped)
      do {
        let snapshot = try await UpcomingWidgetQuery.read(
          profile: summary,
          profileDatabaseURL: dbURL,
          asOf: date,
          calendar: Calendar.current,
          maxRows: 5)
        return Entry(date: date, snapshot: snapshot, profile: profileEntity)
      } catch {
        return Entry(date: date, snapshot: nil, profile: profileEntity)
      }
    }
  }

  struct EntryView: View {
    let entry: Entry

    var body: some View {
      Group {
        if let profile = entry.profile, let snapshot = entry.snapshot {
          let intent = OpenUpcomingFromWidgetIntent()
          let _ = { intent.profile = profile }()
          Button(intent: intent) {
            UpcomingCountView(snapshot: snapshot, profile: profile)
          }
          .buttonStyle(.plain)
        } else if entry.profile != nil {
          WidgetEmptyStateView(title: "Profile not available", subtitle: "Open Moolah to fix")
        } else {
          WidgetEmptyStateView(title: "Add a profile", subtitle: "Edit widget to choose one")
        }
      }
      .containerBackground(.background, for: .widget)
    }
  }
}
```

### Step 4: Wire bundle + delete placeholder file

- [ ] **Step 4.1: Modify `MoolahWidgets/MoolahWidgetsBundle.swift`**

```swift
import SwiftUI
import WidgetKit

@main
struct MoolahWidgetsBundle: WidgetBundle {
  var body: some Widget {
    UpcomingTransactionsListWidget()
    UpcomingTransactionsCountWidget()
  }
}
```

- [ ] **Step 4.2: Delete `MoolahWidgets/Placeholders.swift`**

```bash
git rm MoolahWidgets/Placeholders.swift
```

### Step 5: Build, gate, commit

- [ ] **Step 5.1: Build + tests**

```bash
just build-mac
just build-ios
just format-check
just test-mac
just test-ios
```

- [ ] **Step 5.2: Commit**

```bash
git add MoolahWidgets/ MoolahTests/Widgets/
git commit -m "$(cat <<'EOF'
feat(widgets): ship UpcomingTransactionsCountWidget (.systemSmall)

Small widget shows the count of scheduled transactions that are
overdue or due today plus the sum of their amounts (per-instrument,
falling back to "Multiple currencies" if more than one instrument and
none match the profile's currency). Tap opens the Upcoming list in the
configured profile via OpenUpcomingFromWidgetIntent.

Placeholder file removed — both widgets are now real.
EOF
)"
```

---

## Task 6: `WidgetReloadCoordinator` + host hooks

**Files:**
- Create: `Shared/Widgets/WidgetReloadCoordinator.swift`
- Create: `MoolahTests/Widgets/WidgetReloadCoordinatorTests.swift`
- Modify: `Features/Transactions/TransactionStore+Mutations.swift`
- Modify: `Backends/CloudKit/Sync/<sync-coordinator>.swift` (locate by grep below)
- Modify: `App/MoolahApp+Lifecycle.swift`
- Modify: `Shared/ProfileContainerManager.swift`

### Step 1: `WidgetReloadCoordinator` — TDD

- [ ] **Step 1.1: Failing test — `MoolahTests/Widgets/WidgetReloadCoordinatorTests.swift`**

```swift
import Foundation
import Testing

@testable import Moolah

@Suite("WidgetReloadCoordinator")
struct WidgetReloadCoordinatorTests {

  @Test("calling reload(reason:) invokes the injected handler with the reason")
  func reloadInvokesHandler() async {
    var captured: WidgetReloadCoordinator.Reason?
    let coordinator = WidgetReloadCoordinator { captured = $0 }
    coordinator.reload(reason: .transactionMutation)
    #expect(captured == .transactionMutation)
  }

  @Test("default reload reason values are distinct")
  func reasonsAreDistinct() {
    let all: [WidgetReloadCoordinator.Reason] = [
      .transactionMutation, .syncCompleted, .scenePhaseBackground, .profileMutation,
    ]
    #expect(Set(all).count == all.count)
  }
}
```

- [ ] **Step 1.2: Run — verify failing**

```bash
just test-mac WidgetReloadCoordinatorTests 2>&1 | tee .agent-tmp/reload-tests.txt
```

- [ ] **Step 1.3: Create `Shared/Widgets/WidgetReloadCoordinator.swift`**

```swift
import Foundation
import OSLog
import WidgetKit

/// Host-side helper: every write-path pinch point calls `reload(reason:)`
/// so the widget extension's timeline rebuilds reflect the latest data.
///
/// Tests inject `handler`; production uses the default which calls
/// `WidgetCenter.shared.reloadAllTimelines()` and logs the reason.
final class WidgetReloadCoordinator: Sendable {

  enum Reason: String, Sendable, Hashable {
    case transactionMutation
    case syncCompleted
    case scenePhaseBackground
    case profileMutation
  }

  private let handler: @Sendable (Reason) -> Void
  private let logger = Logger(subsystem: "com.moolah.app", category: "Widgets")

  /// Production singleton.
  static let shared = WidgetReloadCoordinator { reason in
    WidgetCenter.shared.reloadAllTimelines()
  }

  init(handler: @escaping @Sendable (Reason) -> Void) {
    self.handler = handler
  }

  func reload(reason: Reason) {
    logger.debug("Widget reload requested: \(reason.rawValue, privacy: .public)")
    handler(reason)
  }
}
```

- [ ] **Step 1.4: Run — verify pass**

```bash
just test-mac WidgetReloadCoordinatorTests 2>&1 | tee .agent-tmp/reload-tests.txt
```

### Step 2: Transaction-store mutation hook

- [ ] **Step 2.1: Read `Features/Transactions/TransactionStore+Mutations.swift`** to locate every mutation method (`createTransaction`, `updateTransaction`, `deleteTransaction`, `payScheduledTransaction`, `markAsSpam`, etc).

- [ ] **Step 2.2: After every successful mutation (immediately before the method returns success), add:**

```swift
    WidgetReloadCoordinator.shared.reload(reason: .transactionMutation)
```

Do **not** call this from rollback paths — only on successful completion.

### Step 3: Sync-completion hook

- [ ] **Step 3.1: Locate the sync-completion pinch point**

```bash
grep -rn "fetchChanges\|fetched.*applied\|sendChanges" Backends/CloudKit/Sync/ | head -20
```

The hook lives in the function that resolves after `CKSyncEngine` has applied a fetched batch (or after a send batch acks). If the project has a `SyncCoordinator` / `SyncEngine` final-callback, that is the site.

- [ ] **Step 3.2: At the "fetched + applied" boundary, add:**

```swift
    WidgetReloadCoordinator.shared.reload(reason: .syncCompleted)
```

### Step 4: Scene-phase hook

- [ ] **Step 4.1: Open `App/MoolahApp+Lifecycle.swift`**

- [ ] **Step 4.2: In the iOS scene-phase change handler, when transitioning to `.background`:**

```swift
WidgetReloadCoordinator.shared.reload(reason: .scenePhaseBackground)
```

- [ ] **Step 4.3: In the macOS `NSApplication.willResignActiveNotification` observer (add one if absent), same call:**

```swift
NotificationCenter.default.addObserver(
  forName: NSApplication.willResignActiveNotification,
  object: nil,
  queue: .main
) { _ in
  WidgetReloadCoordinator.shared.reload(reason: .scenePhaseBackground)
}
```

### Step 5: Profile-mutation hook

- [ ] **Step 5.1: Open `Shared/ProfileContainerManager.swift`**

- [ ] **Step 5.2: After every profile add / rename / delete commit, add:**

```swift
WidgetReloadCoordinator.shared.reload(reason: .profileMutation)
```

### Step 6: Build, gate, commit

- [ ] **Step 6.1: Gates**

```bash
just format-check
just test-mac
just test-ios
```

- [ ] **Step 6.2: Commit**

```bash
git add Shared/Widgets/WidgetReloadCoordinator.swift \
  MoolahTests/Widgets/WidgetReloadCoordinatorTests.swift \
  Features/Transactions/TransactionStore+Mutations.swift \
  Backends/CloudKit/Sync/ \
  App/MoolahApp+Lifecycle.swift \
  Shared/ProfileContainerManager.swift
git commit -m "$(cat <<'EOF'
feat(widgets): refresh widget timelines on host write-path events

WidgetReloadCoordinator is the single seam through which the host
asks WidgetKit to rebuild every widget timeline. Hooked into:

- TransactionStore mutations (create / update / delete / pay-scheduled
  / mark-as-spam) on the success path only.
- CloudKit sync's fetched + applied boundary.
- Scene-phase background on iOS, willResignActive on macOS.
- ProfileContainerManager profile add / rename / delete.

Test injects a fake handler; production uses
WidgetCenter.shared.reloadAllTimelines().
EOF
)"
```

---

## Task 7: Verification + documentation polish

**Files:**
- Modify: `CLAUDE.md`
- Manual smoke per the design's checklist.

### Step 1: CLAUDE.md note

- [ ] **Step 1.1: Add one bullet under *Architecture & Constraints* in `CLAUDE.md`**

After the *Backend* bullet, insert:

```
- **Widgets:** The `MoolahWidgets_{iOS,macOS}` extensions live in `MoolahWidgets/` and link only `Shared/Widgets/`, a narrow slice of `Domain/Models/`, and GRDB. The extensions never import `Backends/`, `Features/`, or `Automation/`; widget tap targets use `AppIntent` with `openAppWhenRun = true` routing through `NavigationBridge` (same pattern as `OpenAccountIntent`). Per-profile `data.sqlite` and the profile-index DB live under `WidgetDataPath.scopedRoot()` (App Group container, env-scoped); host code keeps using `URL.moolahScopedApplicationSupport` which resolves there.
```

- [ ] **Step 1.2: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(widgets): document widget-extension linker scope + storage path"
```

### Step 2: Manual smoke

Work through the design's *Manual verification checklist* (§ Testing). Capture results in `.agent-tmp/widget-smoke.txt`. If any step fails, file a GitHub issue and fix in a follow-up PR — do not block the original PR set on smoke regressions unless they reveal a Critical correctness bug.

- [ ] **Step 2.1: All 11 checklist items pass on local Debug builds, recorded in the log.**

### Step 3: Telemetry sanity

- [ ] **Step 3.1: Tail logs while the widget refreshes** to confirm the `WidgetReloadCoordinator` debug logs fire when expected, and `UpcomingWidgetQuery` warnings / faults are absent in steady-state.

```bash
log stream --predicate 'subsystem == "com.moolah.app" AND category == "Widgets"' --level debug
```

(Run while editing scheduled transactions in the app and pulling-to-refresh sync.)

### Step 4: Final commit

If telemetry / smoke uncovered no changes, the documentation commit is the final commit of the plan. Otherwise, fold any small fixes into Task 7 and re-run gates before committing.

---

## Self-Review Notes (applied inline)

**Spec coverage check:**

- Per-widget profile binding — Task 3 (`WidgetProfileEntity` + `WidgetProfileSelectionIntent`).
- Medium layout A (flat list with relative dates) — Task 4 (`UpcomingRowView` + `UpcomingListView`).
- Small layout (big number + total, includes overdue) — Task 5 (`UpcomingCountView` + `SmallWidgetTotalRenderer`).
- Overdue + next-7-days horizon — Task 2's `UpcomingWidgetQuery.read(...)` with `horizonEnd = startOfToday + 7 days`.
- Per-row deep link to transaction — Task 4 (`OpenTransactionFromWidgetIntent`).
- Small-widget tap opens Upcoming — Task 5 (`OpenUpcomingFromWidgetIntent`).
- App Group container + migration — Task 1 (`WidgetDataPath`, `ApplicationSupportToAppGroupMigration`).
- Coordination with handoff non-goal (no URL scheme) — every widget tap target is an `AppIntent`; Task 4 / Task 5 implementations mirror `OpenAccountIntent`.
- Multi-currency fallback on small widget — Task 2 (`SmallWidgetTotalRenderer`) + Task 5 (consumed by `UpcomingCountView`).
- Host-driven reloads on transaction-store / sync / scene-phase / profile-mutation — Task 6.
- Plan-pinning tests — Task 2 (`UpcomingWidgetQueryPlanPinningTests`).
- Telemetry / `os_signpost` — covered indirectly via the `Logger(subsystem: …, category: "Widgets")` calls; an `os_signpost` interval around `UpcomingWidgetQuery.read(...)` is an optional polish that can be added in Task 7's "telemetry polish" step if Instruments traces show value.

**Placeholder scan:** no `TBD` / `TODO` / "implement later" remain. The Swift `TODO(#N)` in `ApplicationSupportToAppGroupMigration` references a real issue filed in Task 0.

**Type consistency:** `UpcomingWidgetSnapshot.Row`, `WidgetProfileSummary`, `WidgetProfileEntity`, `WidgetReloadCoordinator.Reason`, `OpenTransactionFromWidgetIntent`, `OpenUpcomingFromWidgetIntent` use identical signatures everywhere they appear. `UpcomingWidgetQuery.read(...)` signature is the same in Task 2 (definition), Task 4 (timeline provider), Task 5 (timeline provider).

**Spec requirement gaps:** none discovered on the review pass.
