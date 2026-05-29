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

    await SidebarDropDispatch.reorderMembers(
      groupId: group.id,
      sourceAccountId: memberC.id,
      insertionIndex: 0,
      accountStore: stores.accountStore)

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

    await SidebarDropDispatch.reorderMembers(
      groupId: group.id,
      sourceAccountId: memberA.id,
      insertionIndex: 99,
      accountStore: stores.accountStore)

    try await stores.accountStore.waitForNextEmission(
      matching: {
        ($0.accounts.by(id: memberA.id)?.position ?? -1)
          > ($0.accounts.by(id: memberB.id)?.position ?? -1)
      },
      description: "A clamped to end")
  }

  @Test("reorderMembers is a no-op when the source is not in the group")
  func reorderMembersRejectsForeignMember() async throws {
    let (backend, database) = try TestBackend.create()
    let memberA = SidebarDropDispatchTestSupport.bankAccount(name: "A", position: 0)
    let memberB = SidebarDropDispatchTestSupport.bankAccount(name: "B", position: 1)
    let outsider = SidebarDropDispatchTestSupport.bankAccount(name: "Outsider", position: 2)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [memberA, memberB, outsider], in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      joining: memberA, and: memberB, name: "G",
      accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: {
        $0.accounts.by(id: memberA.id)?.groupId == group.id
          && $0.accounts.by(id: memberB.id)?.groupId == group.id
      },
      description: "members joined")

    let outsiderBefore = try #require(stores.accountStore.accounts.by(id: outsider.id))
    await stores.accountStore.drainPendingEmissions()
    await SidebarDropDispatch.reorderMembers(
      groupId: group.id,
      sourceAccountId: outsider.id,
      insertionIndex: 0,
      accountStore: stores.accountStore)

    let emitted = await stores.accountStore.didEmitWithin(timeout: .milliseconds(200))
    #expect(!emitted, "accountStore should not emit on foreign-member reorder")
    #expect(stores.accountStore.accounts.by(id: outsider.id)?.position == outsiderBefore.position)
    #expect(stores.accountStore.accounts.by(id: outsider.id)?.groupId == nil)
    let memberOrder = stores.accountStore.accounts.ordered
      .filter { $0.groupId == group.id }
      .sorted { $0.position < $1.position }
      .map(\.id)
    #expect(memberOrder == [memberA.id, memberB.id])
  }
}
