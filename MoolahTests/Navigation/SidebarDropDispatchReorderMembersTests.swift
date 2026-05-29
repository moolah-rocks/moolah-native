import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `SidebarDropDispatch.reorderMembers`. Shared fixtures live in
/// `SidebarDropDispatchTestSupport.swift`.
@Suite("SidebarDropDispatch — reorderMembers")
@MainActor
struct SidebarDropDispatchReorderMembersTests {

  @Test("reorderMembers moves a member within its group")
  func reorderMembersUpdatesPositions() async throws {
    let (backend, database) = try TestBackend.create()
    let memberA = SidebarDropDispatchTestSupport.bankAccount(name: "A", position: 0)
    let memberB = SidebarDropDispatchTestSupport.bankAccount(name: "B", position: 1)
    let memberC = SidebarDropDispatchTestSupport.bankAccount(name: "C", position: 2)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [memberA, memberB, memberC], in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      joining: memberA, and: memberB, name: "G",
      accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: {
        $0.accounts.by(id: memberA.id)?.groupId == group.id
          && $0.accounts.by(id: memberB.id)?.groupId == group.id
      },
      description: "A,B joined")

    let postC = try #require(stores.accountStore.accounts.by(id: memberC.id))
    try await stores.accountGroupStore.addAccount(
      postC, to: group, accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: memberC.id)?.groupId == group.id },
      description: "C joined")

    try await SidebarDropDispatch.reorderMembers(
      groupId: group.id,
      sourceAccountId: memberC.id,
      insertionIndex: 0,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: memberC.id)?.position == 0 },
      description: "C now first member")
    let members = stores.accountStore.accounts.ordered
      .filter { $0.groupId == group.id }
      .sorted { $0.position < $1.position }
      .map(\.id)
    #expect(members == [memberC.id, memberA.id, memberB.id])
  }

  @Test("reorderMembers clamps insertion index past the end")
  func reorderMembersClampsEnd() async throws {
    let (backend, database) = try TestBackend.create()
    let memberA = SidebarDropDispatchTestSupport.bankAccount(name: "A", position: 0)
    let memberB = SidebarDropDispatchTestSupport.bankAccount(name: "B", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [memberA, memberB], in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      joining: memberA, and: memberB, name: "G",
      accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: {
        $0.accounts.by(id: memberA.id)?.groupId == group.id
          && $0.accounts.by(id: memberB.id)?.groupId == group.id
      },
      description: "members joined")

    try await SidebarDropDispatch.reorderMembers(
      groupId: group.id,
      sourceAccountId: memberA.id,
      insertionIndex: 99,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountStore.waitForNextEmission(
      matching: {
        ($0.accounts.by(id: memberA.id)?.position ?? -1)
          > ($0.accounts.by(id: memberB.id)?.position ?? -1)
      },
      description: "A clamped to end")
  }

  @Test("reorderMembers is a no-op when the source id is unknown")
  func reorderMembersRejectsUnknownId() async throws {
    let (backend, database) = try TestBackend.create()
    let memberA = SidebarDropDispatchTestSupport.bankAccount(name: "A", position: 0)
    let memberB = SidebarDropDispatchTestSupport.bankAccount(name: "B", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [memberA, memberB], in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      joining: memberA, and: memberB, name: "G",
      accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: {
        $0.accounts.by(id: memberA.id)?.groupId == group.id
          && $0.accounts.by(id: memberB.id)?.groupId == group.id
      },
      description: "members joined")

    await stores.accountStore.drainPendingEmissions()
    try await SidebarDropDispatch.reorderMembers(
      groupId: group.id,
      sourceAccountId: UUID(),
      insertionIndex: 0,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    let emitted = await stores.accountStore.didEmitWithin(timeout: .milliseconds(200))
    #expect(!emitted, "accountStore should not emit on unknown-id reorder")
    let memberOrder = stores.accountStore.accounts.ordered
      .filter { $0.groupId == group.id }
      .sorted { $0.position < $1.position }
      .map(\.id)
    #expect(memberOrder == [memberA.id, memberB.id])
  }

  @Test("reorderMembers adds a standalone source to the target group at the insertion index")
  func reorderMembersAddsStandaloneToGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let standalone = SidebarDropDispatchTestSupport.bankAccount(
      name: "Standalone", position: 0)
    let memberA = SidebarDropDispatchTestSupport.bankAccount(name: "MA", position: 1)
    let memberB = SidebarDropDispatchTestSupport.bankAccount(name: "MB", position: 2)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [standalone, memberA, memberB], in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      joining: memberA, and: memberB, name: "G",
      accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: memberA.id)?.groupId == group.id },
      description: "group seeded")

    try await SidebarDropDispatch.reorderMembers(
      groupId: group.id,
      sourceAccountId: standalone.id,
      insertionIndex: 1,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: standalone.id)?.groupId == group.id },
      description: "standalone joined group")
    let members = stores.accountStore.accounts.ordered
      .filter { $0.groupId == group.id }
      .sorted { $0.position < $1.position }
      .map(\.id)
    #expect(members == [memberA.id, standalone.id, memberB.id])
  }

  @Test("reorderMembers moves source from group A to group B; A keeps remaining members")
  func reorderMembersCrossGroupKeepsOldGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let accA1 = SidebarDropDispatchTestSupport.bankAccount(name: "A1", position: 0)
    let accA2 = SidebarDropDispatchTestSupport.bankAccount(name: "A2", position: 1)
    let accB1 = SidebarDropDispatchTestSupport.bankAccount(name: "B1", position: 2)
    let accB2 = SidebarDropDispatchTestSupport.bankAccount(name: "B2", position: 3)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [accA1, accA2, accB1, accB2], in: database, backend: backend)

    let groupA = try await stores.accountGroupStore.createGroup(
      joining: accA1, and: accA2, name: "A", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: accA1.id)?.groupId == groupA.id },
      description: "group A seeded")
    let groupB = try await stores.accountGroupStore.createGroup(
      joining: accB1, and: accB2, name: "B", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: accB1.id)?.groupId == groupB.id },
      description: "group B seeded")

    try await SidebarDropDispatch.reorderMembers(
      groupId: groupB.id,
      sourceAccountId: accA1.id,
      insertionIndex: 1,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: accA1.id)?.groupId == groupB.id },
      description: "accA1 now in group B")
    #expect(stores.accountStore.accounts.by(id: accA2.id)?.groupId == groupA.id)
    #expect(stores.accountGroupStore.by(id: groupA.id) != nil)
    let bMembers = stores.accountStore.accounts.ordered
      .filter { $0.groupId == groupB.id }
      .sorted { $0.position < $1.position }
      .map(\.id)
    #expect(bMembers == [accB1.id, accA1.id, accB2.id])
  }

  @Test("reorderMembers deletes empty old group when source was its sole member")
  func reorderMembersDeletesEmptyOldGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let aSole = SidebarDropDispatchTestSupport.bankAccount(name: "ASole", position: 0)
    let accB1 = SidebarDropDispatchTestSupport.bankAccount(name: "B1", position: 1)
    let accB2 = SidebarDropDispatchTestSupport.bankAccount(name: "B2", position: 2)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [aSole, accB1, accB2], in: database, backend: backend)

    let groupA = try await stores.accountGroupStore.createGroup(
      from: aSole, name: "A", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: aSole.id)?.groupId == groupA.id },
      description: "aSole joined A")
    let groupB = try await stores.accountGroupStore.createGroup(
      joining: accB1, and: accB2, name: "B", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: accB1.id)?.groupId == groupB.id },
      description: "group B seeded")

    try await SidebarDropDispatch.reorderMembers(
      groupId: groupB.id,
      sourceAccountId: aSole.id,
      insertionIndex: 1,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: aSole.id)?.groupId == groupB.id },
      description: "aSole now in group B")
    try await stores.accountGroupStore.waitForNextEmission(
      matching: { $0.by(id: groupA.id) == nil },
      description: "group A auto-deleted")
  }
}
