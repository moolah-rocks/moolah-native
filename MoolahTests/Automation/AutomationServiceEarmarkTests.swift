import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Earmark Operations")
@MainActor
struct AutomationServiceEarmarkTests {
  private struct OpenSessionFailed: Error {}

  private func makeServiceWithSession() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(
      containerManager: containerManager,
      profileIndexRepository: containerManager.profileIndexRepositoryForTesting)
    let profile = Profile(
      label: "Test",
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    guard case .ready(let session) = await sessionManager.session(for: profile) else {
      Issue.record("expected .ready")
      throw OpenSessionFailed()
    }
    // EarmarkStore is reactive — wait for the first emission so any
    // pre-seeded earmarks are visible.
    try await session.earmarkStore.waitForFirstEmission()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("createEarmark creates and lists earmarks")
  func createAndListEarmarks() async throws {
    let (service, _) = try await makeServiceWithSession()

    let earmark = try await service.createEarmark(
      profileIdentifier: "Test",
      name: "Holiday Fund",
      targetAmount: 5000
    )

    #expect(earmark.name == "Holiday Fund")
    #expect(earmark.savingsGoal?.quantity == 5000)

    // EarmarkStore is reactive — the new earmark becomes listable shortly after
    // the GRDB write commits. Poll the exact asserted value (the service
    // listing) so a racing observation pass can't slip a stale read between an
    // awaited emission and a single read.
    await expectEventually("created earmark is listed via the service") {
      let earmarks = (try? service.listEarmarks(profileIdentifier: "Test")) ?? []
      return earmarks.count == 1 && earmarks.first?.name == "Holiday Fund"
    }
  }

  @Test("resolveEarmark finds earmark case-insensitively")
  func resolveEarmarkCaseInsensitive() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createEarmark(
      profileIdentifier: "Test",
      name: "Emergency Fund"
    )

    // Authoritative read — resolves deterministically, no expectEventually.
    let resolved = try await service.resolveEarmark(
      named: "emergency fund", profileIdentifier: "Test")
    #expect(resolved.name == "Emergency Fund")
  }

  @Test("resolveEarmark throws when not found")
  func resolveEarmarkNotFound() async throws {
    let (service, _) = try await makeServiceWithSession()

    await #expect(throws: AutomationError.self) {
      try await service.resolveEarmark(named: "NonExistent", profileIdentifier: "Test")
    }
  }
}
