import Foundation
import Testing

@testable import Moolah

@Suite("CategoryStore")
@MainActor
struct CategoryStoreTests {
  @Test
  func testInitialEmissionPopulatesCategories() async throws {
    let cat = Moolah.Category(name: "Groceries")
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(categories: [cat], in: database)
    let store = CategoryStore(repository: backend.categories)

    try await store.waitForFirstEmission()

    #expect(store.categories.roots.count == 1)
    #expect(store.categories.roots.first?.name == "Groceries")
  }

  @Test
  func testCreateAddsCategory() async throws {
    let (backend, _) = try TestBackend.create()
    let store = CategoryStore(repository: backend.categories)
    try await store.waitForFirstEmission()

    let cat = Moolah.Category(name: "Transport")
    let created = await store.create(cat)

    #expect(created != nil)
    #expect(created?.name == "Transport")
    await expectEventually("categories has one root named Transport") {
      store.categories.roots.count == 1
        && store.categories.roots.first?.name == "Transport"
    }
  }

  @Test
  func testCreateReturnsNilOnFailure() async throws {
    let store = CategoryStore(repository: FailingCategoryRepository())

    let result = await store.create(Moolah.Category(name: "Fails"))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test
  func testUpdateModifiesCategory() async throws {
    let cat = Moolah.Category(name: "Groceries")
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(categories: [cat], in: database)
    let store = CategoryStore(repository: backend.categories)
    try await store.waitForFirstEmission()

    var modified = cat
    modified.name = "Food & Groceries"
    let updated = await store.update(modified)

    #expect(updated != nil)
    #expect(updated?.name == "Food & Groceries")
    try await store.waitForNextEmission(
      matching: { $0.categories.by(id: cat.id)?.name == "Food & Groceries" },
      description: "category renamed"
    )
  }

  @Test
  func testUpdateReturnsNilOnFailure() async throws {
    let store = CategoryStore(repository: FailingCategoryRepository())

    let result = await store.update(Moolah.Category(name: "Fails"))

    #expect(result == nil)
    #expect(store.error != nil)
  }

  @Test
  func testDeleteRemovesCategory() async throws {
    let cat = Moolah.Category(name: "Groceries")
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(categories: [cat], in: database)
    let store = CategoryStore(repository: backend.categories)
    try await store.waitForNextEmission(
      matching: { $0.categories.roots.count == 1 },
      description: "store sees seeded category"
    )

    let success = await store.delete(id: cat.id, withReplacement: nil)

    #expect(success == true)
    try await store.waitForNextEmission(
      matching: { $0.categories.roots.isEmpty },
      description: "category removed"
    )
  }

  @Test
  func testDeleteWithReplacementId() async throws {
    let cat1 = Moolah.Category(name: "Old Category")
    let cat2 = Moolah.Category(name: "New Category")
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(categories: [cat1, cat2], in: database)
    let store = CategoryStore(repository: backend.categories)
    try await store.waitForNextEmission(
      matching: { $0.categories.roots.count == 2 },
      description: "store sees both seeded categories"
    )

    let success = await store.delete(id: cat1.id, withReplacement: cat2.id)

    #expect(success == true)
    await expectEventually("categories collapsed to one named New Category") {
      store.categories.roots.count == 1
        && store.categories.roots.first?.name == "New Category"
    }
  }

  @Test
  func testDeleteReturnsFalseOnFailure() async throws {
    let store = CategoryStore(repository: FailingCategoryRepository())

    let result = await store.delete(id: UUID(), withReplacement: nil)

    #expect(result == false)
    #expect(store.error != nil)
  }
}

// MARK: - Test helpers

private struct FailingCategoryRepository: CategoryRepository {
  func fetchAll() async throws -> [Moolah.Category] {
    throw BackendError.networkUnavailable
  }

  func observeAll() -> AsyncStream<[Moolah.Category]> {
    AsyncStream { $0.finish() }
  }

  func observeErrors() -> AsyncStream<any Error> {
    AsyncStream { $0.finish() }
  }

  func create(_ category: Moolah.Category) async throws -> Moolah.Category {
    throw BackendError.networkUnavailable
  }

  func update(_ category: Moolah.Category) async throws -> Moolah.Category {
    throw BackendError.networkUnavailable
  }

  func delete(id: UUID, withReplacement replacementId: UUID?) async throws {
    throw BackendError.networkUnavailable
  }
}
