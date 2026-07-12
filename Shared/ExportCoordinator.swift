@preconcurrency import CloudKit
import Foundation
import GRDB
import OSLog
import Observation

/// Coordinates exporting a profile to a JSON file and importing one back.
/// The coordinator is observable so the UI can reflect progress.
@Observable
@MainActor
final class ExportCoordinator {
  enum State: Sendable {
    case idle
    case exporting(step: String)
    case importing(step: String, progress: Double)
    case verifying
  }

  private(set) var state: State = .idle

  /// Record IDs queued with the sync coordinator by the most recent successful
  /// `importFromFile(...)` call. Empty if no sync coordinator was provided, the
  /// import failed, or the profile had no records to queue. Exposed for test
  /// verification.
  private(set) var lastRecordIDsQueuedForUpload: [CKRecord.ID] = []

  private let logger = Logger(subsystem: "com.moolah.app", category: "Export")

  /// Exports all data from a profile to a JSON file.
  ///
  /// - Parameters:
  ///   - url: The file URL to write the exported JSON to
  ///   - backend: The backend for the profile (provides repositories)
  ///   - profile: The profile to export
  ///   - progress: Optional callback fired on `@MainActor` with a stage name
  ///     (`accounts`, `account groups`, `categories`, `tax owners`,
  ///     `earmarks`, `transactions`, `investment values`, `encoding`,
  ///     `writing`) so the UI can render a progress indicator. The download
  ///     stages are forwarded from `DataExporter`; `encoding` and `writing`
  ///     are emitted around the JSON serialisation and atomic file write that
  ///     run inside this method.
  func exportToFile(
    url: URL,
    backend: any BackendProvider,
    profile: Profile,
    progress: @escaping @MainActor (String) -> Void = { _ in }
  ) async throws {
    state = .exporting(step: "Starting...")
    progress("starting")

    let exporter = DataExporter(backend: backend)
    let exported = try await exporter.export(
      profileLabel: profile.label,
      currencyCode: profile.currencyCode,
      financialYearStartMonth: profile.financialYearStartMonth,
      defaultTaxOwnerId: profile.defaultTaxOwnerId
    ) { [weak self] exportProgress in
      Task { @MainActor in
        switch exportProgress {
        case .downloading(let step):
          self?.state = .exporting(step: step)
          progress(step)
        default: break
        }
      }
    }

    state = .exporting(step: "encoding")
    progress("encoding")
    let data = try JSONEncoder.exportEncoder.encode(exported)

    state = .exporting(step: "writing")
    progress("writing")
    try data.write(to: url, options: .atomic)

    state = .idle
  }

  /// Imports data from a JSON file into the per-profile GRDB queue.
  ///
  /// - Parameters:
  ///   - url: The file URL to read the exported JSON from
  ///   - database: The target GRDB queue to import data into. The runtime
  ///     stores read exclusively from GRDB, so the import writes every
  ///     record type into `data.sqlite` for the imported profile to be
  ///     visible to its session.
  ///   - profileId: The UUID of the new profile that owns the stores. Required
  ///     when `syncCoordinator` is non-nil so imported records can be queued for upload.
  ///   - syncCoordinator: Optional sync coordinator. When provided, all imported records
  ///     are queued for upload so the profile syncs to CloudKit and other devices.
  ///   - instrumentRegistrar: The registry every non-fiat denomination is
  ///     registered into before the per-profile write — instrument
  ///     identity lives on the shared profile-index registry, not a
  ///     per-profile `instrument` table. Defaults to the coordinator's shared
  ///     registry; an explicit value lets coordinator-less callers
  ///     (some tests) supply a shared test registry.
  /// - Returns: The import result with counts of imported records
  func importFromFile(
    url: URL,
    database: any DatabaseWriter,
    profileId: UUID? = nil,
    syncCoordinator: SyncCoordinator? = nil,
    instrumentRegistrar: (any InstrumentRegistering)? = nil
  ) async throws -> ImportResult {
    state = .importing(step: "reading file", progress: 0)
    lastRecordIDsQueuedForUpload = []

    let jsonData: Data
    do {
      jsonData = try Data(contentsOf: url)
    } catch {
      throw ExportError.fileReadFailed(url, underlying: error)
    }

    let exported: ExportedData
    do {
      exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
    } catch {
      throw ExportError.importFailed(underlying: error)
    }

    return try await importFromData(
      exported,
      database: database,
      profileId: profileId,
      syncCoordinator: syncCoordinator,
      instrumentRegistrar: instrumentRegistrar ?? syncCoordinator?.sharedInstrumentRegistry
    )
  }

  /// Performs the post-decode import steps: version check, data insertion,
  /// verification, and optional sync-queue. Callers that already hold an
  /// `ExportedData` (e.g. `importNewProfileFromFile`) call this directly to
  /// avoid reading and decoding the file a second time.
  private func importFromData(
    _ exported: ExportedData,
    database: any DatabaseWriter,
    profileId: UUID?,
    syncCoordinator: SyncCoordinator?,
    instrumentRegistrar: (any InstrumentRegistering)?
  ) async throws -> ImportResult {
    guard exported.version <= 1 else {
      throw ExportError.unsupportedVersion(exported.version)
    }

    state = .importing(step: "saving", progress: 0.3)

    // Instrument identity lives on the shared profile-index registry,
    // not a per-profile `instrument` table. Production always has a
    // coordinator carrying the shared registry; the importer registers
    // every non-fiat denomination there before the per-profile write.
    let importer = CloudKitDataImporter(
      database: database,
      currencyCode: exported.currencyCode,
      instrumentRegistrar: instrumentRegistrar
    )

    let result: ImportResult
    do {
      result = try await importer.importData(exported)
    } catch {
      throw ExportError.importFailed(underlying: error)
    }

    state = .verifying
    let verifier = ImportVerifier()
    let verification: ImportVerificationResult = try await verifier.verify(
      exported: exported,
      database: database
    )

    if !verification.countMatch {
      state = .idle
      throw ExportError.verificationFailed
    }

    // Queue every imported record for upload so the new profile actually syncs to
    // CloudKit. Without this the container has data but CKSyncEngine never hears
    // about it — the profile would be iCloud-backed in name only.
    if let syncCoordinator, let profileId {
      let queued = await syncCoordinator.queueAllRecordsAfterImport(for: profileId)
      lastRecordIDsQueuedForUpload = queued
      if !queued.isEmpty {
        await syncCoordinator.sendChanges()
      }
    }

    state = .idle
    return result
  }

  /// Imports a profile-export JSON file as a new profile.
  ///
  /// Reads the file, constructs a fresh `Profile` from the embedded label,
  /// registers it via `profileStore`, runs the import, and rolls back
  /// (removes the profile, which also deletes the per-profile GRDB store)
  /// if the import throws. Returns the new profile's `id` on success.
  func importNewProfileFromFile(
    url: URL,
    profileStore: ProfileStore,
    containerManager: ProfileContainerManager,
    syncCoordinator: SyncCoordinator?,
    instrumentRegistrar: (any InstrumentRegistering)? = nil
  ) async throws -> UUID {
    state = .importing(step: "reading file", progress: 0)
    lastRecordIDsQueuedForUpload = []

    let jsonData: Data
    do {
      jsonData = try Data(contentsOf: url)
    } catch {
      throw ExportError.fileReadFailed(url, underlying: error)
    }

    let exported: ExportedData
    do {
      exported = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: jsonData)
    } catch {
      throw ExportError.importFailed(underlying: error)
    }

    let importedDefaultTaxOwnerId = exported.defaultTaxOwnerId.flatMap { ownerId in
      exported.taxOwners.contains { $0.id == ownerId } ? ownerId : nil
    }
    let newProfile = Profile(
      label: exported.profileLabel,
      currencyCode: exported.currencyCode,
      financialYearStartMonth: exported.financialYearStartMonth,
      defaultTaxOwnerId: importedDefaultTaxOwnerId
    )
    try await profileStore.addProfilePersisting(newProfile)

    do {
      let database = try containerManager.database(for: newProfile.id)
      _ = try await importFromData(
        exported,
        database: database,
        profileId: newProfile.id,
        syncCoordinator: syncCoordinator,
        instrumentRegistrar: instrumentRegistrar ?? syncCoordinator?.sharedInstrumentRegistry
      )
    } catch {
      let importError = error
      do {
        try await profileStore.removeProfilePersisting(newProfile.id)
      } catch {
        logger.error(
          "Failed to roll back imported profile \(newProfile.id): \(error, privacy: .public)")
      }
      throw importError
    }

    return newProfile.id
  }
}
