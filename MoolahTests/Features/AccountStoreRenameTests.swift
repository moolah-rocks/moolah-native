import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore/rename")
@MainActor
struct AccountStoreRenameTests {

  @Test("rename updates the account's name")
  func renameUpdatesName() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(
      name: "Old", type: .bank, balance: 0, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: original.id) != nil },
      description: "seeded account observed"
    )

    let result = try await store.rename(id: original.id, to: "New")

    #expect(result?.name == "New")
    await expectEventually("rename reaches the store with no error") {
      store.accounts.by(id: original.id)?.name == "New" && store.error == nil
    }
    let fetched = try await backend.accounts.fetchAll()
    #expect(fetched.first(where: { $0.id == original.id })?.name == "New")
  }

  @Test("rename trims surrounding whitespace before persisting")
  func renameTrimsWhitespace() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(
      name: "Old", type: .bank, balance: 0, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: original.id) != nil },
      description: "seeded account observed"
    )

    let result = try await store.rename(id: original.id, to: "  Spaced  ")

    #expect(result?.name == "Spaced")
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: original.id)?.name == "Spaced" },
      description: "trimmed rename observed"
    )
    let fetched = try await backend.accounts.fetchAll()
    #expect(fetched.first(where: { $0.id == original.id })?.name == "Spaced")
  }

  @Test("rename to empty / whitespace-only string is a no-op (returns current account unchanged)")
  func renameToEmptyReverts() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(
      name: "Old", type: .bank, balance: 0, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: original.id) != nil },
      description: "seeded account observed"
    )

    let result = try await store.rename(id: original.id, to: "   ")

    // Returns the existing account unchanged; no write happens.
    #expect(result?.name == "Old")
    await expectEventually("store name stays Old after no-op rename") {
      store.accounts.by(id: original.id)?.name == "Old"
    }
  }

  @Test("rename to the same name is a no-op (no write, returns current)")
  func renameToSameNameIsNoOp() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(
      name: "Stable", type: .bank, balance: 0, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: original.id) != nil },
      description: "seeded account observed"
    )

    let result = try await store.rename(id: original.id, to: "Stable")

    #expect(result?.name == "Stable")
    await expectEventually("no-op rename surfaces no error") {
      store.error == nil
    }
    let fetched = try await backend.accounts.fetchAll()
    #expect(fetched.first(where: { $0.id == original.id })?.name == "Stable")
  }

  @Test("rename of unknown id returns nil without surfacing an error")
  func renameOfUnknownIdReturnsNil() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()

    let result = try await store.rename(id: UUID(), to: "Whatever")

    #expect(result == nil)
    await expectEventually("unknown-id rename surfaces no error") {
      store.error == nil
    }
  }
}
