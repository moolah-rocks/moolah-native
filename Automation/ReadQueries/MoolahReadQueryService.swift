import Foundation

/// Background reads use repository snapshots, with a short main-actor hop for session ownership.
/// Grant/profile authorization belongs at the calling transport boundary, before acquiring leases.
struct MoolahReadQueryService: Sendable {
  let sessions: SessionManager

  func accounts(
    profileID: UUID,
    includeHidden: Bool = false,
    page: ReadPageRequest,
    timeZone: TimeZone
  ) async throws -> ReadQueryResponse<ReadAccountDTO> {
    try await perform(
      profileID: profileID,
      timeZone: timeZone
    ) { reads in
      try await reads.repository.accounts(includeHidden: includeHidden, page: page)
    }
  }

  /// The validated search owns the effective timezone used for both SQL and metadata.
  func transactions(
    profileID: UUID,
    search: ReadTransactionSearch,
    page: ReadPageRequest,
    includeNotes: Bool = false
  ) async throws -> ReadQueryResponse<ReadTransactionDTO> {
    try await perform(
      profileID: profileID,
      timeZone: search.range.timeZone
    ) { reads in
      try await reads.repository.transactions(
        search: search,
        page: page,
        includeNotes: includeNotes
      )
    }
  }

  func categories(
    profileID: UUID,
    page: ReadPageRequest,
    timeZone: TimeZone
  ) async throws -> ReadQueryResponse<ReadCategoryDTO> {
    try await perform(profileID: profileID, timeZone: timeZone) {
      try await $0.repository.categories(page: page)
    }
  }

  func earmarks(
    profileID: UUID,
    page: ReadPageRequest,
    timeZone: TimeZone
  ) async throws -> ReadQueryResponse<ReadEarmarkDTO> {
    try await perform(profileID: profileID, timeZone: timeZone) {
      try await $0.repository.earmarks(page: page)
    }
  }

  func transaction(
    profileID: UUID,
    id: UUID,
    includeNotes: Bool,
    timeZone: TimeZone
  ) async throws -> ReadQueryResponse<ReadTransactionDTO> {
    try await perform(profileID: profileID, timeZone: timeZone) {
      try await $0.repository.transaction(id: id, includeNotes: includeNotes)
    }
  }

  func balances(
    profileID: UUID,
    accountIDs: Set<UUID>,
    timeZone: TimeZone
  ) async throws -> ReadQueryResponse<ReadBalanceDTO> {
    try await perform(profileID: profileID, timeZone: timeZone) {
      try await $0.repository.balances(accountIDs: accountIDs)
    }
  }

  func status(profileID: UUID, timeZone: TimeZone) async throws -> ReadQueryResponse<
    ReadProfileStatusDTO
  > {
    try await perform(profileID: profileID, timeZone: timeZone) { reads in
      let snapshot = try await reads.repository.accounts(
        includeHidden: false,
        page: ReadPageRequest(limit: 1)
      )
      return ReadPage(
        items: [
          ReadProfileStatusDTO(
            id: reads.profile.id,
            label: reads.profile.label,
            baseInstrument: ReadInstrumentDTO(reads.profile.instrument),
            readiness: "ready",
            syncState: reads.syncState.rawValue
          )
        ],
        revision: snapshot.revision,
        queriedAt: snapshot.queriedAt,
        nextKey: nil
      )
    }
  }

  private func perform<Element: Codable & Sendable>(
    profileID: UUID,
    timeZone: TimeZone,
    read: @Sendable (ReadProfileAccess) async throws -> ReadPage<Element>
  ) async throws -> ReadQueryResponse<Element> {
    let access = try await sessions.readAccess(profileID: profileID)
    do {
      let page = try await read(access)
      try Task.checkCancellation()
      try await sessions.validateReadAccess(access)
      return ReadQueryResponse(
        metadata: ReadQueryMetadata(
          queriedAt: page.queriedAt,
          profileID: profileID,
          timeZone: timeZone.identifier,
          localRevision: page.revision,
          consistency: "profile_database_read_snapshot",
          syncState: access.syncState.rawValue,
          warnings: [
            "Results use data currently available on this Mac. "
              + "If you use iCloud sync, recent changes from your other devices may not appear yet."
          ]
        ),
        items: page.items,
        nextKey: page.nextKey
      )
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ReadQueryError {
      throw error
    } catch {
      throw ReadQueryError.profileUnavailable
    }
  }
}
