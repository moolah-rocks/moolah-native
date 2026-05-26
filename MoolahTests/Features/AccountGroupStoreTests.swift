import Foundation
import Testing

@testable import Moolah

@Suite("AccountGroupStore — load & observe")
@MainActor
struct AccountGroupStoreTests {

  @Test("initial emission is empty")
  func initialLoadEmitsEmpty() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForFirstEmission()

    #expect(store.groups.isEmpty)
  }

  @Test("creating a group emits via observation")
  func createObserved() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForFirstEmission()

    _ = try await backend.accountGroups.create(
      AccountGroup(
        name: "Trust Fund Crypto", bucket: .investments,
        instrument: .defaultTestInstrument))

    try await store.waitForNextEmission(
      matching: { $0.groups.count == 1 },
      description: "create observed"
    )
    #expect(store.groups.first?.name == "Trust Fund Crypto")
    #expect(store.error == nil)
  }

  @Test("groups are ordered by position ascending")
  func groupsAreOrderedByPositionAscending() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForFirstEmission()

    _ = try await backend.accountGroups.create(
      AccountGroup(
        name: "B", bucket: .investments,
        instrument: .defaultTestInstrument, position: 2))
    _ = try await backend.accountGroups.create(
      AccountGroup(
        name: "A", bucket: .investments,
        instrument: .defaultTestInstrument, position: 1))

    try await store.waitForNextEmission(
      matching: { $0.groups.count == 2 },
      description: "creates observed"
    )
    #expect(store.groups.map(\.name) == ["A", "B"])
  }

  @Test("by(id:) finds an existing group")
  func byIdReturnsGroup() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForFirstEmission()

    let created = try await backend.accountGroups.create(
      AccountGroup(
        name: "G", bucket: .investments,
        instrument: .defaultTestInstrument))

    try await store.waitForNextEmission(
      matching: { $0.groups.count == 1 },
      description: "create observed"
    )

    #expect(store.by(id: created.id)?.name == "G")
    #expect(store.by(id: UUID()) == nil)
  }

  @Test("members(of:) filters accounts by groupId and sorts by position")
  func membersFilteredAndSorted() async throws {
    let (backend, database) = try TestBackend.create()
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForFirstEmission()

    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "G", bucket: .investments,
        instrument: .defaultTestInstrument))

    let memberB = Account(
      id: UUID(), name: "B", type: .crypto, instrument: .AUD,
      positions: [], position: 1, isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1,
      groupId: group.id)
    let memberA = Account(
      id: UUID(), name: "A", type: .crypto, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      walletAddress: "0x" + String(repeating: "b", count: 40), chainId: 1,
      groupId: group.id)
    let nonMember = Account(
      id: UUID(), name: "Standalone", type: .bank, instrument: .AUD,
      positions: [], position: 0, isHidden: false)
    TestBackend.seed(accounts: [memberA, memberB, nonMember], in: database)

    let accountsList = try await backend.accounts.fetchAll()
    let accounts = Accounts(from: accountsList)

    let members = store.members(of: group.id, in: accounts)
    #expect(members.map(\.name) == ["A", "B"])
  }
}
