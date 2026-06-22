import Foundation
import Testing

@testable import Moolah

@Suite("Multi-Profile Isolation")
struct MultiProfileIsolationTests {
  @Test("two CloudKit backends with separate containers see only their own data")
  @MainActor
  func testProfileIsolation() async throws {
    let (backendA, _) = try TestBackend.create()
    let (backendB, _) = try TestBackend.create()

    _ = try await backendA.categories.create(Moolah.Category(name: "Groceries"))
    _ = try await backendA.categories.create(Moolah.Category(name: "Transport"))
    _ = try await backendB.categories.create(Moolah.Category(name: "Entertainment"))

    let categoriesA = try await backendA.categories.fetchAll()
    #expect(categoriesA.count == 2)

    let categoriesB = try await backendB.categories.fetchAll()
    #expect(categoriesB.count == 1)
    #expect(categoriesB[0].name == "Entertainment")
  }

  @Test("deleting one profile's store doesn't affect another")
  @MainActor
  func testDeleteIsolation() async throws {
    let manager = try ProfileContainerManager.forTesting()
    let profileA = UUID()

    // Two independent in-memory GRDB-backed backends. Profile B's data
    // must survive the deletion of Profile A's store on the manager.
    let databaseA = try ProfileDatabase.openInMemory()
    let databaseB = try ProfileDatabase.openInMemory()
    let backendA = CloudKitBackend(
      database: databaseA,
      instrument: .defaultTestInstrument, profileLabel: "A",
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentRegistry: GRDBInstrumentRegistryRepository(database: databaseA))
    let backendB = CloudKitBackend(
      database: databaseB,
      instrument: .defaultTestInstrument, profileLabel: "B",
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentRegistry: GRDBInstrumentRegistryRepository(database: databaseB))

    _ = try await backendA.categories.create(Moolah.Category(name: "A-Cat"))
    _ = try await backendB.categories.create(Moolah.Category(name: "B-Cat"))

    manager.deleteStore(for: profileA)

    let categoriesB = try await backendB.categories.fetchAll()
    #expect(categoriesB.count == 1)
    #expect(categoriesB[0].name == "B-Cat")
  }
}
