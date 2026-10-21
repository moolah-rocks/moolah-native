import Foundation
import GRDB

// Filesystem layout helpers and the `DatabaseQueue` opener for a
// profile session. Every helper here is `nonisolated static` and
// reaches none of the session's private state.

extension ProfileSession {
  /// Per-profile directory under Application Support where CSV import staging
  /// lives. Not part of the SwiftData store because staging is device-local
  /// and doesn't sync.
  nonisolated static func importStagingDirectory(for profileId: UUID) -> URL {
    URL.moolahScopedApplicationSupport
      .appendingPathComponent("Moolah", isDirectory: true)
      .appendingPathComponent("csv-staging", isDirectory: true)
      .appendingPathComponent(profileId.uuidString, isDirectory: true)
  }

  /// Per-profile directory containing `data.sqlite` (and its `-wal`/`-shm`
  /// sidecars). Removed wholesale on profile delete by
  /// `ProfileContainerManager.deleteStore(for:)`.
  nonisolated static func profileDatabaseDirectory(for profileId: UUID) -> URL {
    URL.moolahScopedApplicationSupport
      .appendingPathComponent("Moolah", isDirectory: true)
      .appendingPathComponent("profiles", isDirectory: true)
      .appendingPathComponent(profileId.uuidString, isDirectory: true)
  }

  /// Opens the profile's `data.sqlite` GRDB queue, creating intermediate
  /// directories as needed and applying the `ProfileSchema` migrator.
  nonisolated static func openProfileDatabase(profileId: UUID) throws -> DatabaseQueue {
    let url = profileDatabaseDirectory(for: profileId)
      .appendingPathComponent("data.sqlite")
    return try ProfileDatabase.open(at: url)
  }

  /// Resolves which `DatabaseQueue` the session should own. Order:
  ///   1. Caller-provided `override` (tests, previews).
  ///   2. The container manager's cached per-profile queue. Required so
  ///      the import path and the session see the same in-memory queue
  ///      (each `ProfileDatabase.openInMemory()` call returns a fresh
  ///      queue otherwise) and so on-disk profiles don't run the
  ///      migrator twice on the same file.
  ///   3. Fallback: open the on-disk `data.sqlite` directly. Used by
  ///      callers that pass `containerManager: nil` (a few legacy test
  ///      paths).
  static func resolveDatabase(
    override: DatabaseQueue?,
    profile: Profile,
    containerManager: ProfileContainerManager?
  ) throws -> DatabaseQueue {
    if let override { return override }
    if let containerManager {
      return try containerManager.database(for: profile.id)
    }
    return try openProfileDatabase(profileId: profile.id)
  }

  /// Convenience constructor for `#Preview` blocks. Backs the session with
  /// an in-memory GRDB queue so previews never touch disk. Uses an in-memory
  /// `ProfileContainerManager` so the CloudKit backend can be constructed
  /// without touching the network or the on-disk container store.
  static func preview(
    profile: Profile = Profile(label: "Preview")
  ) throws -> ProfileSession {
    try ProfileSession(
      resources: .disconnected,
      profile: profile,
      containerManager: ProfileContainerManager.forTesting(),
      database: ProfileDatabase.openInMemory())
  }
}
