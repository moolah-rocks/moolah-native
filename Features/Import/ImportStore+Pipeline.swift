import Foundation
import OSLog
import os

// Pipeline-stage helpers (tokenize, parser selection, parse, dedup, persist)
// for `ImportStore`. Every helper is file-scoped to the store and only
// mutates shared state via the public staging/backend accessors.
extension ImportStore {

  // MARK: - Pipeline

  func runPipeline(
    data: Data, source: ImportSource, sessionId: UUID
  ) async throws -> ImportSessionResult {
    let pipelineSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin, log: Signposts.importPipeline, name: "ingest", signpostID: pipelineSignpost)
    defer {
      os_signpost(
        .end, log: Signposts.importPipeline, name: "ingest", signpostID: pipelineSignpost)
    }

    // 1. Decode + tokenize.
    let rows = try tokenize(data)
    guard let headers = rows.first else { throw IngestError.empty }

    // 2. Select parser + candidates.
    let parsing = try await selectAndParse(rows: rows, headers: headers, source: source)
    let candidates = parsing.candidates
    if candidates.isEmpty {
      // Every row skipped (summary-only fixture, empty file) — treat as a
      // successful no-op rather than failing.
      return .imported(sessionId: sessionId, imported: [], skippedAsDuplicate: 0)
    }

    // 3. Profile match (or forced-account override).
    let profile = try await resolveProfile(
      data: data,
      source: source,
      parserIdentifier: parsing.parser.identifier,
      headers: headers,
      candidates: candidates)
    let resolvedProfile: CSVImportProfile
    switch profile {
    case .routed(let routedProfile):
      resolvedProfile = routedProfile
    case .needsSetup(let pendingId):
      return .needsSetup(pendingId: pendingId)
    }

    // 4. Dedup + 5. Rules + persist.
    let dedup = try await runDedup(candidates: candidates, accountId: resolvedProfile.accountId)
    let persisted = try await persistCandidates(
      dedup: dedup,
      resolvedProfile: resolvedProfile,
      sessionId: sessionId,
      source: source,
      parserIdentifier: parsing.parser.identifier)

    // 6. Update profile lastUsedAt (best-effort — log on failure rather
    // than silently swallow so a backend hiccup isn't invisible).
    await touchProfileLastUsedAt(resolvedProfile)

    // 7. Optional delete source. Honour either the profile-level flag or
    // (for folder-watched files) the folder-level default.
    let folderDefaultDelete: Bool = {
      if case .folderWatch = source {
        return folderWatchDeleteAfterImport?() ?? false
      }
      return false
    }()
    if resolvedProfile.deleteAfterImport || folderDefaultDelete,
      let url = source.sourceURL
    {
      await Self.deleteSourceInBackground(at: url)
    }

    return .imported(
      sessionId: sessionId,
      imported: persisted,
      skippedAsDuplicate: dedup.skipped.count)
  }

  func tokenize(_ data: Data) throws -> [[String]] {
    let tokenizeSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin,
      log: Signposts.importPipeline,
      name: "tokenize",
      signpostID: tokenizeSignpost)
    defer {
      os_signpost(
        .end,
        log: Signposts.importPipeline,
        name: "tokenize",
        signpostID: tokenizeSignpost)
    }
    do {
      return try CSVTokenizer.parse(data)
    } catch {
      throw IngestError.decode(error.localizedDescription)
    }
  }

  struct ParseOutcome {
    let parser: any CSVParser
    let candidates: [ParsedTransaction]
  }

  /// Selects a parser via `registry.select` + pre-existing profile lookup
  /// (so saved `dateFormatRawValue` and column-role overrides are threaded
  /// into the parser), runs the parse, and projects parsed records down to
  /// transaction candidates.
  func selectAndParse(
    rows: [[String]], headers: [String], source: ImportSource
  ) async throws -> ParseOutcome {
    let parser = registry.select(for: headers)
    let profileForOverride = try? await preExistingProfile(
      parserIdentifier: parser.identifier,
      headers: headers,
      forcedAccountId: source.forcedAccountId)
    let dateFormatOverride = profileForOverride?.dateFormatRawValue
      .flatMap(GenericBankCSVParser.DateFormat.fromRawValue)

    // Column-role override: if the profile stored a user-edited column
    // mapping, rebuild the ColumnMapping from it and pass as an explicit
    // `overrideMapping` so the parser doesn't re-auto-detect. Without
    // this, the user's first-time setup choice would be ignored on every
    // subsequent import with the same header signature. An empty
    // `columnRoleRawValues` means "no override"; skip rebuilding.
    let columnMappingOverride: GenericBankCSVParser.ColumnMapping? = {
      guard let rawValues = profileForOverride?.columnRoleRawValues, !rawValues.isEmpty else {
        return nil
      }
      return Self.buildColumnMapping(
        headers: headers,
        columnRoleRawValues: rawValues,
        sampleRows: Array(rows.dropFirst().prefix(5)),
        dateFormatOverride: dateFormatOverride)
    }()

    let records = try runParse(
      parser: parser,
      rows: rows,
      columnMappingOverride: columnMappingOverride,
      dateFormatOverride: dateFormatOverride)
    let candidates = records.compactMap { record -> ParsedTransaction? in
      if case .transaction(let transaction) = record {
        return transaction
      } else {
        return nil
      }
    }
    return ParseOutcome(parser: parser, candidates: candidates)
  }

  func runParse(
    parser: any CSVParser,
    rows: [[String]],
    columnMappingOverride: GenericBankCSVParser.ColumnMapping?,
    dateFormatOverride: GenericBankCSVParser.DateFormat?
  ) throws -> [ParsedRecord] {
    let parseSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin, log: Signposts.importPipeline, name: "parse", signpostID: parseSignpost)
    defer {
      os_signpost(
        .end, log: Signposts.importPipeline, name: "parse", signpostID: parseSignpost)
    }
    do {
      if let genericParser = parser as? GenericBankCSVParser {
        if let mapping = columnMappingOverride {
          return try genericParser.parse(rows: rows, overrideMapping: mapping)
        }
        return try genericParser.parse(rows: rows, overrideDateFormat: dateFormatOverride)
      }
      return try parser.parse(rows: rows)
    } catch let error as CSVParserError {
      throw IngestError.parse(error)
    }
  }

  func runDedup(
    candidates: [ParsedTransaction], accountId: UUID
  ) async throws -> CSVDedupResult {
    let dedupSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin, log: Signposts.importPipeline, name: "dedup", signpostID: dedupSignpost)
    defer {
      os_signpost(
        .end, log: Signposts.importPipeline, name: "dedup", signpostID: dedupSignpost)
    }
    let existingPage = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId),
      page: 0,
      pageSize: 1000)
    return CSVDeduplicator.filter(
      candidates,
      against: existingPage.transactions,
      accountId: accountId)
  }

  /// Evaluate import rules against each surviving candidate and persist
  /// the resulting transactions in a single atomic write. Fetches every
  /// account once and builds a `{ id → instrument }` map so
  /// `buildTransaction` can stamp each leg with its own account's
  /// instrument — in particular the destination leg of a
  /// `.markAsTransfer` rule, which may target an account in a different
  /// instrument than the source (Rule 11a — never write a leg with the
  /// wrong instrument).
  ///
  /// On any backend failure during the bulk insert, **no** transactions
  /// from this session persist. A half-imported CSV is hard to reconcile
  /// against on a retry — the dedup window would have to be narrowed
  /// manually to skip the rows that did land. Failing the whole session
  /// instead keeps re-running the same file safe.
  func persistCandidates(
    dedup: CSVDedupResult,
    resolvedProfile: CSVImportProfile,
    sessionId: UUID,
    source: ImportSource,
    parserIdentifier: String
  ) async throws -> [Transaction] {
    let rulesSignpost = OSSignpostID(log: Signposts.importPipeline)
    os_signpost(
      .begin, log: Signposts.importPipeline, name: "rules", signpostID: rulesSignpost)
    defer {
      os_signpost(
        .end, log: Signposts.importPipeline, name: "rules", signpostID: rulesSignpost)
    }
    let rules = try await backend.importRules.fetchAll()
    let allAccounts = try await backend.accounts.fetchAll()
    let accountInstruments: [UUID: Instrument] = Dictionary(
      uniqueKeysWithValues: allAccounts.map { ($0.id, $0.instrument) })
    guard let routedInstrument = accountInstruments[resolvedProfile.accountId] else {
      throw IngestError.other(
        "Account \(resolvedProfile.accountId) not found; cannot resolve its instrument.")
    }

    let buildContext = ImportBuildContext(
      routedAccountId: resolvedProfile.accountId,
      accountInstrument: routedInstrument,
      accountInstruments: accountInstruments,
      sessionId: sessionId,
      source: source,
      parserIdentifier: parserIdentifier)
    let transactions: [Transaction] = dedup.kept.compactMap { candidate in
      let evaluation = ImportRulesEngine.evaluate(
        candidate, routedAccountId: resolvedProfile.accountId, rules: rules)
      if evaluation.isSkipped { return nil }
      return buildTransaction(from: evaluation, context: buildContext)
    }
    return try await backend.transactions.createMany(transactions)
  }

  func touchProfileLastUsedAt(_ resolvedProfile: CSVImportProfile) async {
    var updatedProfile = resolvedProfile
    updatedProfile.lastUsedAt = Date()
    do {
      _ = try await backend.csvImportProfiles.update(updatedProfile)
    } catch {
      logger.warning(
        "Profile lastUsedAt update failed (non-critical): \(error.localizedDescription, privacy: .public)"
      )
    }
  }
}
