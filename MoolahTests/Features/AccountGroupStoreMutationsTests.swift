import Foundation
// Re-export the import for `GRDB.DatabaseWriter` used as a type in the
// helper above. The @testable import of Moolah re-exports GRDB types
// used by the production code, but the test target needs an explicit
// `import GRDB` for type names that don't appear elsewhere in this
// suite's signatures.
import GRDB
import Testing

@testable import Moolah

@Suite("AccountGroupStore — mutations")
@MainActor
struct AccountGroupStoreMutationsTests {

  private func makeStores(
    seedAccounts: [Account] = [],
    in database: any GRDB.DatabaseWriter,
    backend: CloudKitBackend
  ) async throws -> (AccountStore, AccountGroupStore) {
    TestBackend.seed(accounts: seedAccounts, in: database)
    let accountStore = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    let groupStore = AccountGroupStore(repository: backend.accountGroups)
    try await groupStore.waitForFirstEmission()
    // Wait for the initial accounts emission (carries the seeded rows).
    // Using `waitForNextEmission` rather than `waitForFirstEmission` so
    // tests that don't seed still see the empty initial tick.
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.ordered.count == seedAccounts.count },
      description: "accounts seeded observed")
    return (accountStore, groupStore)
  }

  @Test("createGroup(from:) creates a 1-member group with the source account")
  func createGroupFromSingleAccount() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Wallet", type: .crypto, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    let (accountStore, groupStore) = try await makeStores(
      seedAccounts: [account], in: database, backend: backend)

    let group = try await groupStore.createGroup(
      from: account, name: "New Group", accountStore: accountStore)

    #expect(group.name == "New Group")
    #expect(group.bucket == .investments)
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: account.id)?.groupId == group.id },
      description: "member.groupId set"
    )
    let member = try #require(accountStore.accounts.by(id: account.id))
    #expect(member.groupId == group.id)
    #expect(member.position == 0)
  }

  @Test("createGroup(joining:and:) creates a 2-member group")
  func createGroupFromTwoAccounts() async throws {
    let (backend, database) = try TestBackend.create()
    let accountA = Account(
      id: UUID(), name: "A", type: .crypto, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    let accountB = Account(
      id: UUID(), name: "B", type: .crypto, instrument: .AUD,
      positions: [], position: 1, isHidden: false,
      walletAddress: "0x" + String(repeating: "b", count: 40), chainId: 1)
    let (accountStore, groupStore) = try await makeStores(
      seedAccounts: [accountA, accountB], in: database, backend: backend)

    let group = try await groupStore.createGroup(
      joining: accountA, and: accountB, name: "Pair", accountStore: accountStore)

    try await accountStore.waitForNextEmission(
      matching: {
        $0.accounts.by(id: accountA.id)?.groupId == group.id
          && $0.accounts.by(id: accountB.id)?.groupId == group.id
      },
      description: "both members in group"
    )
    let memberA = try #require(accountStore.accounts.by(id: accountA.id))
    let memberB = try #require(accountStore.accounts.by(id: accountB.id))
    #expect(memberA.position == 0)
    #expect(memberB.position == 1)
  }

  @Test("addAccount(_:to:) sets groupId and persists order")
  func addAccountToExistingGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let seed = Account(
      id: UUID(), name: "Seed", type: .crypto, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    let target = Account(
      id: UUID(), name: "Target", type: .crypto, instrument: .AUD,
      positions: [], position: 1, isHidden: false,
      walletAddress: "0x" + String(repeating: "b", count: 40), chainId: 1)
    let (accountStore, groupStore) = try await makeStores(
      seedAccounts: [seed, target], in: database, backend: backend)

    let group = try await groupStore.createGroup(
      from: seed, name: "Crypto", accountStore: accountStore)
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: seed.id)?.groupId == group.id },
      description: "seed member observed"
    )

    try await groupStore.addAccount(target, to: group, accountStore: accountStore)
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: target.id)?.groupId == group.id },
      description: "target joined"
    )
    let added = try #require(accountStore.accounts.by(id: target.id))
    #expect(added.groupId == group.id)
    #expect(added.position == 1)
  }

  @Test("removeAccount clears groupId and auto-deletes single-member group")
  func removeLastMemberAutoDeletes() async throws {
    let (backend, database) = try TestBackend.create()
    let account = Account(
      id: UUID(), name: "Solo", type: .crypto, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    let (accountStore, groupStore) = try await makeStores(
      seedAccounts: [account], in: database, backend: backend)

    let group = try await groupStore.createGroup(
      from: account, name: "Solo Group", accountStore: accountStore)
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: account.id)?.groupId == group.id },
      description: "member in group"
    )
    try await groupStore.waitForNextEmission(
      matching: { $0.groups.contains { $0.id == group.id } },
      description: "group observed"
    )

    // Reload the post-join account so it carries the updated `groupId`.
    let member = try #require(accountStore.accounts.by(id: account.id))
    try await groupStore.removeAccount(member, accountStore: accountStore)
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: account.id)?.groupId == nil },
      description: "groupId cleared"
    )
    try await groupStore.waitForNextEmission(
      matching: { !$0.groups.contains { $0.id == group.id } },
      description: "empty group auto-deleted"
    )
    #expect(groupStore.by(id: group.id) == nil)
  }

  @Test("removeAccount leaves group when other members remain")
  func removeAccountLeavesGroupWhenMembersRemain() async throws {
    let (backend, database) = try TestBackend.create()
    let accountA = Account(
      id: UUID(), name: "A", type: .crypto, instrument: .AUD,
      positions: [], position: 0, isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    let accountB = Account(
      id: UUID(), name: "B", type: .crypto, instrument: .AUD,
      positions: [], position: 1, isHidden: false,
      walletAddress: "0x" + String(repeating: "b", count: 40), chainId: 1)
    let (accountStore, groupStore) = try await makeStores(
      seedAccounts: [accountA, accountB], in: database, backend: backend)

    let group = try await groupStore.createGroup(
      joining: accountA, and: accountB, name: "Pair", accountStore: accountStore)
    try await accountStore.waitForNextEmission(
      matching: {
        $0.accounts.by(id: accountA.id)?.groupId == group.id
          && $0.accounts.by(id: accountB.id)?.groupId == group.id
      },
      description: "both joined"
    )

    // Reload the post-join A so it carries the updated `groupId`.
    let memberA = try #require(accountStore.accounts.by(id: accountA.id))
    try await groupStore.removeAccount(memberA, accountStore: accountStore)
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: accountA.id)?.groupId == nil },
      description: "A removed"
    )
    #expect(groupStore.by(id: group.id) != nil)
    #expect(accountStore.accounts.by(id: accountB.id)?.groupId == group.id)
  }

  @Test("rename updates a group's name")
  func renameUpdatesName() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Old", bucket: .investments,
        instrument: .defaultTestInstrument))
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForNextEmission(
      matching: { $0.by(id: group.id) != nil },
      description: "group observed"
    )

    let renamed = try await store.rename(id: group.id, to: "New")

    #expect(renamed?.name == "New")
    try await store.waitForNextEmission(
      matching: { $0.by(id: group.id)?.name == "New" },
      description: "rename observed"
    )
    #expect(store.error == nil)
  }

  @Test("rename trims whitespace before persisting")
  func renameTrimsWhitespace() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Old", bucket: .investments,
        instrument: .defaultTestInstrument))
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForNextEmission(
      matching: { $0.by(id: group.id) != nil },
      description: "group observed"
    )

    let renamed = try await store.rename(id: group.id, to: "  Spaced  ")

    #expect(renamed?.name == "Spaced")
  }

  @Test("rename to empty / whitespace-only string is a no-op")
  func renameToEmptyIsNoOp() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Stable", bucket: .investments,
        instrument: .defaultTestInstrument))
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForNextEmission(
      matching: { $0.by(id: group.id) != nil },
      description: "group observed"
    )

    let result = try await store.rename(id: group.id, to: "   ")
    #expect(result?.name == "Stable")
    #expect(store.error == nil)
  }

  @Test("rename to same name is a no-op")
  func renameToSameNameIsNoOp() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Stable", bucket: .investments,
        instrument: .defaultTestInstrument))
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForNextEmission(
      matching: { $0.by(id: group.id) != nil },
      description: "group observed"
    )

    let result = try await store.rename(id: group.id, to: "Stable")
    #expect(result?.name == "Stable")
    #expect(store.error == nil)
  }

  @Test("rename of unknown id returns nil without surfacing an error")
  func renameOfUnknownIdReturnsNil() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForFirstEmission()

    let result = try await store.rename(id: UUID(), to: "Whatever")
    #expect(result == nil)
    #expect(store.error == nil)
  }

  @Test("moveGroup updates the group's position")
  func moveGroupUpdatesPosition() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "G", bucket: .investments,
        instrument: .defaultTestInstrument, position: 0))
    let store = AccountGroupStore(repository: backend.accountGroups)
    try await store.waitForNextEmission(
      matching: { $0.by(id: group.id) != nil },
      description: "group observed"
    )

    try await store.moveGroup(group, to: 5)
    try await store.waitForNextEmission(
      matching: { $0.by(id: group.id)?.position == 5 },
      description: "position updated"
    )
  }
}
