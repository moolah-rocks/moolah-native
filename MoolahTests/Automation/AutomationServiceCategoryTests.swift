import Foundation
import Testing

@testable import Moolah

@Suite("AutomationService Category Operations")
@MainActor
struct AutomationServiceCategoryTests {
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
    // CategoryStore is reactive — wait for the first emission so any
    // pre-seeded rows are visible.
    try await session.categoryStore.waitForFirstEmission()
    let service = AutomationService(sessionManager: sessionManager)
    return (service, session)
  }

  @Test("createCategory creates and lists categories")
  func createAndListCategories() async throws {
    let (service, _) = try await makeServiceWithSession()

    let category = try await service.createCategory(
      profileIdentifier: "Test",
      name: "Food",
      parentName: nil
    )

    #expect(category.name == "Food")
    #expect(category.parentId == nil)

    // CategoryStore is reactive — the new category becomes listable shortly
    // after the GRDB write commits. Poll the exact asserted value so a racing
    // observation pass can't slip a stale read between an awaited emission and
    // a single read.
    await expectEventually("created category is listed via the service") {
      let categories = (try? service.listCategories(profileIdentifier: "Test")) ?? []
      return categories.count == 1 && categories.first?.name == "Food"
    }
  }

  @Test("resolveCategory finds category by name case-insensitively")
  func resolveCategoryByName() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createCategory(
      profileIdentifier: "Test",
      name: "Transport",
      parentName: nil
    )

    await expectEventually("created category resolves case-insensitively") {
      (try? service.resolveCategory(named: "transport", profileIdentifier: "Test"))?.name
        == "Transport"
    }
  }

  @Test("resolveCategory throws when not found")
  func resolveCategoryNotFound() async throws {
    let (service, _) = try await makeServiceWithSession()

    #expect(throws: AutomationError.self) {
      try service.resolveCategory(named: "NonExistent", profileIdentifier: "Test")
    }
  }

  @Test("createCategory with parent creates subcategory")
  func createSubcategory() async throws {
    let (service, session) = try await makeServiceWithSession()

    let parent = try await service.createCategory(
      profileIdentifier: "Test",
      name: "Food",
      parentName: nil
    )

    // The subsequent createCategory call resolves "Food" against the
    // store's `categories` cache — wait for the first create to land
    // there before issuing the second.
    try await session.categoryStore.waitForNextEmission(
      matching: { $0.categories.roots.contains { $0.name == "Food" } },
      description: "parent category observable"
    )

    let child = try await service.createCategory(
      profileIdentifier: "Test",
      name: "Groceries",
      parentName: "Food"
    )

    #expect(child.parentId == parent.id)
  }
}
