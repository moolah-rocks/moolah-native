import CloudKit
import Foundation
import OSLog
import Observation

/// Manages the list of profiles and which one is active.
/// Profiles persist as CloudKit `ProfileRecord` rows in the GRDB
/// profile-index database; the active profile ID is per-device via
/// UserDefaults.
@Observable
@MainActor
final class ProfileStore {
  // internal (was private) so the `+Cloud` extension can key UserDefaults
  // lookups under the same constants.
  static let activeProfileKey = "com.moolah.activeProfileID"

  // Setters widened from `private(set)` to default (internal) so the
  // `+Cloud` extension file can mutate them while loading / validating.
  var profiles: [Profile] = []
  var activeProfileID: UUID?
  var isValidating = false
  var validationError: String?

  /// Signal from `WelcomeView` about which interaction phase is on screen.
  /// When `.creating`, `loadCloudProfiles` suppresses its auto-activate
  /// behaviour so a single profile arriving from iCloud doesn't race the
  /// user's in-flight "Create Profile" tap. Cleared (`nil`) when
  /// `WelcomeView` unmounts. See design spec §3.3, §8.
  enum WelcomePhase: Sendable {
    case landing
    case creating
    case pickingProfile
  }

  var welcomePhase: WelcomePhase?

  /// True while the initial cloud profile load may still be retrying.
  /// CloudKit-driven remote inserts may not have landed yet on the
  /// first fetch.
  var isCloudLoadPending = false

  /// The currently-scheduled retry task, tracked so it can be cancelled when a
  /// fresh load arrives (e.g. from a remote change notification) or when a new
  /// retry is queued. See `guides/CONCURRENCY_GUIDE.md` — fire-and-forget
  /// `Task {}` in stores must be tracked.
  var retryTask: Task<Void, Never>?

  /// In-flight tracked tasks for fire-and-forget GRDB writes (add /
  /// update / remove / cloud load). Tasks self-evict on completion so
  /// the array doesn't grow unbounded across long-running sessions.
  /// See `guides/CONCURRENCY_GUIDE.md` — every fire-and-forget Task
  /// in a store must be tracked so the lifecycle is observable.
  ///
  /// `private(set)` so test code can read (drain) the array but only
  /// the store can append to it.
  private(set) var pendingMutationTasks: [Task<Void, Never>] = []

  /// Called when a cloud profile is removed (locally or via remote sync).
  /// Used by SessionManager to tear down the corresponding ProfileSession.
  var onProfileRemoved: ((UUID) -> Void)?

  // internal (was private) so the `+Cloud` extension can reach the injected
  // dependencies and logger.
  let defaults: UserDefaults
  let containerManager: ProfileContainerManager?
  private let syncCoordinator: SyncCoordinator?
  let logger = Logger(subsystem: "com.moolah.app", category: "ProfileStore")

  /// Pass-through to ``SyncCoordinator/iCloudAvailability``. `.unknown`
  /// when no coordinator was injected (tests, previews). View code (e.g.
  /// `WelcomeView`) reads this rather than reaching into the sync layer.
  var iCloudAvailability: ICloudAvailability {
    syncCoordinator?.iCloudAvailability ?? .unknown
  }

  var activeProfile: Profile? {
    profiles.first { $0.id == activeProfileID }
  }

  var hasProfiles: Bool {
    !profiles.isEmpty
  }

  init(
    defaults: UserDefaults = .moolahShared,
    containerManager: ProfileContainerManager? = nil,
    syncCoordinator: SyncCoordinator? = nil
  ) {
    self.defaults = defaults
    self.containerManager = containerManager
    self.syncCoordinator = syncCoordinator
    loadFromDefaults()
    if let containerManager {
      // Synchronous initial population so the first scene tick already
      // sees the on-disk profiles. Required so `ProfileWindowView`
      // resolves to a profile (not `WelcomeView`) on launch — under
      // `--ui-testing` the hydrator writes the seed profile to GRDB
      // before this init runs, and the UI test interacts with the
      // window immediately. Empty profile-index (e.g. fresh install
      // before the SwiftData migrator runs) falls through to the async
      // load + retry, which fills the list once the migrator commits.
      do {
        let initial = try containerManager.profileIndexRepository.fetchAllSync()
        if !initial.isEmpty {
          profiles = initial
        }
      } catch {
        logger.error(
          "Initial sync profile-index read failed: \(error, privacy: .public)")
      }
      loadCloudProfiles(isInitialLoad: true)
      scheduleRetryIfNeeded()
    } else {
      // No CloudKit — nothing pending
      isCloudLoadPending = false
    }
  }

  deinit {
    // Cancel every in-flight fire-and-forget mutation and the retry
    // task so GRDB writes don't outlive the store. Swift 6 makes
    // `deinit` `nonisolated`, so reading `@MainActor`-isolated state
    // requires `MainActor.assumeIsolated` — the deinit is invoked
    // from a main-actor reference release in practice (the store is
    // owned by main-actor code), so the assumption holds.
    MainActor.assumeIsolated {
      for task in pendingMutationTasks { task.cancel() }
      retryTask?.cancel()
    }
  }

  /// Tracks a fire-and-forget mutation Task. The task self-evicts from
  /// `pendingMutationTasks` on completion so the array doesn't grow
  /// unbounded over a long session.
  func trackMutation(_ task: Task<Void, Never>) {
    pendingMutationTasks.append(task)
    // The bookkeeping Task is intentionally untracked: its only side
    // effect is cleaning up the array, which becomes a no-op when
    // `self` has already deallocated (the `[weak self]` capture goes
    // nil and the array is gone). Tracking it would create infinite
    // self-recursion through `trackMutation`.
    Task { [weak self] in
      _ = await task.value
      self?.pendingMutationTasks.removeAll { $0 == task }
    }
  }

  func addProfile(_ profile: Profile) {
    guard let containerManager else {
      logger.error("Cannot add CloudKit profile without ProfileContainerManager")
      return
    }
    // Snapshot prior state so the GRDB-write Task can roll back the
    // optimistic in-memory mutation if the upsert throws.
    let previousActiveID = activeProfileID
    profiles.append(profile)
    let isFirstProfile = profiles.count == 1
    let task = Task { [weak self] in
      do {
        try await containerManager.profileIndexRepository.upsert(profile)
      } catch {
        // Roll back the optimistic mutation: drop the appended profile
        // and restore the previous active id so in-memory state matches
        // what GRDB now contains. The Task body runs on @MainActor
        // because the store is @MainActor-isolated, so direct mutation
        // is safe.
        self?.profiles.removeAll { $0.id == profile.id }
        if isFirstProfile, self?.activeProfileID == profile.id {
          self?.activeProfileID = previousActiveID
          self?.saveActiveProfileID()
        }
        self?.logger.error("Failed to save CloudKit profile: \(error, privacy: .public)")
      }
    }
    trackMutation(task)

    if isFirstProfile {
      activeProfileID = profile.id
      saveActiveProfileID()
    }
    logger.debug("Added profile: \(profile.label) (\(profile.id))")
  }

  /// Adds a profile and does not return until its profile-index row is
  /// durable. Import uses this path so post-import sync cannot construct a
  /// per-profile handler before metadata such as `defaultTaxOwnerId` exists.
  func addProfilePersisting(_ profile: Profile) async throws {
    guard let containerManager else {
      logger.error("Cannot add CloudKit profile without ProfileContainerManager")
      return
    }
    let previousActiveID = activeProfileID
    profiles.append(profile)
    let isFirstProfile = profiles.count == 1
    if isFirstProfile {
      activeProfileID = profile.id
      saveActiveProfileID()
    }

    do {
      try await containerManager.profileIndexRepository.upsert(profile)
      logger.debug("Added and persisted profile: \(profile.label) (\(profile.id))")
    } catch {
      profiles.removeAll { $0.id == profile.id }
      if isFirstProfile, activeProfileID == profile.id {
        activeProfileID = previousActiveID
        saveActiveProfileID()
      }
      throw error
    }
  }

  func removeProfile(_ id: UUID) {
    guard let index = profiles.firstIndex(where: { $0.id == id }) else {
      logger.debug("Removed profile: \(id) — not present")
      return
    }
    // Snapshot prior state so the Task can roll back on GRDB failure.
    let previousProfile = profiles[index]
    let previousIndex = index
    let previousActiveID = activeProfileID
    profiles.remove(at: index)
    let activeChanged = activeProfileID == id
    if activeChanged {
      activeProfileID = profiles.first?.id
      saveActiveProfileID()
    }

    if let containerManager {
      // Evict the in-memory GRDB-queue cache immediately so synchronous
      // observers (e.g. `ExportCoordinator`'s import rollback path)
      // see a consistent view. The on-disk teardown stays inside the
      // Task and is gated on the GRDB index-row delete succeeding.
      containerManager.evictCachedStore(for: id)
      // Delete order matters. The GRDB profile-index row is deleted
      // FIRST: a remote sync that observes only the index row delete
      // can re-create the per-profile files on the next pull, so the
      // user's per-profile data is unaffected by an interrupted
      // delete. The reverse ordering (delete files first, then
      // index) would leave a tombstone-resurrect window — if the
      // GRDB delete failed after the files were gone, the index row
      // would survive and resurrect a profile whose data has been
      // wiped on disk. Per-profile file deletion happens only after
      // the index delete succeeds.
      let task = Task { [weak self] in
        do {
          _ = try await containerManager.profileIndexRepository.delete(id: id)
          // Index row is gone on disk — now wipe per-profile files
          // (GRDB queue, sync state, CloudKit zone).
          containerManager.deleteStore(for: id)
        } catch {
          // Roll back: re-insert the profile at its original position
          // and restore the active id. The per-profile files were not
          // touched, so no file-system rollback is needed. The cache
          // entries we evicted above are recoverable lazily — the next
          // `database(for:)` call will repopulate them.
          if let self {
            let insertIndex = min(previousIndex, self.profiles.count)
            self.profiles.insert(previousProfile, at: insertIndex)
            if activeChanged {
              self.activeProfileID = previousActiveID
              self.saveActiveProfileID()
            }
            self.logger.error(
              "Failed to delete CloudKit profile row: \(error, privacy: .public)")
          }
        }
      }
      trackMutation(task)
    } else {
      // No container manager (test/preview path). Optimistic in-memory
      // removal stands; nothing to roll back.
    }
    onProfileRemoved?(id)
    logger.debug("Removed profile: \(id)")
  }

  /// Removes a profile only after its profile-index deletion commits. Import
  /// rollback uses this path so an asynchronous profile reload cannot
  /// resurrect metadata between an in-memory removal and the durable delete.
  func removeProfilePersisting(_ id: UUID) async throws {
    guard profiles.contains(where: { $0.id == id }) else { return }
    if let containerManager {
      _ = try await containerManager.profileIndexRepository.delete(id: id)
      containerManager.evictCachedStore(for: id)
      containerManager.deleteStore(for: id)
    }
    profiles.removeAll { $0.id == id }
    if activeProfileID == id {
      activeProfileID = profiles.first?.id
      saveActiveProfileID()
    }
    onProfileRemoved?(id)
    logger.debug("Removed and persisted profile deletion: \(id)")
  }

  func setActiveProfile(_ id: UUID) {
    guard profiles.contains(where: { $0.id == id }) else { return }
    activeProfileID = id
    saveActiveProfileID()
    logger.debug("Switched to profile: \(id)")
  }

  func updateProfile(_ profile: Profile) {
    guard let containerManager else { return }
    guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
    // Snapshot the prior profile so the GRDB-write Task can restore it
    // on failure. Capturing by value is enough because `Profile` is a
    // value type.
    let previousProfile = profiles[index]
    profiles[index] = profile

    let task = Task { [weak self] in
      do {
        try await containerManager.profileIndexRepository.upsert(profile)
      } catch {
        // Roll back: restore the previous profile by id (the index may
        // have shifted if other mutations interleaved, so look it up
        // again rather than using the captured `index`).
        if let currentIndex = self?.profiles.firstIndex(where: { $0.id == profile.id }) {
          self?.profiles[currentIndex] = previousProfile
        }
        self?.logger.error(
          "Failed to save CloudKit profile update: \(error, privacy: .public)")
      }
    }
    trackMutation(task)
    logger.debug("Updated profile: \(profile.label)")
  }

  @discardableResult
  func updateProfilePersisting(
    id: UUID,
    applying update: (inout Profile) -> Void
  ) async throws -> Profile? {
    guard let containerManager else {
      guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
      update(&profiles[index])
      return profiles[index]
    }

    while true {
      guard let index = profiles.firstIndex(where: { $0.id == id }) else { return nil }
      let base = profiles[index]
      var updated = base
      update(&updated)
      guard updated != base else { return base }

      try await containerManager.profileIndexRepository.upsert(updated)
      guard let currentIndex = profiles.firstIndex(where: { $0.id == id }) else { return nil }
      guard profiles[currentIndex] != base else {
        profiles[currentIndex] = updated
        logger.debug("Updated profile: \(updated.label)")
        return updated
      }
    }
  }

  // MARK: - Validated mutations

  /// Validates iCloud availability then adds the profile. Returns true on success.
  func validateAndAddProfile(_ profile: Profile) async -> Bool {
    guard await validateiCloudAvailability() else { return false }
    addProfile(profile)
    return true
  }

  func clearValidationError() {
    validationError = nil
  }

}

extension ProfileStore {
  /// Creates a no-backend `ProfileStore` suitable for `#Preview` blocks
  /// (and any other preview-host without a real CloudKit / GRDB stack).
  /// Pass `profiles` to seed the list — empty by default; pass a single
  /// fixture to exercise the single-profile branch of
  /// `profileNavigationTitle`; pass two or more to exercise the
  /// multi-profile branch (which appends the profile label to the title).
  ///
  /// `defaults`, `containerManager`, and `syncCoordinator` are all `nil`
  /// — no persistence, no CloudKit. The store is read-only for the
  /// duration of the preview.
  static func preview(profiles: [Profile] = []) -> ProfileStore {
    let store = ProfileStore()
    if !profiles.isEmpty {
      store.profiles = profiles
      store.activeProfileID = profiles.first?.id
    }
    return store
  }
}
