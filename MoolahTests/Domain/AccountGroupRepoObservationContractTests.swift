import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("AccountGroupRepository observation contract")
struct AccountGroupRepoObservationContractTests {

  @Test("initial emission reflects current DB state")
  func initialEmission() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.accountGroups.observeAll().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)
  }

  @Test("create emits new value")
  func createEmits() async throws {
    let (backend, _) = try TestBackend.create()
    var iterator = backend.accountGroups.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial empty

    _ = try await backend.accountGroups.create(
      AccountGroup(
        name: "Trust Fund Crypto",
        bucket: .investments,
        instrument: .defaultTestInstrument)
    )

    let afterCreate = await iterator.next()
    #expect(afterCreate?.count == 1)
    #expect(afterCreate?.first?.name == "Trust Fund Crypto")
  }

  @Test("update emits new value")
  func updateEmits() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.accountGroups.create(
      AccountGroup(
        name: "Original Name",
        bucket: .investments,
        instrument: .defaultTestInstrument)
    )
    var iterator = backend.accountGroups.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial — single group
    var updated = created
    updated.name = "Renamed"
    _ = try await backend.accountGroups.update(updated)
    let afterUpdate = await iterator.next()
    let renamed = try #require(afterUpdate?.first)
    #expect(renamed.name == "Renamed")
  }

  @Test("delete emits new value")
  func deleteEmits() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.accountGroups.create(
      AccountGroup(
        name: "Doomed",
        bucket: .investments,
        instrument: .defaultTestInstrument)
    )
    var iterator = backend.accountGroups.observeAll().makeAsyncIterator()
    _ = await iterator.next()  // initial — single group

    try await backend.accountGroups.delete(id: created.id)

    let afterDelete = await iterator.next()
    #expect(afterDelete?.contains { $0.id == created.id } == false)
  }
}
