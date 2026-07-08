import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("ProfileStore")
@MainActor
struct ProfileStoreTests {
  private func makeDefaults() -> UserDefaults {
    let suiteName = "com.moolah.test.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName)
    else { preconditionFailure("a fresh UUID-based suite name always yields a UserDefaults") }
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
  }

  private func makeProfile(label: String = "Test") -> Profile {
    Profile(label: label)
  }

  /// Installs a `BEFORE INSERT` trigger on the manager's profile-index
  /// queue that aborts any write whose `label` matches the sentinel
  /// `___FAIL___`. Mirrors the pattern in `ProfileIndexRollbackTests` —
  /// gives tests a deterministic, in-process failure injection point
  /// without mocking the repository.
  private func installFailingProfileTrigger(
    on manager: ProfileContainerManager,
    name: String = "fail_profile_store_test"
  ) async throws {
    try await manager.profileIndexDatabase.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER \(name)
          BEFORE INSERT ON profile
          WHEN NEW.label = '___FAIL___'
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }
  }

  // MARK: - Add

  @Test("addProfile appends and sets first profile as active")
  func addFirstProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let profile = makeProfile()

    store.addProfile(profile)

    #expect(store.profiles.count == 1)
    #expect(store.activeProfileID == profile.id)
    #expect(store.activeProfile == profile)
    #expect(store.hasProfiles == true)
  }

  @Test("addProfile does not change active when adding second profile")
  func addSecondProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    store.addProfile(first)
    store.addProfile(second)

    #expect(store.profiles.count == 2)
    #expect(store.activeProfileID == first.id)
  }

  // MARK: - Remove

  @Test("removeProfile removes and switches active to next profile")
  func removeActiveProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    store.addProfile(first)
    store.addProfile(second)
    store.removeProfile(first.id)

    #expect(store.profiles.count == 1)
    #expect(store.activeProfileID == second.id)
  }

  @Test("removeProfile clears active when last profile removed")
  func removeLastProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let profile = makeProfile()

    store.addProfile(profile)
    store.removeProfile(profile.id)

    #expect(store.profiles.isEmpty)
    #expect(store.activeProfileID == nil)
    #expect(store.hasProfiles == false)
  }

  // MARK: - Switch

  @Test("setActiveProfile switches to specified profile")
  func switchProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    store.addProfile(first)
    store.addProfile(second)
    store.setActiveProfile(second.id)

    #expect(store.activeProfileID == second.id)
  }

  @Test("setActiveProfile ignores unknown profile ID")
  func switchToUnknownProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let profile = makeProfile()

    store.addProfile(profile)
    store.setActiveProfile(UUID())

    #expect(store.activeProfileID == profile.id)
  }

  // MARK: - Update

  @Test("updateProfile modifies the profile in place")
  func updateProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    var profile = makeProfile(label: "Old")
    store.addProfile(profile)

    profile.label = "New"
    store.updateProfile(profile)

    #expect(store.profiles[0].label == "New")
  }

  @Test("updateProfile ignores unknown profile")
  func updateUnknownProfile() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let unknown = makeProfile(label: "Ghost")

    store.updateProfile(unknown)

    #expect(store.profiles.isEmpty)
  }

  @Test("updateProfilePersisting applies a mutation to the latest profile")
  func updateProfilePersistingAppliesMutation() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let profile = makeProfile(label: "Old")
    store.addProfile(profile)
    await drainPendingMutations(store)

    try await store.updateProfilePersisting(id: profile.id) { profile in
      profile.label = "New"
    }

    #expect(store.profiles.first { $0.id == profile.id }?.label == "New")
    let saved = try #require(
      try await manager.profileIndexRepository.fetchAll().first {
        $0.id == profile.id
      })
    #expect(saved.label == "New")
  }

  // MARK: - Persistence

  @Test("active profile ID persists across instances")
  func activeProfilePersists() throws {
    let defaults = makeDefaults()
    let manager = try ProfileContainerManager.forTesting()
    let first = makeProfile(label: "First")
    let second = makeProfile(label: "Second")

    let store1 = ProfileStore(defaults: defaults, containerManager: manager)
    store1.addProfile(first)
    store1.addProfile(second)
    store1.setActiveProfile(second.id)

    let store2 = ProfileStore(defaults: defaults, containerManager: manager)
    #expect(store2.activeProfileID == second.id)
  }

  // MARK: - Initial-load race

  /// `init` must populate `profiles` synchronously from GRDB before any
  /// await, so it is non-empty on the first scene tick. If `profiles`
  /// were empty there, `ProfileWindowView.resolvedProfile` would fall
  /// through to `WelcomeView` even though a profile exists on disk,
  /// breaking every UI test seed that relies on the seeded profile
  /// being immediately resolvable.
  @Test("init populates profiles synchronously from GRDB before any await")
  func initSynchronousPopulation() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let preSeeded = Profile(label: "Pre-seeded")
    try await manager.profileIndexRepository.upsert(preSeeded)

    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    // No drain — the assertion is that `profiles` is populated before
    // the first scene tick (i.e. without any await between init and
    // the read).
    #expect(store.profiles.map(\.id) == [preSeeded.id])
  }

  /// Regression for the race where an async initial cloud load lands
  /// after an optimistic `addProfile`. Before the fix the load
  /// blindly assigned `profiles = loaded`, dropping the optimistic
  /// addition (and any GRDB row that hadn't yet committed when the
  /// fetch ran). The pre-seeded GRDB row plus the in-memory addition
  /// are both expected after `drainPendingMutations`.
  @Test("initial cloud load merges with in-flight optimistic addProfile")
  func initialLoadMergesOptimisticAdd() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let preSeeded = Profile(label: "Pre-seeded")
    try await manager.profileIndexRepository.upsert(preSeeded)

    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    // Optimistic addProfile lands synchronously, before the init's
    // async load can read GRDB. The race the fix targets: the load
    // sees only the pre-seeded row, not the just-added one.
    let optimistic = Profile(label: "Optimistic")
    store.addProfile(optimistic)

    await drainPendingMutations(store)

    let ids = Set(store.profiles.map(\.id))
    #expect(ids == [preSeeded.id, optimistic.id])
    let onDisk = try await manager.profileIndexRepository.fetchAll()
    #expect(Set(onDisk.map(\.id)) == [preSeeded.id, optimistic.id])
  }

  // MARK: - Empty state

  @Test("fresh store with no data has no profiles")
  func emptyState() throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)

    #expect(store.profiles.isEmpty)
    #expect(store.activeProfileID == nil)
    #expect(store.activeProfile == nil)
    #expect(store.hasProfiles == false)
  }

  // MARK: - Validation: Add

  @Test("validateAndAddProfile adds profile when iCloud available")
  func validateAndAddSuccess() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let profile = makeProfile()

    // In tests without CloudKit entitlements, validateiCloudAvailability returns true
    // (the guard skips the account status check)
    let result = await store.validateAndAddProfile(profile)

    #expect(result == true)
    #expect(store.profiles.count == 1)
    #expect(store.profiles[0] == profile)
    #expect(store.validationError == nil)
  }

  // MARK: - Validation: Update

  // MARK: - Rollback on GRDB write failure
  //
  // Each test installs a `BEFORE INSERT` trigger that aborts any write
  // touching a sentinel label. The store performs an optimistic
  // in-memory mutation, then awaits the GRDB write Task; once the
  // failure surfaces the rollback closure must restore the prior
  // state so what observers see matches what is on disk.

  @Test("addProfile rolls back optimistic state when GRDB write fails")
  func addProfileRollsBackOnFailure() async throws {
    let manager = try ProfileContainerManager.forTesting()
    try await installFailingProfileTrigger(on: manager)
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)
    let failing = Profile(label: "___FAIL___")

    // Optimistic insert lands synchronously…
    store.addProfile(failing)
    #expect(store.profiles.contains { $0.id == failing.id })
    #expect(store.activeProfileID == failing.id)

    // …and is rolled back once the GRDB write Task surfaces the error.
    await drainPendingMutations(store)
    #expect(store.profiles.isEmpty)
    #expect(store.activeProfileID == nil)
    let onDisk = try await manager.profileIndexRepository.fetchAll()
    #expect(onDisk.isEmpty)
  }

  @Test("updateProfile restores prior profile when GRDB write fails")
  func updateProfileRollsBackOnFailure() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)

    let original = Profile(label: "Original")
    store.addProfile(original)
    await drainPendingMutations(store)

    // Trigger installed AFTER the seed so the original write succeeds;
    // the next write that touches the sentinel label will trip it.
    try await installFailingProfileTrigger(on: manager)

    var failing = original
    failing.label = "___FAIL___"
    store.updateProfile(failing)
    #expect(store.profiles.first { $0.id == original.id }?.label == "___FAIL___")

    await drainPendingMutations(store)
    let restored = try #require(store.profiles.first { $0.id == original.id })
    #expect(restored.label == "Original")
    let onDisk = try await manager.profileIndexRepository.fetchAll()
    #expect(onDisk.first?.label == "Original")
  }

  @Test("removeProfile re-inserts profile when GRDB delete fails")
  func removeProfileRollsBackOnFailure() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let store = ProfileStore(defaults: makeDefaults(), containerManager: manager)

    let first = Profile(label: "First")
    let second = Profile(label: "Second")
    store.addProfile(first)
    store.addProfile(second)
    await drainPendingMutations(store)

    // Install a `BEFORE DELETE` trigger that always aborts so the
    // delete throws. Distinct from the insert-side helper because
    // upsert/delete travel different SQLite codepaths.
    try await manager.profileIndexDatabase.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_profile_store_delete
          BEFORE DELETE ON profile
          BEGIN
              SELECT RAISE(ABORT, 'forced delete failure for rollback test');
          END;
          """)
    }

    store.setActiveProfile(first.id)
    let priorIDs = store.profiles.map(\.id)
    store.removeProfile(first.id)
    // Optimistic removal lands synchronously.
    #expect(!store.profiles.contains { $0.id == first.id })
    #expect(store.activeProfileID == second.id)

    await drainPendingMutations(store)
    // Rolled back: the profile is back at its original index, and the
    // active id is restored.
    #expect(store.profiles.map(\.id) == priorIDs)
    #expect(store.activeProfileID == first.id)
    let onDisk = try await manager.profileIndexRepository.fetchAll()
    #expect(Set(onDisk.map(\.id)) == Set(priorIDs))
  }
}
