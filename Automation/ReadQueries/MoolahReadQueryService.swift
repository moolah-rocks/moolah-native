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
      try await reads.accounts(includeHidden: includeHidden, page: page)
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
      try await reads.transactions(search: search, page: page, includeNotes: includeNotes)
    }
  }

  private func perform<Element: Codable & Sendable>(
    profileID: UUID,
    timeZone: TimeZone,
    read: @Sendable (any ReadQueryRepository) async throws -> ReadPage<Element>
  ) async throws -> ReadQueryResponse<Element> {
    let access = try await sessions.readAccess(profileID: profileID)
    do {
      let page = try await read(access.repository)
      try Task.checkCancellation()
      try await sessions.validateReadAccess(access)
      return ReadQueryResponse(
        metadata: ReadQueryMetadata(
          queriedAt: page.queriedAt,
          profileID: profileID,
          timeZone: timeZone.identifier,
          localRevision: page.revision,
          consistency: "profile_database_read_snapshot",
          syncState: "unknown",
          warnings: [
            "Results use data currently available on this Mac. "
              + "If you use iCloud sync, recent changes from your other devices may not appear yet."
          ]),
        items: page.items,
        nextKey: page.nextKey)
    } catch is CancellationError {
      throw CancellationError()
    } catch let error as ReadQueryError {
      throw error
    } catch {
      throw ReadQueryError.profileUnavailable
    }
  }
}
