import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `SidebarDropDispatch.dropOntoAccount` cross-group membership
/// transitions — source leaves its old group and joins the target's group.
/// Shared fixtures live in `SidebarDropDispatchTestSupport.swift`.
@Suite("SidebarDropDispatch — cross-group drops")
@MainActor
struct SidebarDropDispatchCrossGroupTests {

  @Test("dropOntoAccount moves source from group A to group B; A keeps members")
  func dropOntoAccountCrossGroupKeepsOldGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let aMember1 = SidebarDropDispatchTestSupport.bankAccount(name: "A1", position: 0)
    let aMember2 = SidebarDropDispatchTestSupport.bankAccount(name: "A2", position: 1)
    let bMember = SidebarDropDispatchTestSupport.bankAccount(name: "B1", position: 2)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [aMember1, aMember2, bMember], in: database, backend: backend)

    let groupA = try await stores.accountGroupStore.createGroup(
      joining: aMember1, and: aMember2, name: "A",
      accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: {
        $0.accounts.by(id: aMember1.id)?.groupId == groupA.id
          && $0.accounts.by(id: aMember2.id)?.groupId == groupA.id
      },
      description: "group A members joined")

    let groupB = try await stores.accountGroupStore.createGroup(
      from: bMember, name: "B", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: bMember.id)?.groupId == groupB.id },
      description: "B single-member group seeded")

    _ = try await SidebarDropDispatch.dropOntoAccount(
      sourceId: aMember1.id,
      targetId: bMember.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: aMember1.id)?.groupId == groupB.id },
      description: "aMember1 now in groupB")
    #expect(stores.accountStore.accounts.by(id: aMember2.id)?.groupId == groupA.id)
    #expect(stores.accountGroupStore.by(id: groupA.id) != nil)
  }

  @Test("dropOntoAccount onto cross-group member deletes empty old group")
  func dropOntoAccountCrossGroupDeletesEmptyOldGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let aSole = SidebarDropDispatchTestSupport.bankAccount(name: "ASole", position: 0)
    let bMember = SidebarDropDispatchTestSupport.bankAccount(name: "B1", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [aSole, bMember], in: database, backend: backend)

    let groupA = try await stores.accountGroupStore.createGroup(
      from: aSole, name: "A", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: aSole.id)?.groupId == groupA.id },
      description: "aSole joined group A")
    let groupB = try await stores.accountGroupStore.createGroup(
      from: bMember, name: "B", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: bMember.id)?.groupId == groupB.id },
      description: "bMember joined group B")

    _ = try await SidebarDropDispatch.dropOntoAccount(
      sourceId: aSole.id,
      targetId: bMember.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: aSole.id)?.groupId == groupB.id },
      description: "aSole now in groupB")
    try await stores.accountGroupStore.waitForNextEmission(
      matching: { $0.by(id: groupA.id) == nil },
      description: "group A auto-deleted")
  }

  @Test("dropOntoGroup from a sole-member-group deletes the old group")
  func dropOntoGroupCrossGroupDeletesEmptyOldGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let aSole = SidebarDropDispatchTestSupport.bankAccount(name: "ASole", position: 0)
    let bMember = SidebarDropDispatchTestSupport.bankAccount(name: "B1", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [aSole, bMember], in: database, backend: backend)

    let groupA = try await stores.accountGroupStore.createGroup(
      from: aSole, name: "A", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: aSole.id)?.groupId == groupA.id },
      description: "aSole joined group A")
    let groupB = try await stores.accountGroupStore.createGroup(
      from: bMember, name: "B", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: bMember.id)?.groupId == groupB.id },
      description: "bMember joined group B")

    try await SidebarDropDispatch.dropOntoGroup(
      sourceId: aSole.id,
      groupId: groupB.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: aSole.id)?.groupId == groupB.id },
      description: "aSole now in groupB")
    try await stores.accountGroupStore.waitForNextEmission(
      matching: { $0.by(id: groupA.id) == nil },
      description: "group A auto-deleted")
  }
}
