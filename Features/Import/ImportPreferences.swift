import Foundation
import OSLog
import Observation

/// Per-profile CSV-import settings. Persisted as a small JSON file next to
/// the staging store. Not synced — security-scoped bookmarks are per-device.
struct ImportPreferencesRecord: Codable, Sendable, Equatable {
  /// Security-scoped bookmark to the user's watched folder. `nil` when folder
  /// watching is disabled.
  var watchedFolderBookmark: Data?
  /// The folder's display path at the time it was picked, for UI display
  /// only. The bookmark is authoritative.
  var watchedFolderDisplayPath: String?
  /// Delete CSVs after successful import (folder-watch only). Per-profile
  /// default; can be overridden per profile via `CSVImportProfile.deleteAfterImport`.
  var deleteAfterImportFolderDefault: Bool = false
}

/// `@Observable @MainActor` store for folder-watch preferences. Backs the
/// Settings → Import panel.
@Observable
@MainActor
final class ImportPreferences {

  private(set) var record = ImportPreferencesRecord()
  private let url: URL
  private let fileManager: FileManager
  private let logger = Logger(subsystem: "com.moolah.app", category: "ImportPreferences")

  init(directory: URL, fileManager: FileManager = .default) {
    self.url = directory.appendingPathComponent("import-preferences.json")
    self.fileManager = fileManager
    do {
      try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
    } catch {
      let dirPath = directory.path
      let errDesc = error.localizedDescription
      logger.error(
        "Could not create preferences directory at \(dirPath, privacy: .public): \(errDesc, privacy: .public)"
      )
    }
    load()
  }

  // MARK: - Public API

  var watchedFolderDisplayPath: String? {
    record.watchedFolderDisplayPath
  }

  var watchedFolderBookmark: Data? {
    record.watchedFolderBookmark
  }

  var deleteAfterImportFolderDefault: Bool {
    get { record.deleteAfterImportFolderDefault }
    set {
      record.deleteAfterImportFolderDefault = newValue
      save()
    }
  }

  /// Resolve the stored bookmark to a URL, starting security-scoped access.
  /// Caller is responsible for calling `stopAccessingSecurityScopedResource`
  /// when done.
  func resolveWatchedFolder() -> (url: URL, startedAccess: Bool)? {
    guard let bookmark = record.watchedFolderBookmark else { return nil }
    var isStale = false
    do {
      let url = try URL(
        resolvingBookmarkData: bookmark,
        options: Self.bookmarkOptions,
        relativeTo: nil,
        bookmarkDataIsStale: &isStale)
      if isStale {
        // Re-make the bookmark so subsequent resolves are fast.
        do {
          let refreshed = try url.bookmarkData(options: Self.bookmarkCreateOptions)
          record.watchedFolderBookmark = refreshed
          save()
        } catch {
          logger.warning(
            "Could not refresh watched-folder bookmark: \(error.localizedDescription, privacy: .public)"
          )
        }
      }
      let started = url.startAccessingSecurityScopedResource()
      return (url, started)
    } catch {
      logger.error(
        "Failed to resolve bookmark: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }

  /// Persist a new watched folder.
  func setWatchedFolder(_ url: URL) {
    do {
      let bookmark = try url.bookmarkData(options: Self.bookmarkCreateOptions)
      record.watchedFolderBookmark = bookmark
      record.watchedFolderDisplayPath = url.path
      save()
    } catch {
      let urlPath = url.path
      let errDesc = error.localizedDescription
      logger.error(
        "Failed to create bookmark for \(urlPath, privacy: .public): \(errDesc, privacy: .public)"
      )
    }
  }

  func clearWatchedFolder() {
    record.watchedFolderBookmark = nil
    record.watchedFolderDisplayPath = nil
    save()
  }

  // MARK: - Persistence

  private func load() {
    guard fileManager.fileExists(atPath: url.path) else { return }
    do {
      let data = try Data(contentsOf: url)
      record = try JSONDecoder().decode(ImportPreferencesRecord.self, from: data)
    } catch {
      logger.error(
        "Failed to load preferences: \(error.localizedDescription, privacy: .public)")
    }
  }

  private func save() {
    do {
      let data = try JSONEncoder().encode(record)
      try data.write(to: url, options: .atomic)
    } catch {
      logger.error(
        "Failed to save preferences: \(error.localizedDescription, privacy: .public)")
    }
  }

  // MARK: - Bookmark options

  private static var bookmarkCreateOptions: URL.BookmarkCreationOptions {
    #if os(macOS)
      return [.withSecurityScope]
    #else
      return []
    #endif
  }

  private static var bookmarkOptions: URL.BookmarkResolutionOptions {
    #if os(macOS)
      return [.withSecurityScope]
    #else
      return []
    #endif
  }
}
