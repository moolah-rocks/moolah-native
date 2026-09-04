import Foundation
import OSLog

/// Scans a folder for new / changed CSV files and feeds them into
/// `ImportStore.ingest(source: .folderWatch)`. Used on both platforms:
/// - iOS: at launch and scene-foreground (no live watch).
/// - macOS: for the catch-up scan on app launch, before `FolderWatchService`
///   takes over for live changes.
///
/// Tracks the last-seen modification date per profile in UserDefaults so
/// subsequent scans only ingest files newer than the cursor.
@MainActor
final class FolderScanService {

  private let defaults: UserDefaults
  private let importStore: ImportStore
  private let preferences: ImportPreferences
  private let profileId: UUID
  private let fileManager: FileManager
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "FolderScanService")

  init(
    profileId: UUID,
    importStore: ImportStore,
    preferences: ImportPreferences,
    defaults: UserDefaults = .moolahShared,
    fileManager: FileManager = .default
  ) {
    self.profileId = profileId
    self.importStore = importStore
    self.preferences = preferences
    self.defaults = defaults
    self.fileManager = fileManager
  }

  /// Scan the watched folder (if configured) and ingest every `.csv` file
  /// whose modification date is newer than the last-seen cursor. Updates
  /// the cursor at the end.
  func scanForNewFiles() async {
    guard let resolved = preferences.resolveWatchedFolder() else { return }
    defer {
      if resolved.startedAccess {
        resolved.url.stopAccessingSecurityScopedResource()
      }
    }
    let folder = resolved.url
    let lastSeen = lastSeenDate()
    let urls: [URL]
    do {
      urls = try fileManager.contentsOfDirectory(
        at: folder,
        includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
        options: [.skipsHiddenFiles])
    } catch {
      let folderPath = folder.path
      let errDesc = error.localizedDescription
      logger.error(
        "Failed to list \(folderPath, privacy: .public): \(errDesc, privacy: .public)"
      )
      return
    }

    var newestSeen = lastSeen
    for url in urls where url.pathExtension.lowercased() == "csv" {
      guard let candidate = importCandidate(at: url) else { continue }
      let modified = candidate.modified
      if modified <= lastSeen { continue }
      // Read the security-scoped bookmark from preferences rather than
      // re-bookmarking each file; the parent folder's scope covers this.
      let bookmark = preferences.watchedFolderBookmark
      let result = await importStore.ingest(
        data: candidate.data,
        source: .folderWatch(url: url, bookmark: bookmark))
      if case .cancelled = result { return }
      if modified > newestSeen { newestSeen = modified }
    }

    if newestSeen > lastSeen {
      setLastSeenDate(newestSeen)
    }
  }

  private func importCandidate(at url: URL) -> (modified: Date, data: Data)? {
    let values: URLResourceValues
    do {
      values = try url.resourceValues(forKeys: [
        .contentModificationDateKey, .isRegularFileKey,
      ])
    } catch {
      logger.error(
        "Could not read metadata for \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
    guard values.isRegularFile == true, let modified = values.contentModificationDate else {
      return nil
    }
    do {
      return (modified, try Data(contentsOf: url))
    } catch {
      logger.error(
        "Could not read \(url.path, privacy: .public): \(error.localizedDescription, privacy: .public)"
      )
      return nil
    }
  }

  // MARK: - Cursor

  private var cursorKey: String { "csvImport.folderScan.lastSeen.\(profileId.uuidString)" }

  private func lastSeenDate() -> Date {
    let interval = defaults.double(forKey: cursorKey)
    if interval > 0 { return Date(timeIntervalSince1970: interval) }
    return .distantPast
  }

  private func setLastSeenDate(_ date: Date) {
    defaults.set(date.timeIntervalSince1970, forKey: cursorKey)
  }
}
