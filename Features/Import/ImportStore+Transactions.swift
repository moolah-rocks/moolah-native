import Foundation
import OSLog

// Transaction-construction and staging helpers for `ImportStore`.
// `importStoreBackgroundLogger` is defined on the main `ImportStore.swift`
// file; the delete helper references it via file-private visibility (same
// module, so `static private` + sibling extension still works through
// `deleteSourceInBackgroundTarget`).
extension ImportStore {

  // MARK: - Transaction construction

  /// Per-session fields that every candidate in an ingest run shares.
  /// Bundled into a struct so call sites don't repeat them once per
  /// candidate.
  struct ImportBuildContext {
    let routedAccountId: UUID
    let accountInstrument: Instrument
    let accountInstruments: [UUID: Instrument]
    let sessionId: UUID
    let source: ImportSource
    let parserIdentifier: String
  }

  func buildTransaction(
    from evaluation: RuleEvaluation,
    context: ImportBuildContext
  ) -> Transaction {
    var legs = evaluation.transaction.legs.map { leg in
      resolveParsedLeg(
        leg,
        routedAccountId: context.routedAccountId,
        accountInstrument: context.accountInstrument)
    }
    if let categoryId = evaluation.assignedCategoryId,
      let index = legs.firstIndex(where: { $0.type == .expense })
    {
      legs[index].categoryId = categoryId
    }
    if let toId = evaluation.transferTargetAccountId, let cash = legs.first {
      legs = makeTransferLegs(
        from: cash,
        fromAccountId: context.routedAccountId,
        toAccountId: toId,
        accountInstruments: context.accountInstruments)
    }

    let origin = ImportOrigin(
      rawDescription: evaluation.transaction.rawDescription,
      bankReference: evaluation.transaction.bankReference,
      rawAmount: evaluation.transaction.rawAmount,
      rawBalance: evaluation.transaction.rawBalance,
      importedAt: Date(),
      importSessionId: context.sessionId,
      sourceFilename: context.source.filename,
      parserIdentifier: context.parserIdentifier)
    return Transaction(
      date: evaluation.transaction.date,
      payee: evaluation.assignedPayee,
      notes: evaluation.appendedNotes,
      legs: legs,
      importOrigin: .single(origin))
  }

  /// Rewrite placeholder-instrument legs (cash legs from parsers) to the
  /// routed account's actual instrument. Explicit instrument legs (e.g.
  /// SelfWealth's `ASX:BHP.AX` position leg) are left alone. The flag is set
  /// by the parser at the leg's point-of-origin, replacing the earlier
  /// fragile "is it AUD?" heuristic.
  func resolveParsedLeg(
    _ leg: ParsedLeg, routedAccountId: UUID, accountInstrument: Instrument
  ) -> TransactionLeg {
    let resolvedAccount = leg.accountId ?? routedAccountId
    let resolvedInstrument =
      leg.isInstrumentPlaceholder ? accountInstrument : leg.instrument
    return TransactionLeg(
      accountId: resolvedAccount,
      instrument: resolvedInstrument,
      quantity: leg.quantity,
      type: leg.type,
      categoryId: nil,
      earmarkId: nil)
  }

  /// Build the pair of legs for a `.markAsTransfer` evaluation. Each side
  /// of a transfer carries ITS OWN account's instrument (Rule 11a). Falls
  /// back to the source leg's instrument if the destination account isn't
  /// in the lookup — that's a same-instrument transfer, which is the safe
  /// default when the map is incomplete.
  func makeTransferLegs(
    from cash: TransactionLeg,
    fromAccountId: UUID,
    toAccountId: UUID,
    accountInstruments: [UUID: Instrument]
  ) -> [TransactionLeg] {
    let destinationInstrument = accountInstruments[toAccountId] ?? cash.instrument
    return [
      TransactionLeg(
        accountId: fromAccountId,
        instrument: cash.instrument,
        quantity: -abs(cash.quantity),
        type: .transfer,
        categoryId: nil,
        earmarkId: nil),
      TransactionLeg(
        accountId: toAccountId,
        instrument: destinationInstrument,
        quantity: abs(cash.quantity),
        type: .transfer,
        categoryId: nil,
        earmarkId: nil),
    ]
  }

  // MARK: - Staging helpers

  func stagePending(
    data: Data,
    headers: [String],
    parserIdentifier: String,
    filename: String?
  ) async throws -> UUID {
    let id = UUID()
    let path = await staging.stagingPath(for: id)
    let file = PendingSetupFile(
      id: id,
      originalFilename: filename ?? "pasted.csv",
      stagingPath: path,
      securityScopedBookmark: nil,
      detectedParserIdentifier: parserIdentifier,
      detectedHeaders: headers.map { CSVImportProfile.normalise($0) },
      parsedAt: Date(),
      sourceBookmark: nil)
    try await staging.stagePending(file, data: data)
    return id
  }

  func stageFailed(
    error: IngestError, source: ImportSource, data: Data
  ) async -> UUID {
    let id = UUID()
    let path = await staging.stagingPath(for: id)
    let (row, index) = error.offendingRow
    let file = FailedImportFile(
      id: id,
      originalFilename: source.filename ?? "pasted.csv",
      stagingPath: path,
      error: error.message,
      offendingRow: row,
      offendingRowIndex: index,
      parsedAt: Date())
    do {
      try await staging.stageFailed(file, data: data)
    } catch {
      logger.error("Stage failed file failed: \(error.localizedDescription)")
    }
    return id
  }

  /// File delete runs off the main actor so the UI isn't blocked on a slow
  /// filesystem call — network-share volumes, security-scoped resource
  /// locks, and iCloud Drive materialisation can all push `removeItem` into
  /// the hundreds-of-ms range. As a `nonisolated` async function called via
  /// `await` from the main actor, Swift's concurrency runtime schedules
  /// the body on a cooperative pool thread automatically — no
  /// `Task.detached` needed.
  nonisolated static func deleteSourceInBackground(at url: URL) async {
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      let path = url.path
      let description = error.localizedDescription
      let logger = Logger(subsystem: "com.moolah.app", category: "ImportStore.Background")
      logger.warning(
        "Could not delete source file at \(path, privacy: .public): \(description, privacy: .public)"
      )
    }
  }
}
