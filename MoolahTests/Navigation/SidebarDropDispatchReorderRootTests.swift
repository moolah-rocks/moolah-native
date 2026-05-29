import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `SidebarDropDispatch.reorderRoot`. Shared fixtures live in
/// `SidebarDropDispatchTestSupport.swift`.
@Suite("SidebarDropDispatch — reorderRoot")
@MainActor
struct SidebarDropDispatchReorderRootTests {

  @Test("reorderRoot moves a standalone account ahead of another")
  func reorderRootMovesAccount() async throws {
    let (backend, database) = try TestBackend.create()
    let first = SidebarDropDispatchTestSupport.bankAccount(name: "First", position: 0)
    let second = SidebarDropDispatchTestSupport.bankAccount(name: "Second", position: 1)
    let third = SidebarDropDispatchTestSupport.bankAccount(name: "Third", position: 2)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [first, second, third], in: database, backend: backend)

    try await SidebarDropDispatch.reorderRoot(
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
    try await SidebarDropDispatch.reorderRoot(
      dragged: DraggableSidebarItem(kind: .group, id: group.id),
      insertionIndex: 0,
      bucket: .current,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    // `reorderRoot` writes to BOTH stores: the group's new position on
    // `accountGroupStore`, and the shifted standalone's position on
    // `accountStore`. The original waiter parked on `accountGroupStore`
    // and read `accountStore` inside the predicate — if the watched
    // store emitted first (still showing the pre-shift state on the
    // other), the predicate was false, no further emission came on
    // the watched store, and the waiter timed out (#1000). Wait on
    // both stores' writes individually, then assert the cross-store
    // invariant synchronously.
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: standalone.id)?.position == 1 },
      description: "standalone shifted to position 1")
    try await stores.accountGroupStore.waitForNextEmission(
      matching: { $0.by(id: group.id)?.position == 0 },
      description: "group landed at position 0")
    let groupPos = stores.accountGroupStore.by(id: group.id)?.position
    let standalonePos = stores.accountStore.accounts.by(id: standalone.id)?.position
    #expect((groupPos ?? -1) < (standalonePos ?? -1))
  }

  @Test("reorderRoot clamps insertion index past the end")
  func reorderRootClampsEnd() async throws {
    let (backend, database) = try TestBackend.create()
    let first = SidebarDropDispatchTestSupport.bankAccount(name: "First", position: 0)
    let second = SidebarDropDispatchTestSupport.bankAccount(name: "Second", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [first, second], in: database, backend: backend)

    try await SidebarDropDispatch.reorderRoot(
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

  @Test("reorderRoot preserves the standalone/group interleave (3-entry mixed)")
  func reorderRootPreservesInterleave() async throws {
    let (backend, database) = try TestBackend.create()
    let standaloneA = SidebarDropDispatchTestSupport.bankAccount(
      name: "StandaloneA", position: 0)
    let memberA = SidebarDropDispatchTestSupport.bankAccount(name: "MemberA", position: 1)
    let memberB = SidebarDropDispatchTestSupport.bankAccount(name: "MemberB", position: 2)
    let standaloneB = SidebarDropDispatchTestSupport.bankAccount(
      name: "StandaloneB", position: 3)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [standaloneA, memberA, memberB, standaloneB],
      in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      joining: memberA, and: memberB, name: "G",
      accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: {
        $0.accounts.by(id: memberA.id)?.groupId == group.id
          && $0.accounts.by(id: memberB.id)?.groupId == group.id
      },
      description: "members joined")

    // Drag the group to the bottom of the bucket (insertionIndex 2 in
    // the 3-entry root: [standaloneA, group, standaloneB] → after the
    // group moves to index 2: [standaloneA, standaloneB, group]).
    try await SidebarDropDispatch.reorderRoot(
      dragged: DraggableSidebarItem(kind: .group, id: group.id),
      insertionIndex: 2,
      bucket: .current,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountGroupStore.waitForNextEmission(
      matching: { $0.by(id: group.id)?.position == 2 },
      description: "group walked to position 2")

    // Per-entry walk-index writes — not a contiguous 0..N-1 collapse —
    // so each entry's absolute position matches its walk-order index.
    let postStandaloneA = try #require(
      stores.accountStore.accounts.by(id: standaloneA.id))
    let postStandaloneB = try #require(
      stores.accountStore.accounts.by(id: standaloneB.id))
    let postGroup = try #require(stores.accountGroupStore.by(id: group.id))
    #expect(postStandaloneA.position == 0)
    #expect(postStandaloneB.position == 1)
    #expect(postGroup.position == 2)
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
    await stores.accountStore.drainPendingEmissions()
    try await SidebarDropDispatch.reorderRoot(
      dragged: DraggableSidebarItem(kind: .account, id: UUID()),
      insertionIndex: 0,
      bucket: .current,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    let emitted = await stores.accountStore.didEmitWithin(timeout: .milliseconds(200))
    #expect(!emitted, "accountStore should not emit on unknown-id reorder")
    #expect(stores.accountStore.accounts.by(id: first.id)?.position == beforeFirst)
    #expect(stores.accountStore.accounts.by(id: second.id)?.position == beforeSecond)
  }

  @Test("reorderRoot clears groupId when source is a member; old group keeps its remaining member")
  func reorderRootClearsGroupIdAndKeepsNonEmptyOldGroup() async throws {
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

    // Drop memberA at root insertion index 0 (ahead of standalone + group).
    try await SidebarDropDispatch.reorderRoot(
      dragged: DraggableSidebarItem(kind: .account, id: memberA.id),
      insertionIndex: 0,
      bucket: .current,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: memberA.id)?.groupId == nil },
      description: "memberA back to root")
    #expect(stores.accountStore.accounts.by(id: memberB.id)?.groupId == group.id)
    #expect(stores.accountGroupStore.by(id: group.id) != nil)
  }

  @Test("reorderRoot deletes the old group when the source was its sole member")
  func reorderRootDeletesEmptyOldGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let standalone = SidebarDropDispatchTestSupport.bankAccount(
      name: "Standalone", position: 0)
    let soleMember = SidebarDropDispatchTestSupport.bankAccount(
      name: "Sole", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [standalone, soleMember], in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      from: soleMember, name: "Lonely", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: soleMember.id)?.groupId == group.id },
      description: "soleMember joined group")

    try await SidebarDropDispatch.reorderRoot(
      dragged: DraggableSidebarItem(kind: .account, id: soleMember.id),
      insertionIndex: 0,
      bucket: .current,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: soleMember.id)?.groupId == nil },
      description: "soleMember back to root")
    try await stores.accountGroupStore.waitForNextEmission(
      matching: { $0.by(id: group.id) == nil },
      description: "lonely group auto-deleted")
  }
}
