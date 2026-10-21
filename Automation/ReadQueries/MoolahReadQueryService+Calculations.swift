import Foundation

extension MoolahReadQueryService {
  func valuedBalances(
    profileID: UUID,
    accountIDs: Set<UUID>,
    reportingInstrument: Instrument?,
    timeZone: TimeZone
  ) async throws -> ReadQueryResponse<ReadValuedBalanceDTO> {
    try await calculate(
      profileID: profileID,
      reportingInstrument: reportingInstrument,
      timeZone: timeZone,
      read: { try await $0.balanceInputs(accountIDs: accountIDs) },
      transform: { inputs, calculation, target, date in
        let (items, warnings) = try await calculation.balances(inputs, target: target, on: date)
        return ReadCalculatedItems(items: items, warnings: warnings)
      }
    )
  }

  func summary(
    profileID: UUID,
    range: ReadDateRange,
    reportingInstrument: Instrument?,
    groupByCategory: Bool
  ) async throws -> ReadQueryResponse<ReadSummaryDTO> {
    try await calculate(
      profileID: profileID,
      reportingInstrument: reportingInstrument,
      timeZone: range.timeZone,
      read: { repository in
        let snapshot = try await repository.summaryInputs(range: range)
        return ReadPage(
          items: [snapshot],
          revision: snapshot.revision,
          queriedAt: snapshot.queriedAt,
          nextKey: nil
        )
      },
      transform: { inputs, calculation, target, _ in
        guard let snapshot = inputs.first else { throw ReadCalculationError.invalidResult }
        let (item, warnings) = try await calculation.summary(
          snapshot,
          target: target,
          groupByCategory: groupByCategory
        )
        return ReadCalculatedItems(items: [item], warnings: warnings)
      }
    )
  }

  private func calculate<Input: Sendable, Output: Codable & Sendable>(
    profileID: UUID,
    reportingInstrument: Instrument?,
    timeZone: TimeZone,
    read: @Sendable (any ReadQueryRepository) async throws -> ReadPage<Input>,
    transform:
      @Sendable ([Input], ReadFinancialCalculationService, Instrument, Date) async throws ->
      ReadCalculatedItems<Output>
  ) async throws -> ReadQueryResponse<Output> {
    let access = try await sessions.readAccess(profileID: profileID)
    do {
      let page = try await read(access.repository)
      try Task.checkCancellation()
      let result = try await transform(
        page.items,
        ReadFinancialCalculationService(conversion: access.conversionService),
        reportingInstrument ?? access.profile.instrument,
        page.queriedAt
      )
      try Task.checkCancellation()
      try await sessions.validateReadAccess(access)
      return ReadQueryResponse(
        metadata: ReadQueryMetadata(
          queriedAt: page.queriedAt,
          profileID: profileID,
          timeZone: timeZone.identifier,
          localRevision: page.revision,
          consistency: "profile_database_read_snapshot;prices_read_separately",
          syncState: "unknown",
          warnings: [
            "Results use data currently available on this Mac. If you use iCloud sync, recent changes from your other devices may not appear yet.",
            "Financial records come from one database snapshot. Prices are read separately and may be cached or dated to an earlier market day.",
          ] + result.warnings
        ),
        items: result.items,
        nextKey: nil
      )
    } catch is CancellationError { throw CancellationError() } catch let error as ReadQueryError {
      throw error
    } catch {
      throw error
    }
  }
}

private struct ReadCalculatedItems<Element: Sendable>: Sendable {
  let items: [Element]
  let warnings: [String]
}
