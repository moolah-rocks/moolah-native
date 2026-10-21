import Foundation
import OSLog

/// Owns the mapping from `Profile.ID` to `ProfileSession`.
/// Multiple macOS windows share session instances through this manager.
/// Injected via `.environment(sessionManager)` at the app level.
@Observable
@MainActor
final class SessionManager {
  /// Live sessions keyed by profile id.
  ///
  /// **Mutation invariant:** any code path that drops a session
  /// **must** go through `removeSession(for:)` so the session's
  /// `cleanupSync(coordinator:)` runs first. `cleanupSync` is the
  /// only place that cancels the session's tracked tasks
  /// (`catalogRefreshTask`, `pragmaOptimizeTask`,
  /// `periodicPragmaOptimizeTask`, `setUpTask`); a direct mutation to
  /// `sessions` would leak any of those that happen to be in flight.
  /// Adding new tracked tasks to `ProfileSession`? Cancel them in
  /// `cleanupSync` and uphold this rule for any new mutation site.
  private(set) var sessions: [UUID: ProfileSession] = [:]
  /// Internal mutation is restricted to session ownership helpers in sibling extensions.
  var readSessionOwners: [UUID: Set<UUID>] = [:]
  var readReadyProfiles: Set<UUID> = []
  var windowSessionProfiles: [UUID: UUID] = [:]
  var legacySessionProfiles: Set<UUID> = []

  /// Profiles whose `dataFormatVersion` exceeds `DataFormatVersion.current`
  /// — either the gate refused to open them or a remote bump arrived
  /// mid-session and `removeSession` evicted the session. Routing
  /// observes this dictionary to flip into `IncompatibleProfileView`.
  ///
  /// Cleared on a successful `.ready` open for the same profile id, so
  /// after an app update the entry doesn't linger.
  private(set) var incompatibleProfiles: [UUID: IncompatibleProfileInfo] = [:]

  /// Token returned by `SyncCoordinator.addIndexObserver` when
  /// `installIndexObserver` registers the mid-session bump-arrival
  /// observer. `nil` until installed (and re-`nil`ed on
  /// `removeIndexObserver`); the install guard relies on this to be
  /// idempotent on this `SessionManager` instance.
  private var indexObserverToken: UUID?

  /// In-flight reconcile task spawned by the index-observer callback.
  /// Cancel-and-replace on each firing: if two observer batches arrive
  /// in rapid succession, the prior reconcile is cancelled before the
  /// next one starts so the two don't race writes to
  /// `incompatibleProfiles` / `sessions`. Makes the `Task.isCancelled`
  /// guard inside `reconcileIncompatibilityFromIndex` genuinely
  /// reachable.
  private var reconcileTask: Task<Void, Never>?

  private let resources: ProfileSessionResources
  let containerManager: ProfileContainerManager
  let syncCoordinator: SyncCoordinator?
  let profileIndexRepository: any ProfileIndexRepository

  private let logger = Logger(subsystem: "com.moolah.app", category: "SessionManager")

  init(
    resources: ProfileSessionResources = .live,
    containerManager: ProfileContainerManager,
    profileIndexRepository: any ProfileIndexRepository,
    syncCoordinator: SyncCoordinator? = nil
  ) {
    self.resources = resources
    self.containerManager = containerManager
    self.profileIndexRepository = profileIndexRepository
    self.syncCoordinator = syncCoordinator
  }

  /// Opens a session for the given profile, gated on data-format
  /// compatibility (issue #764).
  ///
  /// Re-reads the profile-index row before the gate check so a stale
  /// in-memory `Profile` snapshot can't bypass an incompatibility that
  /// was just delivered over sync.
  func session(
    for profile: Profile,
    windowOwner: UUID? = nil
  ) async -> SessionOpenResult {
    // Legacy callers receive cached ownership only after a successful open. A temporary
    // owner keeps shared setup alive while awaiting, and is always released on cancellation.
    let openOwner = windowOwner ?? UUID()
    registerWindowSession(profileID: profile.id, owner: openOwner)
    defer {
      if windowOwner == nil { releaseWindowSession(owner: openOwner) }
    }
    guard openIsCurrent(profileID: profile.id, windowOwner: openOwner) else { return .cancelled }
    let live = await freshProfile(fallingBackTo: profile)
    guard openIsCurrent(profileID: profile.id, windowOwner: openOwner) else { return .cancelled }
    if live.dataFormatVersion > DataFormatVersion.current {
      return makeIncompatible(for: live)
    }
    let session = sessions[live.id] ?? makeSession(for: live)
    let setUpSucceeded = await runSetUp(on: session)
    guard
      openIsCurrent(
        profileID: live.id,
        windowOwner: openOwner),
      sessions[live.id] === session
    else {
      cleanUpUnownedSession(profileID: live.id)
      return .cancelled
    }
    if setUpSucceeded {
      await bumpDataFormatVersionIfNeeded(profile: live, session: session)
    }
    guard
      openIsCurrent(
        profileID: live.id,
        windowOwner: openOwner),
      sessions[live.id] === session
    else {
      cleanUpUnownedSession(profileID: live.id)
      return .cancelled
    }
    if windowOwner == nil { legacySessionProfiles.insert(live.id) }
    return .ready(session)
  }

  private func openIsCurrent(
    profileID: UUID,
    windowOwner: UUID?
  ) -> Bool {
    guard !Task.isCancelled else {
      cleanUpUnownedSession(profileID: profileID)
      return false
    }
    return windowOwner.map { windowSessionProfiles[$0] == profileID } ?? true
  }

  /// Re-reads the profile-index row so the gate sees the latest
  /// `dataFormatVersion`. Falls back to the caller's snapshot on read
  /// failure — better to open optimistically than to refuse outright on
  /// a transient repository error.
  private func freshProfile(fallingBackTo snapshot: Profile) async -> Profile {
    do {
      return try await profileIndexRepository.profile(forID: snapshot.id) ?? snapshot
    } catch {
      logger.error(
        "session(for:) repository re-read failed: \(error, privacy: .public) — using in-memory snapshot"
      )
      return snapshot
    }
  }

  private func makeIncompatible(for profile: Profile) -> SessionOpenResult {
    let info = IncompatibleProfileInfo(
      profileLabel: profile.label,
      profileVersion: profile.dataFormatVersion,
      buildVersion: DataFormatVersion.current)
    incompatibleProfiles[profile.id] = info
    return .incompatible(info)
  }

  private func makeSession(for profile: Profile) -> ProfileSession {
    let session: ProfileSession
    do {
      session = try ProfileSession(
        resources: resources,
        profile: profile,
        containerManager: containerManager,
        syncCoordinator: syncCoordinator)
    } catch {
      fatalError("Failed to open profile database for \(profile.id): \(error)")
    }
    sessions[profile.id] = session
    incompatibleProfiles.removeValue(forKey: profile.id)
    return session
  }

  /// Runs `setUp()` on the session. Returns `true` when bump-on-write
  /// can safely fire, `false` when setup was cancelled (teardown path)
  /// or threw — in which case the caller still returns `.ready` so a
  /// transient migration failure doesn't strand the user, but the next
  /// open will retry the bump.
  private func runSetUp(on session: ProfileSession) async -> Bool {
    do {
      try await session.setUp()
      return true
    } catch is CancellationError {
      return false
    } catch {
      logger.error(
        "session(for:) setUp failed: \(error, privacy: .public) — bump-on-write skipped"
      )
      return false
    }
  }

  private func bumpDataFormatVersionIfNeeded(
    profile: Profile,
    session: ProfileSession
  ) async {
    guard profile.dataFormatVersion < DataFormatVersion.current else { return }
    do {
      var bumped = profile
      bumped.dataFormatVersion = DataFormatVersion.current
      try await profileIndexRepository.upsert(bumped)
      session.updateProfile(bumped)
    } catch {
      logger.error(
        "session(for:) bump-on-write failed: \(error, privacy: .public) — will retry on next open"
      )
    }
  }

  /// Removes the session for a profile (e.g. when profile is deleted)
  /// or evicted under a mid-session bump.
  ///
  /// `cleanupSync` runs whether or not a coordinator is wired (Preview /
  /// some test fixtures construct `SessionManager` without one);
  /// `cleanupSync(coordinator:)` itself accepts an optional and
  /// guards the coordinator-only work internally. Without this split,
  /// no-coordinator builds would leak the session's tracked tasks
  /// (`setUpTask`, etc.) past teardown.
  func removeSession(for profileID: UUID) {
    readSessionOwners.removeValue(forKey: profileID)
    readReadyProfiles.remove(profileID)
    legacySessionProfiles.remove(profileID)
    windowSessionProfiles = windowSessionProfiles.filter { $0.value != profileID }
    incompatibleProfiles.removeValue(forKey: profileID)
    guard let session = sessions.removeValue(forKey: profileID) else { return }
    session.cleanupSync(coordinator: syncCoordinator)
    syncCoordinator?.removeDataHandler(for: profileID)
  }

  /// Service creation propagates database-open failures instead of taking the UI's fatal path.
  func makeReadSession(for profile: Profile) throws -> ProfileSession {
    do {
      let session = try ProfileSession(
        resources: resources,
        profile: profile,
        containerManager: containerManager,
        syncCoordinator: syncCoordinator)
      sessions[profile.id] = session
      incompatibleProfiles.removeValue(forKey: profile.id)
      return session
    } catch {
      throw ReadQueryError.profileUnavailable
    }
  }

  func recordReadIncompatibility(_ profile: Profile) {
    _ = makeIncompatible(for: profile)
  }

  /// Live eviction state takes precedence over a root's previously resolved result.
  func displayedOpenResult(
    profileID: UUID,
    cached: SessionOpenResult?
  ) -> SessionOpenResult? {
    if let info = incompatibleProfiles[profileID] { return .incompatible(info) }
    if case .ready(let session) = cached, sessions[profileID] !== session { return nil }
    return cached
  }

  // MARK: - Automation Lookup

  /// Find an open session by profile name (case-insensitive).
  func session(named name: String) -> ProfileSession? {
    let lowered = name.lowercased()
    return sessions.values.first { $0.profile.label.lowercased() == lowered }
  }

  /// Find an open session by profile UUID.
  func session(forID id: UUID) -> ProfileSession? {
    sessions[id]
  }

  /// All currently open profile sessions.
  var openProfiles: [ProfileSession] {
    Array(sessions.values)
  }

  /// Propagates a profile-metadata edit (label, currency code,
  /// financial-year start) into the live session **in place** — no
  /// teardown, no data reload, no sync restart. This is the path a
  /// rename takes: `ProfileSession.profile` is `@Observable`, so the
  /// window title and any label-bound UI update reactively off the
  /// single assignment. Mirrors the bump-on-write in-place update
  /// (`bumpDataFormatVersionIfNeeded`).
  ///
  /// No-op when no session is open for the profile — the next
  /// `session(for:)` reads the fresh value from the profile index.
  /// A remote `dataFormatVersion` bump that would make the profile
  /// incompatible is handled independently by the index observer
  /// (`installIndexObserver` / `reconcileIncompatibilityFromIndex`),
  /// so a metadata edit must not trigger `rebuildSession`.
  func refreshProfile(_ profile: Profile) {
    sessions[profile.id]?.updateProfile(profile)
  }

  // MARK: - Mid-session compatibility reconcile

  /// Installs a `SyncCoordinator` index observer that, on every
  /// profile-index batch, evicts any session whose `dataFormatVersion`
  /// has been raised above `DataFormatVersion.current` and records an
  /// `IncompatibleProfileInfo` in `incompatibleProfiles`.
  ///
  /// Idempotent on this `SessionManager` instance: subsequent calls are
  /// no-ops once the observer is installed. Pair with
  /// `removeIndexObserver()` if you need to drop the registration
  /// (tests, teardown).
  func installIndexObserver() {
    guard let syncCoordinator, indexObserverToken == nil else { return }
    indexObserverToken = syncCoordinator.addIndexObserver { [weak self] in
      // Bridge sync callback to async reconcile. weak self prevents the
      // observer from extending the SessionManager's lifetime.
      self?.reconcileTask?.cancel()
      self?.reconcileTask = Task {
        await self?.reconcileIncompatibilityFromIndex()
      }
    }
  }

  /// Drops the index-observer registration. Use from `deinit` or
  /// teardown helpers; production has a single long-lived
  /// `SessionManager` so this is mostly for test isolation.
  func removeIndexObserver() {
    if let token = indexObserverToken, let syncCoordinator {
      syncCoordinator.removeIndexObserver(token)
    }
    indexObserverToken = nil
    reconcileTask?.cancel()
    reconcileTask = nil
  }

  /// Walks the profile-index repository and applies the gate to any
  /// profile that is now incompatible — evicting a live session if one
  /// is open, and recording an `IncompatibleProfileInfo` either way.
  /// The eviction order (`cleanupSync` then `evictCachedState`) is
  /// safe under `@MainActor`: both calls are synchronous, so no other
  /// `@MainActor` work interleaves between them, and the
  /// `SyncCoordinator` delegate runs on the same actor.
  private func reconcileIncompatibilityFromIndex() async {
    let profiles: [Profile]
    do {
      profiles = try await profileIndexRepository.fetchAll()
    } catch {
      logger.error(
        "reconcileIncompatibilityFromIndex: fetchAll failed: \(error, privacy: .public)")
      return
    }
    // Bail if a newer reconcile / a session tear-down ran during the
    // suspension above — using the (now-stale) snapshot to mutate
    // `sessions` / `incompatibleProfiles` would re-evict a freshly
    // opened session or overwrite fresher state with old data.
    guard !Task.isCancelled else { return }
    for profile in profiles where profile.dataFormatVersion > DataFormatVersion.current {
      let info = IncompatibleProfileInfo(
        profileLabel: profile.label,
        profileVersion: profile.dataFormatVersion,
        buildVersion: DataFormatVersion.current)
      if sessions[profile.id] != nil {
        removeSession(for: profile.id)
        // Drop cached repositories as well as the live handler so sync cannot reopen it.
        syncCoordinator?.evictCachedState(for: profile.id)
      }
      incompatibleProfiles[profile.id] = info
    }
  }

  #if DEBUG
    /// Test-only: drive `reconcileIncompatibilityFromIndex` directly,
    /// bypassing the observer callback path. Lets tests assert
    /// reconciliation outcomes without polling on `Task.yield()`.
    func reconcileIncompatibilityFromIndexForTesting() async {
      await reconcileIncompatibilityFromIndex()
    }

    /// Test-only: seed an incompatible entry so the eviction-on-`.ready`
    /// path can be verified without first triggering the observer.
    func setIncompatibleProfileForTesting(id: UUID, info: IncompatibleProfileInfo) {
      incompatibleProfiles[id] = info
    }

    /// Test-only: the in-flight reconcile task, if any. Tests `await`
    /// its `value` after firing `notifyIndexObservers()` to deterministically
    /// wait for the reconcile to complete.
    var reconcileTaskForTesting: Task<Void, Never>? { reconcileTask }
  #endif
}
