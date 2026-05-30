import Foundation
import ImportExtensionKit
import OSLog
import Observation
import os

/// Result of a single `ingest` call. `ImportStore.recentSessions` carries
/// the last few for the Recently Added view.
enum ImportSessionResult: Sendable {
  case imported(sessionId: UUID, imported: [Transaction], skippedAsDuplicate: Int)
  case needsSetup(pendingId: UUID)
  case failed(message: String)
}

/// Summary of a recent import session for the UI.
struct ImportSessionSummary: Sendable, Identifiable, Hashable {
  var id: UUID
  var importedCount: Int
  var skippedAsDuplicate: Int
  var importedAt: Date
  var filename: String?
}

/// Errors that can abort a pipeline run before reaching the persist stage.
/// All land in the Failed Files panel; nothing bubbles to the user.
enum IngestError: Error, Sendable {
  case decode(String)
  case parse(CSVParserError)
  case empty
  case other(String)

  var message: String {
    switch self {
    case .decode(let detail): return "Could not decode file: \(detail)"
    case .parse(let error):
      switch error {
      case .headerMismatch: return "Headers did not match any known parser"
      case let .malformedRow(index, reason, _):
        return "Malformed row \(index): \(reason)"
      case .emptyFile: return "File was empty"
      }
    case .empty: return "File had no rows"
    case .other(let detail): return detail
    }
  }

  /// Which row the underlying parser error pointed at, if any. An empty
  /// `row` with a `nil` `index` means "no row info was captured"
  /// (e.g. an `.empty` / `.decode` / `.other` error, or a parser error
  /// other than `.malformedRow`).
  var offendingRow: (row: [String], index: Int?) {
    if case let .parse(parserError) = self,
      case let .malformedRow(index, _, row) = parserError
    {
      return (row, index)
    }
    return ([], nil)
  }
}

/// The top-level CSV import orchestrator. One instance per profile.
///
/// `ingest(data:source:)` walks the full pipeline:
///   bytes → tokenize → parser select → parse → profile match
///        → dedup → rule evaluation → persist → update profile + recent
///
/// Failure anywhere before persistence routes the bytes into the staging
/// store (pending for "needs user attention", failed for "can't parse").
/// Per-row persistence failures are logged and the rest continue (spec:
/// no batch rollback).
@Observable
@MainActor
final class ImportStore {

  private(set) var isImporting: Bool = false
  private(set) var pendingSetup: [PendingSetupFile] = []
  private(set) var failedFiles: [FailedImportFile] = []
  /// Session summaries for the Recently Added view, newest first.
  private(set) var recentSessions: [ImportSessionSummary] = []
  /// Count of recently-imported transactions with no category assigned.
  /// Drives the sidebar badge on Recently Added. Refreshed at app launch
  /// and after every successful ingest.
  private(set) var unreviewedBadgeCount: Int = 0
  private(set) var lastError: String?

  // Package-internal: the pipeline / resolution / transactions extension
  // files reach the injected dependencies and logger.
  let backend: any BackendProvider
  let registry: CSVParserRegistry
  /// Exposed so the Needs Setup sheet can re-read staged bytes via its own
  /// `CSVImportSetupStore`. Mutations still flow through the `ImportStore`
  /// public API; external callers should only read.
  let staging: ImportStagingStore
  /// Optional resolver for the folder-watch "delete after import" default.
  /// `ProfileSession` wires this to `ImportPreferences.deleteAfterImportFolderDefault`
  /// so `.folderWatch` ingests honour the setting even when the matched
  /// profile's own `deleteAfterImport` is false.
  var folderWatchDeleteAfterImport: (@MainActor () -> Bool)?
  /// Runs the fuzzy cross-account transfer scan over each imported batch.
  /// Non-optional: every construction site builds a real coordinator from
  /// the same backend so detection always runs after an import.
  let transferDetection: TransferDetectionCoordinator
  let logger = Logger(subsystem: "com.moolah.app", category: "ImportStore")

  init(
    backend: any BackendProvider,
    staging: ImportStagingStore,
    transferDetection: TransferDetectionCoordinator,
    registry: CSVParserRegistry = .default
  ) {
    self.backend = backend
    self.registry = registry
    self.staging = staging
    self.transferDetection = transferDetection
  }

  // MARK: - Public API

  /// Ingest one file. Updates `recentSessions`, `pendingSetup`, and
  /// `failedFiles` as a side effect. Never throws: every failure path lands
  /// in the staging store.
  @discardableResult
  func ingest(data: Data, source: ImportSource) async -> ImportSessionResult {
    isImporting = true
    defer { isImporting = false }
    lastError = nil
    let sessionId = UUID()
    do {
      let result = try await runPipeline(data: data, source: source, sessionId: sessionId)
      await applyPipelineResult(result, sessionId: sessionId, source: source)
      return result
    } catch let error as IngestError {
      let pendingId = await stageFailed(error: error, source: source, data: data)
      lastError = error.message
      await reloadStagingLists()
      return .failed(message: error.message + " (staged as \(pendingId))")
    } catch {
      let ingest = IngestError.other(error.localizedDescription)
      let pendingId = await stageFailed(error: ingest, source: source, data: data)
      lastError = error.localizedDescription
      await reloadStagingLists()
      return .failed(message: error.localizedDescription + " (staged as \(pendingId))")
    }
  }

  /// Shared post-pipeline machinery used by both `ingest(data:source:)`
  /// and `startWebReview(payload:)`. Records a session summary, refreshes
  /// the sidebar badge, runs cross-account transfer detection over the
  /// fresh batch, and reloads staging lists if the pipeline routed the
  /// run into Needs Setup.
  ///
  /// Detection runs inside the `isImporting == true` window deliberately:
  /// a concurrent second ingest is rejected by the `isImporting` guard,
  /// so the persisted set here is the only batch in flight.
  private func applyPipelineResult(
    _ result: ImportSessionResult, sessionId: UUID, source: ImportSource
  ) async {
    if case let .imported(_, imported, skipped) = result {
      recentSessions.insert(
        ImportSessionSummary(
          id: sessionId,
          importedCount: imported.count,
          skippedAsDuplicate: skipped,
          importedAt: Date(),
          filename: source.filename),
        at: 0)
      await refreshBadge()
      if let earliest = imported.min(by: { $0.date < $1.date }) {
        let windowLowerBound = earliest.date
          .addingTimeInterval(-FuzzyTransferDetector.windowSeconds)
        await transferDetection.runDetection(
          newlyImported: imported,
          participatingAccountIds: Set(
            imported.compactMap { $0.transferDetectionValueLeg?.accountId }),
          windowLowerBound: windowLowerBound)
      }
    }
    if case .needsSetup = result {
      await reloadStagingLists()
    }
  }

  /// Drain an `ImportPayload` (from the Safari web-import extension)
  /// through the same review pipeline `ingest(data:source:)` uses. The
  /// payload's rows are translated into the existing `ParsedTransaction`
  /// shape and routed through profile matching, dedup, rules, and
  /// persistence with no review-state duplication; the only thing
  /// distinguishing a web import from a CSV import inside the pipeline is
  /// the `ImportSource.web(host:accountHint:)` tag. Never throws: every
  /// failure path lands in the staging store.
  @discardableResult
  func startWebReview(payload: ImportPayload) async -> ImportSessionResult {
    isImporting = true
    defer { isImporting = false }
    lastError = nil
    let sessionId = UUID()
    let source = ImportSource.web(
      host: payload.sourceHost, accountHint: payload.accountHint)
    do {
      let result = try await runWebPipeline(
        payload: payload, source: source, sessionId: sessionId)
      await applyPipelineResult(result, sessionId: sessionId, source: source)
      return result
    } catch let error as IngestError {
      let data = (try? Self.payloadStagingBytes(payload)) ?? Data()
      let pendingId = await stageFailed(error: error, source: source, data: data)
      lastError = error.message
      await reloadStagingLists()
      return .failed(message: error.message + " (staged as \(pendingId))")
    } catch {
      let ingest = IngestError.other(error.localizedDescription)
      let data = (try? Self.payloadStagingBytes(payload)) ?? Data()
      let pendingId = await stageFailed(error: ingest, source: source, data: data)
      lastError = error.localizedDescription
      await reloadStagingLists()
      return .failed(message: error.localizedDescription + " (staged as \(pendingId))")
    }
  }

  /// Refresh the sidebar badge count (transactions imported in the last
  /// 24 hours whose legs are all uncategorised). Call at app launch, on
  /// scene-foreground, and after each successful ingest.
  func refreshBadge(now: Date = Date()) async {
    do {
      let page = try await backend.transactions.fetch(
        filter: TransactionFilter(), page: 0, pageSize: 500)
      let windowStart = now.addingTimeInterval(-86_400)
      unreviewedBadgeCount =
        page.transactions.filter { transaction in
          guard let origin = transaction.importOrigin?.singleOrigin else { return false }
          guard origin.importedAt >= windowStart && origin.importedAt <= now else {
            return false
          }
          return transaction.needsReview
        }.count
    } catch {
      logger.error(
        "refreshBadge failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Re-fetch pending + failed from staging. Call on view appear.
  func reloadStagingLists() async {
    do {
      pendingSetup = try await staging.pendingFiles()
      failedFiles = try await staging.failedFiles()
    } catch {
      logger.error("Staging reload failed: \(error.localizedDescription)")
    }
  }

  /// Merge a detected transfer pair through the detection coordinator,
  /// then refresh the staging lists. Symmetric with the detail surface's
  /// `TransactionStore` dispatch — unit-testable against `TestBackend`.
  func mergeTransfer(_ transaction: Transaction, counterpart: Transaction) async {
    await transferDetection.merge(transaction, counterpart)
    await reloadStagingLists()
  }

  /// Dismiss a detected transfer pair through the detection coordinator,
  /// then refresh the staging lists. Symmetric with the detail surface's
  /// `TransactionStore` dispatch — unit-testable against `TestBackend`.
  func dismissTransfer(_ transaction: Transaction, counterpart: Transaction) async {
    await transferDetection.dismiss(transaction, counterpart)
    await reloadStagingLists()
  }

  func dismissPending(id: UUID) async {
    do {
      try await staging.dismiss(pendingId: id)
      await reloadStagingLists()
    } catch {
      logger.error("Dismiss pending failed: \(error.localizedDescription)")
    }
  }

  func dismissFailed(id: UUID) async {
    do {
      try await staging.dismiss(failedId: id)
      await reloadStagingLists()
    } catch {
      logger.error("Dismiss failed failed: \(error.localizedDescription)")
    }
  }

  /// Retry a failed file: re-read the staged bytes, drop the failed
  /// record, and send the bytes back through `ingest`. Works for any
  /// file we staged (picker, drop, paste, folder-watch) because we use
  /// the on-disk copy, not the original URL.
  @discardableResult
  func retryFailed(id: UUID) async -> ImportSessionResult {
    do {
      guard let record = try await staging.failedFiles().first(where: { $0.id == id })
      else {
        return .failed(message: "Failed file not found")
      }
      let bytes = try await staging.data(forFailedId: id)
      try await staging.dismiss(failedId: id)
      await reloadStagingLists()
      return await ingest(
        data: bytes,
        source: .reingestFromSetup(
          filename: record.originalFilename, sourceURL: nil))
    } catch {
      logger.error("retryFailed failed: \(error.localizedDescription)")
      return .failed(message: error.localizedDescription)
    }
  }

  /// Complete a Needs Setup file: caller supplies the profile that will be
  /// created/attached. The bytes are re-read from staging and the pipeline
  /// runs end-to-end with the profile pre-matched.
  @discardableResult
  func finishSetup(pendingId: UUID, profile: CSVImportProfile) async -> ImportSessionResult {
    do {
      let pendingRecord = try await staging.pendingFiles().first {
        $0.id == pendingId
      }
      let originalFilename = pendingRecord?.originalFilename ?? "setup-\(pendingId.uuidString)"
      // Resolve the source bookmark (if any) so delete-after-import still
      // works on the file the user picked.
      let bookmark = pendingRecord?.sourceBookmark
      let sourceURL: URL? = {
        guard let bookmark else { return nil }
        var isStale = false
        #if os(macOS)
          let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
        #else
          let options: URL.BookmarkResolutionOptions = []
        #endif
        do {
          return try URL(
            resolvingBookmarkData: bookmark,
            options: options,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale)
        } catch {
          logger.error(
            "bookmark resolution failed: \(error.localizedDescription)")
          return nil
        }
      }()
      let bytes = try await staging.data(for: pendingId)
      _ = try await backend.csvImportProfiles.create(profile)
      try await staging.dismiss(pendingId: pendingId)
      await reloadStagingLists()
      return await ingest(
        data: bytes,
        source: .reingestFromSetup(
          filename: originalFilename, sourceURL: sourceURL))
    } catch {
      logger.error("finishSetup failed: \(error.localizedDescription)")
      return .failed(message: error.localizedDescription)
    }
  }

}
