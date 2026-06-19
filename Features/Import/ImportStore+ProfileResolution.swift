import Foundation

// Profile-matching and column-mapping-rebuild helpers for `ImportStore`.
extension ImportStore {

  // MARK: - Profile resolution

  enum ProfileResolution {
    case routed(CSVImportProfile)
    case needsSetup(pendingId: UUID)
  }

  /// Cheap lookup used to pre-fetch a profile before parsing, so parser
  /// overrides like `dateFormatRawValue` can be threaded into the parse
  /// step. Returns nil when zero / multiple profiles match — the pipeline
  /// then falls back to auto-detect.
  func preExistingProfile(
    parserIdentifier: String,
    headers: [String],
    forcedAccountId: UUID?
  ) async throws -> CSVImportProfile? {
    let profiles = try await backend.csvImportProfiles.fetchAll()
    let normalisedHeaders = headers.map { CSVImportProfile.normalise($0) }
    if let forcedAccountId {
      return profiles.first(where: {
        $0.accountId == forcedAccountId
          && $0.parserIdentifier == parserIdentifier
          && $0.headerSignature == normalisedHeaders
      })
    }
    let matching = profiles.filter {
      $0.parserIdentifier == parserIdentifier
        && $0.headerSignature == normalisedHeaders
    }
    return matching.count == 1 ? matching[0] : nil
  }

  func resolveProfile(
    data: Data,
    source: ImportSource,
    parserIdentifier: String,
    headers: [String],
    candidates: [ParsedTransaction]
  ) async throws -> ProfileResolution {
    let profiles = try await backend.csvImportProfiles.fetchAll()
    let normalisedHeaders = headers.map { CSVImportProfile.normalise($0) }

    // Forced target via explicit drop: bypass matcher. Create or update a
    // profile on the fly if one doesn't exist.
    if let forcedId = source.forcedAccountId {
      if let match = profiles.first(where: {
        $0.accountId == forcedId && $0.parserIdentifier == parserIdentifier
          && $0.headerSignature == normalisedHeaders
      }) {
        return .routed(match)
      }
      let created = try await backend.csvImportProfiles.create(
        CSVImportProfile(
          accountId: forcedId,
          parserIdentifier: parserIdentifier,
          headerSignature: normalisedHeaders))
      return .routed(created)
    }

    // Build existingByAccountId map for each candidate profile.
    let candidateProfiles = profiles.filter {
      $0.parserIdentifier == parserIdentifier
        && $0.headerSignature == normalisedHeaders
    }
    var existingByAccount: [UUID: [Transaction]] = [:]
    for profile in candidateProfiles {
      let page = try await backend.transactions.fetch(
        filter: TransactionFilter(accountId: profile.accountId),
        page: 0,
        pageSize: 1000)
      existingByAccount[profile.accountId] = page.transactions
    }
    let matcherInput = MatcherInput(
      filename: source.filename,
      parserIdentifier: parserIdentifier,
      headerSignature: headers,
      candidates: candidates,
      existingByAccountId: existingByAccount,
      profiles: profiles)
    switch CSVImportProfileMatcher.match(matcherInput) {
    case .routed(let profile):
      return .routed(profile)
    case .needsSetup:
      let pendingId = try await stagePending(
        data: data,
        headers: headers,
        parserIdentifier: parserIdentifier,
        filename: source.filename)
      return .needsSetup(pendingId: pendingId)
    }
  }

  /// Rebuild a `GenericBankCSVParser.ColumnMapping` from the raw strings
  /// persisted on `CSVImportProfile.columnRoleRawValues`. Static +
  /// nonisolated so it can be called from `runPipeline` without crossing
  /// actor boundaries. Returns nil when the raw-values array is empty /
  /// all nil / obviously inconsistent with the live headers.
  nonisolated static func buildColumnMapping(
    headers: [String],
    columnRoleRawValues: [String?],
    sampleRows: [[String]],
    dateFormatOverride: GenericBankCSVParser.DateFormat?
  ) -> GenericBankCSVParser.ColumnMapping? {
    guard columnRoleRawValues.count == headers.count else { return nil }
    // Resolve role per column; indices < 0 mean "unassigned" which
    // `safe(row:_:)` turns into "".
    func firstIndex(of role: CSVImportSetupStore.ColumnRole) -> Int? {
      columnRoleRawValues.firstIndex { $0 == role.rawValue }
    }
    let date = firstIndex(of: .date) ?? -1
    let description = firstIndex(of: .description) ?? -1
    guard date >= 0, description >= 0 else { return nil }
    let amount = firstIndex(of: .amount)
    let debit = firstIndex(of: .debit)
    let credit = firstIndex(of: .credit)
    let balance = firstIndex(of: .balance)
    let reference = firstIndex(of: .reference)
    guard amount != nil || (debit != nil && credit != nil) else { return nil }

    // Date format: prefer the explicit override; otherwise re-detect
    // against the current sample rows using the same algorithm the
    // detector uses when a profile has no stored format.
    let parser = GenericBankCSVParser()
    let detectedMapping = parser.inferMapping(from: headers, sampleRows: sampleRows)
    let detectedFormat =
      detectedMapping?.dateFormat ?? .ddMMyyyy(separator: "/")
    let dateFormat = dateFormatOverride ?? detectedFormat

    return GenericBankCSVParser.ColumnMapping(
      date: date,
      description: description,
      amount: amount,
      debit: debit,
      credit: credit,
      balance: balance,
      reference: reference,
      dateFormat: dateFormat,
      dateFormatAmbiguous: false)
  }
}
