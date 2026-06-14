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

    // Authoritative read — resolves deterministically, no expectEventually.
    let resolved = try await service.resolveCategory(
      named: "transport", profileIdentifier: "Test")
    #expect(resolved.name == "Transport")
  }

  @Test("resolveCategory matches by full path after authoritative read")
  func resolveCategoryByPath() async throws {
    let (service, _) = try await makeServiceWithSession()

    _ = try await service.createCategory(profileIdentifier: "Test", name: "Food")
    let child = try await service.createCategory(
      profileIdentifier: "Test", name: "Groceries", parentName: "Food")

    // The repository returns a flat list; resolveCategory rebuilds the
    // hierarchy so a full "Food:Groceries" path still resolves.
    let resolved = try await service.resolveCategory(
      named: "food:groceries", profileIdentifier: "Test")
    #expect(resolved.id == child.id)
  }

  @Test("resolveCategory throws when not found")
  func resolveCategoryNotFound() async throws {
    let (service, _) = try await makeServiceWithSession()

    await #expect(throws: AutomationError.self) {
      try await service.resolveCategory(named: "NonExistent", profileIdentifier: "Test")
    }
  }

  @Test("createCategory with parent creates subcategory")
  func createSubcategory() async throws {
    let (service, _) = try await makeServiceWithSession()

    let parent = try await service.createCategory(
      profileIdentifier: "Test",
      name: "Food",
      parentName: nil
    )

    // createCategory resolves the parent via the authoritative repository
    // snapshot, so the second create sees "Food" deterministically without
    // waiting on the reactive store.
    let child = try await service.createCategory(
      profileIdentifier: "Test",
      name: "Groceries",
      parentName: "Food"
    )

    #expect(child.parentId == parent.id)
  }
}
