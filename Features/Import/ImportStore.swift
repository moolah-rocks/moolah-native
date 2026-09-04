import Foundation
import ImportExtensionKit
import OSLog
import Observation
import os

/// The top-level CSV import orchestrator. One instance per profile.
///
/// `ingest(data:source:)` walks the full pipeline:
///   bytes → tokenize → parser select → parse → profile match
///        → dedup → rule evaluation → persist → update profile + recent
///
/// Failure anywhere before persistence routes the bytes into the staging
/// store (pending for "needs user attention", failed for "can't parse").
/// Persistence is atomic for the full session: if one row cannot be written,
/// none of that session's transactions are committed.
@Observable
@MainActor
final class ImportStore {

  private(set) var isImporting: Bool = false
  private(set) var pendingSetup: [PendingSetupFile] = []
  private(set) var failedFiles: [FailedImportFile] = []
  /// Session summaries for the Recently Added view, newest first.
  private(set) var recentSessions: [ImportSessionSummary] = []
  /// Count of recently-imported, non-spam transactions needing a category.
  /// Drives the sidebar badge on Recently Added. Refreshed at app launch
  /// and after every successful ingest.
  private(set) var unreviewedBadgeCount: Int = 0
  private(set) var lastError: String?
  private var badgeRefreshGeneration = 0
  private var stagingReloadGeneration = 0
  // Package-internal for the queue implementation in `ImportStore+Queue.swift`.
  var importQueueGeneration = 0
  var importQueueTail: Task<Void, Never>?

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
  /// `failedFiles` as a side effect. Never throws: recoverable failures land
  /// in the staging store, while caller cancellation returns `.cancelled`.
  @discardableResult
  func ingest(data: Data, source: ImportSource) async -> ImportSessionResult {
    await enqueueImport {
      await self.performIngest(data: data, source: source)
    }
  }

  func performIngest(data: Data, source: ImportSource) async -> ImportSessionResult {
    guard !Task.isCancelled else { return .cancelled }
    isImporting = true
    defer { isImporting = false }
    lastError = nil
    let sessionId = UUID()
    do {
      let result = try await runPipeline(data: data, source: source, sessionId: sessionId)
      await applyPipelineResult(result, sessionId: sessionId, source: source)
      return result
    } catch let error as IngestError {
      guard !Task.isCancelled else { return .cancelled }
      logger.error("\(error.diagnosticDescription, privacy: .private)")
      _ = await stageFailed(error: error, source: source, data: data)
      lastError = error.message
      await reloadStagingLists()
      return .failed(message: error.message)
    } catch {
      guard !Task.isCancelled else { return .cancelled }
      let ingest = IngestError.other(error.localizedDescription)
      _ = await stageFailed(error: ingest, source: source, data: data)
      logger.error("Import failed: \(error.localizedDescription, privacy: .public)")
      lastError = ingest.message
      await reloadStagingLists()
      return .failed(message: ingest.message)
    }
  }

  /// Shared post-pipeline machinery used by both `ingest(data:source:)`
  /// and `startWebReview(payload:)`. Records a session summary, refreshes
  /// the sidebar badge, runs cross-account transfer detection over the
  /// fresh batch, and reloads staging lists if the pipeline routed the
  /// run into Needs Setup.
  ///
  /// Detection runs inside the `isImporting == true` window deliberately:
  /// the import queue does not start the next ingest until this complete
  /// pipeline (including transfer detection) has finished.
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
  /// recoverable failure lands in the staging store. Cancellation returns
  /// `.cancelled`; an unencodable payload returns `.retryLater` so its inbox
  /// entry remains available for a later attempt.
  @discardableResult
  func startWebReview(payload: ImportPayload) async -> ImportSessionResult {
    await enqueueImport {
      await self.performWebReview(payload: payload)
    }
  }

  private func performWebReview(payload: ImportPayload) async -> ImportSessionResult {
    guard !Task.isCancelled else { return .cancelled }
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
      guard !Task.isCancelled else { return .cancelled }
      logger.error("\(error.diagnosticDescription, privacy: .private)")
      guard let data = recoverablePayloadStagingBytes(payload) else {
        lastError = error.message
        return .retryLater(message: error.message)
      }
      _ = await stageFailed(error: error, source: source, data: data)
      lastError = error.message
      await reloadStagingLists()
      return .failed(message: error.message)
    } catch {
      guard !Task.isCancelled else { return .cancelled }
      let ingest = IngestError.other(error.localizedDescription)
      guard let data = recoverablePayloadStagingBytes(payload) else {
        lastError = ingest.message
        return .retryLater(message: ingest.message)
      }
      _ = await stageFailed(error: ingest, source: source, data: data)
      logger.error("Web import failed: \(error.localizedDescription, privacy: .public)")
      lastError = ingest.message
      await reloadStagingLists()
      return .failed(message: ingest.message)
    }
  }

  /// Refresh the sidebar badge count: transactions imported in the last
  /// 24 hours with uncategorised income/expense legs, excluding transactions
  /// composed entirely of spam instruments. Call at app launch, on
  /// scene-foreground, and after each successful ingest.
  func refreshBadge(now: Date = Date()) async {
    badgeRefreshGeneration &+= 1
    let refreshGeneration = badgeRefreshGeneration
    do {
      let registrations = try await backend.instrumentRegistry?.allCryptoRegistrations() ?? []
      let spamInstruments = Set(
        registrations.lazy
          .filter { $0.pricingStatus == .spam }
          .map(\.instrument))
      let windowStart = now.addingTimeInterval(-86_400)
      let transactions = try await backend.transactions.fetchAll(
        filter: TransactionFilter(importedAtRange: windowStart...now))
      guard refreshGeneration == badgeRefreshGeneration else { return }
      unreviewedBadgeCount = transactions.count {
        $0.needsReview(excluding: spamInstruments)
      }
    } catch {
      logger.error(
        "refreshBadge failed: \(error.localizedDescription, privacy: .public)")
    }
  }

  /// Re-fetch pending + failed from staging. Call on view appear.
  func reloadStagingLists() async {
    stagingReloadGeneration &+= 1
    let reloadGeneration = stagingReloadGeneration
    do {
      let snapshot = try await staging.stagedFiles()
      guard reloadGeneration == stagingReloadGeneration, !Task.isCancelled else { return }
      pendingSetup = snapshot.pending
      failedFiles = snapshot.failed
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

}
