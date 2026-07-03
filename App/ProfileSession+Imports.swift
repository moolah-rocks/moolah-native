import Foundation
import OSLog

extension ProfileSession {
  // MARK: - Import Pipeline

  /// Bundle of the full CSV import pipeline: the `ImportStore`, the import-rule
  /// store, and the three folder-watch pieces. Returned from `makeImportPipeline`
  /// so `ProfileSession.init` can assign all five fields in one step.
  struct ImportPipeline {
    let importStore: ImportStore
    let importRuleStore: ImportRuleStore
    let preferences: ImportPreferences
    let scanner: FolderScanService
    let watcher: FolderWatchService
  }

  /// Builds the complete CSV import pipeline for a profile: staging store,
  /// import rules, folder watch, and wires the delete-after-import default
  /// closure into `ImportStore` before returning.
  static func makeImportPipeline(
    backend: BackendProvider,
    profileId: UUID,
    logger: Logger
  ) -> ImportPipeline {
    let stagingDirectory = ProfileSession.importStagingDirectory(for: profileId)
    let importStore = Self.makeImportStore(
      backend: backend,
      stagingDirectory: stagingDirectory,
      profileId: profileId,
      logger: logger
    )
    let importRuleStore = ImportRuleStore(
      repository: backend.importRules,
      instrumentChanges: backend.instrumentChangeObserver)
    let folderWatch = Self.makeFolderWatch(
      stagingDirectory: stagingDirectory,
      profileId: profileId,
      importStore: importStore
    )
    importStore.folderWatchDeleteAfterImport = { [preferences = folderWatch.preferences] in
      preferences.deleteAfterImportFolderDefault
    }
    return ImportPipeline(
      importStore: importStore,
      importRuleStore: importRuleStore,
      preferences: folderWatch.preferences,
      scanner: folderWatch.scanner,
      watcher: folderWatch.watcher
    )
  }

  // MARK: - Folder Watch Services

  /// Bundle of the services that make up folder-watch ingestion for a
  /// profile: the on-disk `ImportPreferences`, the catch-up `FolderScanService`,
  /// and the live `FolderWatchService`. Returned from `makeFolderWatch` so
  /// `ProfileSession.init` can assign each field in one step.
  struct FolderWatchServices {
    let preferences: ImportPreferences
    let scanner: FolderScanService
    let watcher: FolderWatchService
  }

  /// Builds the folder-watch bundle for a profile. `stagingDirectory` is the
  /// per-profile CSV staging directory; preferences live in its parent so
  /// they survive staging-store recreation.
  static func makeFolderWatch(
    stagingDirectory: URL,
    profileId: UUID,
    importStore: ImportStore
  ) -> FolderWatchServices {
    let preferencesDirectory = stagingDirectory.deletingLastPathComponent()
    let preferences = ImportPreferences(directory: preferencesDirectory)
    let scanner = FolderScanService(
      profileId: profileId,
      importStore: importStore,
      preferences: preferences)
    let watcher = FolderWatchService(
      importStore: importStore,
      preferences: preferences,
      scanner: scanner)
    return FolderWatchServices(preferences: preferences, scanner: scanner, watcher: watcher)
  }

  /// Opens the per-profile CSV import staging store. Falls back to a scratch
  /// directory in the tmp dir (which cannot fail in practice on Apple
  /// platforms) if the real directory can't be opened, so the pipeline
  /// remains functional in the degraded mode.
  ///
  /// The tmp-dir fallback is itself fallible; if it raises (unwritable system
  /// tmp directory or sandbox denial that also denies the fallback), the
  /// failure is logged at fault level and the app crashes — there is no
  /// further degradation path that keeps the user's data safe.
  static func makeImportStore(
    backend: BackendProvider,
    stagingDirectory: URL,
    profileId: UUID,
    logger: Logger
  ) -> ImportStore {
    let transferDetection = TransferDetectionCoordinator(
      transactions: backend.transactions,
      suggestions: backend.transferSuggestions)
    do {
      let staging = try ImportStagingStore(directory: stagingDirectory)
      return ImportStore(
        backend: backend, staging: staging, transferDetection: transferDetection)
    } catch {
      let fallback = FileManager.default.temporaryDirectory
        .appendingPathComponent("csv-staging-fallback-\(profileId.uuidString)")
      let stagingPath = stagingDirectory.path
      logger.error(
        "Failed to open CSV import staging at \(stagingPath, privacy: .public): \(error.localizedDescription, privacy: .public). Falling back to tmp."
      )
      guard let staging = try? ImportStagingStore(directory: fallback) else {
        logger.fault(
          "Failed to open CSV import staging fallback at \(fallback.path, privacy: .public). Profile \(profileId, privacy: .public)."
        )
        fatalError(
          "ImportStagingStore failed to open at both primary and tmp fallback paths.")
      }
      return ImportStore(
        backend: backend, staging: staging, transferDetection: transferDetection)
    }
  }
}
