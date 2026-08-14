import Testing

@testable import Moolah

@Suite("AccountRepository automatic sync persistence")
struct AccountRepositoryAutomaticSyncTests {
  @Test("Update persists a disabled automatic sync preference")
  func updatePersistsDisabledAutomaticSync() async throws {
    let (backend, _) = try TestBackend.create()
    let created = try await backend.accounts.create(
      Account(name: "Wallet", type: .bank, instrument: .AUD),
      openingBalance: nil)
    var disabled = created
    disabled.isAutomaticSyncEnabled = false

    let updated = try await backend.accounts.update(disabled)
    let fetched = try #require(
      try await backend.accounts.fetchAll().first { $0.id == created.id })

    #expect(updated.isAutomaticSyncEnabled == false)
    #expect(fetched.isAutomaticSyncEnabled == false)
  }
}
