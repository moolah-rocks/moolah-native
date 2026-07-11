#if os(macOS)
  import Foundation
  import GRDB
  import OSLog

  /// Daily backup of each profile's `data.sqlite` to a date-stamped
  /// snapshot using SQLite's `VACUUM INTO`. Mac-only (matches the
  /// platform that ships the backup UX).
  ///
  /// **`import GRDB` in `Shared/` is justified.** `DATABASE_CODE_GUIDE.md`
  /// scopes `import GRDB` to `Backends/GRDB/` (and implicitly `App/`),
  /// but `StoreBackupManager` is the canonical backup helper — peered
  /// with `TestBackend` / `PreviewBackend` as the third `Shared/` site
  /// that legitimately reaches for `DatabaseWriter`. The alternative
  /// (moving it under `Backends/GRDB/`) would force `App/MoolahApp.swift`
  /// to import the backend layer just to schedule a daily timer, which
  /// is a worse coupling than the targeted backup-only import here.
  @MainActor
  final class StoreBackupManager {
    private let backupDirectory: URL
    private let retentionDays: Int
    private let fileManager: FileManager
    private let logger = Logger(subsystem: "com.moolah.app", category: "Backup")

    private static let dateFormatter: DateFormatter = {
      let formatter = DateFormatter()
      formatter.dateFormat = "yyyy-MM-dd"
      return formatter
    }()

    init(
      backupDirectory: URL = URL.moolahScopedApplicationSupport
        .appending(path: "Moolah/Backups"),
      retentionDays: Int = 7,
      fileManager: FileManager = .default
    ) {
      self.backupDirectory = backupDirectory
      self.retentionDays = retentionDays
      self.fileManager = fileManager
    }

    /// Backs up a profile's GRDB database to a date-stamped `.sqlite`
    /// file if today's backup doesn't already exist.
    ///
    /// Uses SQLite's `VACUUM INTO`, which produces an atomic,
    /// defragmented single-file copy (no `-wal`/`-shm` sidecars). The
    /// statement runs through GRDB's writer queue, so it serialises
    /// with any concurrent CKSyncEngine writes — VACUUM INTO sees a
    /// consistent snapshot and pending writes simply queue behind it
    /// until the copy finishes.
    func backupStore(from sourceDb: any DatabaseWriter, profileId: UUID) async throws {
      guard !hasBackupForToday(profileId: profileId) else {
        logger.debug("Backup already exists for today, skipping \(profileId)")
        return
      }

      let profileDir = backupDirectory.appending(path: profileId.uuidString)
      try fileManager.createDirectory(at: profileDir, withIntermediateDirectories: true)

      let today = Self.dateFormatter.string(from: Date())
      let backupURL = profileDir.appending(path: "\(today).sqlite")

      // Justification: SQLite forbids VACUUM inside a transaction; this still
      // runs on GRDB's writer queue, so concurrent writes serialize around the
      // snapshot copy.
      try await sourceDb.writeWithoutTransaction { database in
        try database.execute(literal: "VACUUM INTO \(backupURL.path)")
      }
      logger.info("Backed up profile \(profileId) to \(backupURL.lastPathComponent)")
    }

    func hasBackupForToday(profileId: UUID) -> Bool {
      let profileDir = backupDirectory.appending(path: profileId.uuidString)
      let today = Self.dateFormatter.string(from: Date())
      let backupURL = profileDir.appending(path: "\(today).sqlite")
      return fileManager.fileExists(atPath: backupURL.path())
    }

    func pruneBackups(profileId: UUID) {
      let profileDir = backupDirectory.appending(path: profileId.uuidString)
      guard let files = try? fileManager.contentsOfDirectory(atPath: profileDir.path()) else {
        return
      }

      // VACUUM INTO produces a single `.sqlite` file with no
      // `-wal`/`-shm` sidecars, so retention only enumerates `.sqlite`.
      let backupFiles = files.filter { $0.hasSuffix(".sqlite") }
        .sorted().reversed()
      let toDelete = Array(backupFiles.dropFirst(retentionDays))
      for filename in toDelete {
        let fileURL = profileDir.appending(path: filename)
        try? fileManager.removeItem(at: fileURL)
        logger.debug("Pruned old backup: \(filename)")
      }
    }

    func performDailyBackup(
      profiles: [Profile], containerManager: ProfileContainerManager
    ) async {
      for profile in profiles {
        do {
          let database = try containerManager.database(for: profile.id)
          try await backupStore(from: database, profileId: profile.id)
          pruneBackups(profileId: profile.id)
        } catch {
          logger.error("Backup failed for profile \(profile.id): \(error.localizedDescription)")
        }
      }
    }

    /// Test-only accessor for the configured backup directory. Read-only.
    var testingBackupDirectory: URL { backupDirectory }
  }
#endif
