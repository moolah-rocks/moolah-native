import Foundation
import Testing

@testable import Moolah

/// Shared factory for AutomationService tests: opens a fresh in-memory
/// profile session and returns the service wired to it.
@MainActor
enum AutomationTestSession {
  struct OpenSessionFailed: Error {}

  static func make() async throws -> (AutomationService, ProfileSession) {
    let containerManager = try ProfileContainerManager.forTesting()
    let sessionManager = SessionManager(
      containerManager: containerManager,
      profileIndexRepository: containerManager.profileIndexRepositoryForTesting)
    let profile = Profile(label: "Test", currencyCode: "AUD", financialYearStartMonth: 7)
    guard case .ready(let session) = await sessionManager.session(for: profile) else {
      Issue.record("expected .ready")
      throw OpenSessionFailed()
    }
    try await session.accountStore.waitForFirstEmission()
    return (AutomationService(sessionManager: sessionManager), session)
  }
}
