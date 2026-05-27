import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `SidebarDropDispatch.reorderRoot` /
/// `SidebarDropDispatch.reorderMembers`. Lives in its own file
/// alongside `SidebarDropDispatchTests` (drop-onto) so each file stays
/// focused; shared fixtures live in
/// `SidebarDropDispatchTestSupport.swift`.
@Suite("SidebarDropDispatch — reorder")
@MainActor
struct SidebarDropDispatchReorderTests {

  // MARK: - reorderRoot

  @Test("reorderRoot moves a standalone account ahead of another")
  func reorderRootMovesAccount() async throws {
    let (backend, database) = try TestBackend.create()
    let first = SidebarDropDispatchTestSupport.bankAccount(name: "First", position: 0)
    let second = SidebarDropDispatchTestSupport.bankAccount(name: "Second", position: 1)
    let third = SidebarDropDispatchTestSupport.bankAccount(name: "Third", position: 2)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [first, second, third], in: database, backend: backend)

    await SidebarDropDispatch.reorderRoot(
      dragged: DraggableSidebarItem(kind: .account, id: third.id),
      insertionIndex: 0,
      bucket: .current,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: third.id)?.position == 0 },
      description: "third now first")
    let order = stores.accountStore.accounts.ordered
      .filter { $0.bucket == .current && $0.groupId == nil }
      .sorted { $0.position < $1.position }
      .map(\.id)
    #expect(order == [third.id, first.id, second.id])
  }

  @Test("reorderRoot moves a group ahead of a standalone account")
  func reorderRootMovesGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let standalone = SidebarDropDispatchTestSupport.bankAccount(
      name: "Standalone", position: 0)
    let memberA = SidebarDropDispatchTestSupport.bankAccount(name: "MemberA", position: 1)
    let memberB = SidebarDropDispatchTestSupport.bankAccount(name: "MemberB", position: 2)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [standalone, memberA, memberB], in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      joining: memberA, and: memberB, name: "G",
      accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: {
        $0.accounts.by(id: memberA.id)?.groupId == group.id
          && $0.accounts.by(id: memberB.id)?.groupId == group.id
      },
      description: "members joined")

    // After the create the bucket entries (tie-break: account first on
    // equal position) are [standalone@0, group@0]. Drop the group at
    // index 0 to put it ahead of the standalone.
    await SidebarDropDispatch.reorderRoot(
      dragged: DraggableSidebarItem(kind: .group, id: group.id),
      insertionIndex: 0,
      bucket: .current,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountGroupStore.waitForNextEmission(
      matching: {
        let groupPos = $0.by(id: group.id)?.position ?? -1
        let standalonePos =
          stores.accountStore.accounts.by(id: standalone.id)?.position ?? -1
        return groupPos < standalonePos
      },
      description: "group now positioned ahead of standalone")
  }

  @Test("reorderRoot clamps insertion index past the end")
  func reorderRootClampsEnd() async throws {
    let (backend, database) = try TestBackend.create()
    let first = SidebarDropDispatchTestSupport.bankAccount(name: "First", position: 0)
    let second = SidebarDropDispatchTestSupport.bankAccount(name: "Second", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [first, second], in: database, backend: backend)

    await SidebarDropDispatch.reorderRoot(
      dragged: DraggableSidebarItem(kind: .account, id: first.id),
      insertionIndex: 99,
      bucket: .current,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountStore.waitForNextEmission(
      matching: {
        ($0.accounts.by(id: first.id)?.position ?? -1)
          > ($0.accounts.by(id: second.id)?.position ?? -1)
      },
      description: "first clamped to after second")
  }

  @Test("reorderRoot is a no-op when the dragged id is unknown")
  func reorderRootRejectsMissing() async throws {
    let (backend, database) = try TestBackend.create()
    let first = SidebarDropDispatchTestSupport.bankAccount(name: "First", position: 0)
    let second = SidebarDropDispatchTestSupport.bankAccount(name: "Second", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [first, second], in: database, backend: backend)

    let beforeFirst = first.position
    let beforeSecond = second.position
    await SidebarDropDispatch.reorderRoot(
      dragged: DraggableSidebarItem(kind: .account, id: UUID()),
      insertionIndex: 0,
      bucket: .current,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try? await Task.sleep(for: .milliseconds(50))
    #expect(stores.accountStore.accounts.by(id: first.id)?.position == beforeFirst)
    #expect(stores.accountStore.accounts.by(id: second.id)?.position == beforeSecond)
  }

  // MARK: - reorderMembers

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
    await SidebarDropDispatch.reorderMembers(
      groupId: group.id,
      sourceAccountId: outsider.id,
      insertionIndex: 0,
      accountStore: stores.accountStore)

    try? await Task.sleep(for: .milliseconds(50))
    #expect(stores.accountStore.accounts.by(id: outsider.id)?.position == outsiderBefore.position)
    #expect(stores.accountStore.accounts.by(id: outsider.id)?.groupId == nil)
    let memberOrder = stores.accountStore.accounts.ordered
      .filter { $0.groupId == group.id }
      .sorted { $0.position < $1.position }
      .map(\.id)
    #expect(memberOrder == [memberA.id, memberB.id])
  }
}
