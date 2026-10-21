import Foundation
import Testing

@testable import Moolah

@MainActor
struct MoolahReadQueryServiceTests {
  @Test
  func backgroundReadsLeaveTheVisibleTransactionFilterUnchanged() async throws {
    let containers = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "Read fixture")
    let repository = containers.profileIndexRepositoryForTesting
    try await repository.upsert(profile)
    let manager = SessionManager(
      resources: .disconnected,
      containerManager: containers,
      profileIndexRepository: repository)
    let session = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let originalFilter = TransactionFilter(payee: "Visible window filter")
    session.transactionStore.setCurrentFilter(originalFilter)
    let service = MoolahReadQueryService(sessions: manager)
    let response = try await service.accounts(
      profileID: profile.id,
      page: ReadPageRequest(),
      timeZone: .utc)
    #expect(response.metadata.profileID == profile.id)
    #expect(response.metadata.syncState == "unknown")
    #expect(!response.metadata.localRevision.isEmpty)
    #expect(session.transactionStore.currentFilter == originalFilter)
    manager.removeSession(for: profile.id)
  }

  @Test
  func datedReadsReportTheSearchRangesEffectiveTimezone() async throws {
    let containers = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "Timezone fixture")
    let index = containers.profileIndexRepositoryForTesting
    try await index.upsert(profile)
    let manager = SessionManager(
      resources: .disconnected,
      containerManager: containers,
      profileIndexRepository: index)
    defer { manager.removeSession(for: profile.id) }
    _ = try await manager.acquireReadSession(profileID: profile.id, owner: UUID())
    let zone = try #require(TimeZone(identifier: "America/New_York"))
    let range = try ReadDateRange(from: "2025-03-09", through: "2025-03-09", timeZone: zone)
    let search = try ReadTransactionSearch(range: range)
    let response = try await MoolahReadQueryService(sessions: manager).transactions(
      profileID: profile.id,
      search: search,
      page: ReadPageRequest())
    #expect(response.metadata.timeZone == zone.identifier)
    #expect(
      search.range.interval.upperBound.timeIntervalSince(search.range.interval.lowerBound) == 23
        * 3600)
  }

  @Test
  func aQueryWithoutAReadyServiceLeaseCannotUseAnOpenWindowProfile() async throws {
    let containers = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "Window-only fixture")
    let manager = SessionManager(
      resources: .disconnected,
      containerManager: containers,
      profileIndexRepository: containers.profileIndexRepositoryForTesting)
    _ = await manager.session(for: profile)
    let service = MoolahReadQueryService(sessions: manager)
    await #expect(throws: ReadQueryError.profileUnavailable) {
      try await service.accounts(profileID: profile.id, page: ReadPageRequest(), timeZone: .utc)
    }
    manager.removeSession(for: profile.id)
  }
}
