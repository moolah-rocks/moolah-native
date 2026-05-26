import Foundation
import Testing

@testable import Moolah

@Suite("AccountGroupRepository contract")
struct AccountGroupRepositoryContractTests {
  @Test
  func createAndFetchById() async throws {
    let (backend, _) = try TestBackend.create()
    let group = AccountGroup(
      name: "Trust Fund Crypto",
      bucket: .investments,
      instrument: .defaultTestInstrument
    )
    let created = try await backend.accountGroups.create(group)
    let fetched = try await backend.accountGroups.fetchAll()
    #expect(fetched.contains { $0.id == created.id && $0.name == "Trust Fund Crypto" })
  }

  @Test
  func updateRenamesAndPersists() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.accountGroups.create(
      AccountGroup(name: "Old", bucket: .investments, instrument: .defaultTestInstrument)
    )
    var modified = created
    modified.name = "New"
    let updated = try await backend.accountGroups.update(modified)
    #expect(updated.name == "New")

    let fetched = try await backend.accountGroups.fetchAll()
    #expect(fetched.first { $0.id == created.id }?.name == "New")
  }

  @Test
  func deleteRemovesGroup() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.accountGroups.create(
      AccountGroup(name: "Temp", bucket: .investments, instrument: .defaultTestInstrument)
    )
    try await backend.accountGroups.delete(id: created.id)
    let fetched = try await backend.accountGroups.fetchAll()
    #expect(!fetched.contains { $0.id == created.id })
  }

  @Test
  func updateMissingThrows404() async throws {
    let (backend, _) = try TestBackend.create()
    let group = AccountGroup(
      name: "Ghost", bucket: .investments,
      instrument: .defaultTestInstrument
    )
    await #expect(throws: BackendError.serverError(404)) {
      _ = try await backend.accountGroups.update(group)
    }
  }

  @Test
  func bucketIsPersistedAndReadBack() async throws {
    let (backend, _) = try TestBackend.create()
    let current = try await backend.accountGroups.create(
      AccountGroup(name: "Joint", bucket: .current, instrument: .defaultTestInstrument)
    )
    let investments = try await backend.accountGroups.create(
      AccountGroup(name: "Stocks", bucket: .investments, instrument: .defaultTestInstrument)
    )
    let fetched = try await backend.accountGroups.fetchAll()
    #expect(fetched.first { $0.id == current.id }?.bucket == .current)
    #expect(fetched.first { $0.id == investments.id }?.bucket == .investments)
  }

  @Test
  func fetchAllReturnsOrderedByPosition() async throws {
    let (backend, _) = try TestBackend.create()
    _ = try await backend.accountGroups.create(
      AccountGroup(
        name: "Third", bucket: .investments,
        instrument: .defaultTestInstrument, position: 2)
    )
    _ = try await backend.accountGroups.create(
      AccountGroup(
        name: "First", bucket: .investments,
        instrument: .defaultTestInstrument, position: 0)
    )
    _ = try await backend.accountGroups.create(
      AccountGroup(
        name: "Second", bucket: .investments,
        instrument: .defaultTestInstrument, position: 1)
    )
    let fetched = try await backend.accountGroups.fetchAll()
    #expect(fetched.map(\.name) == ["First", "Second", "Third"])
  }
}
