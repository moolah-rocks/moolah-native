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
  func testCreateRejectsEmptyName() async throws {
    let (backend, _) = try TestBackend.create()
    let store = CategoryStore(repository: backend.categories)
    try await store.waitForFirstEmission()

    let result = await store.create(Moolah.Category(name: ""))

    #expect(result == nil)
    // Validation rejection is distinct from a repository failure — it must
    // not surface on `store.error`.
    #expect(store.error == nil)
    #expect(store.categories.roots.isEmpty)
  }

  @Test
  func testUpdateRejectsEmptyName() async throws {
    let cat = Moolah.Category(name: "Groceries")
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(categories: [cat], in: database)
    let store = CategoryStore(repository: backend.categories)
    try await store.waitForFirstEmission()

    var blanked = cat
    blanked.name = ""
    let result = await store.update(blanked)

    #expect(result == nil)
    // Validation rejection is distinct from a repository failure — it must
    // not surface on `store.error`.
    #expect(store.error == nil)
    #expect(store.categories.by(id: cat.id)?.name == "Groceries")
  }

  /// The detail inspector fires `onUpdate` on every keystroke; the store
  /// debounce must coalesce a rapid burst into a single save that runs
  /// the last action only. `.zero` short-circuits the production 300ms
  /// wait — the task still hops the executor, so earlier saves are
  /// cancelled before they run.
  @Test
  func testDebouncedSaveOnlyRunsLastAction() async throws {
    let (backend, _) = try TestBackend.create()
    let store = CategoryStore(repository: backend.categories, debounceInterval: .zero)

    var callCount = 0
    var lastValue = ""

    store.debouncedSave {
      callCount += 1
      lastValue = "first"
    }
    store.debouncedSave {
      callCount += 1
      lastValue = "second"
    }
    let liveSave = store.debouncedSave {
      callCount += 1
      lastValue = "third"
    }

    await liveSave.value

    #expect(callCount == 1)
    #expect(lastValue == "third")
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
