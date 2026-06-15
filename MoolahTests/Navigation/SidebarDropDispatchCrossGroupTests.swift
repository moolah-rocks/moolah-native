import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `SidebarDropDispatch` cross-group membership transitions —
/// covers `dropOntoAccount` and `dropOntoGroup` cases where the source
/// leaves its old group to join the destination's. Shared fixtures live
/// in `SidebarDropDispatchTestSupport.swift`.
///
/// Post-mutation state is asserted with `expectEventually` (polls the
/// exact asserted expression) rather than `waitForNextEmission` (awaits
/// one tick, then reads). A store's `observationTicks` is a
/// single-consumer `AsyncStream`; when one test feeds two sequential
/// waits to the same store, the second iterator can miss the tick that
/// carries the awaited state and then block until the deadline even
/// though the steady-state value is already correct. Polling the value
/// sidesteps the stream entirely.
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
    await expectEventually("group A members joined") {
      stores.accountStore.accounts.by(id: aMember1.id)?.groupId == groupA.id
        && stores.accountStore.accounts.by(id: aMember2.id)?.groupId == groupA.id
    }

    let groupB = try await stores.accountGroupStore.createGroup(
      from: bMember, name: "B", accountStore: stores.accountStore)
    await expectEventually("B single-member group seeded") {
      stores.accountStore.accounts.by(id: bMember.id)?.groupId == groupB.id
    }

    _ = try await SidebarDropDispatch.dropOntoAccount(
      sourceId: aMember1.id,
      targetId: bMember.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    await expectEventually("aMember1 moved to groupB; groupA survives with aMember2") {
      stores.accountStore.accounts.by(id: aMember1.id)?.groupId == groupB.id
        && stores.accountStore.accounts.by(id: aMember2.id)?.groupId == groupA.id
        && stores.accountGroupStore.by(id: groupA.id) != nil
    }
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
    await expectEventually("aSole joined group A") {
      stores.accountStore.accounts.by(id: aSole.id)?.groupId == groupA.id
    }
    let groupB = try await stores.accountGroupStore.createGroup(
      from: bMember, name: "B", accountStore: stores.accountStore)
    await expectEventually("bMember joined group B") {
      stores.accountStore.accounts.by(id: bMember.id)?.groupId == groupB.id
    }

    _ = try await SidebarDropDispatch.dropOntoAccount(
      sourceId: aSole.id,
      targetId: bMember.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    await expectEventually("aSole now in groupB and group A auto-deleted") {
      stores.accountStore.accounts.by(id: aSole.id)?.groupId == groupB.id
        && stores.accountGroupStore.by(id: groupA.id) == nil
    }
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
    await expectEventually("aSole joined group A") {
      stores.accountStore.accounts.by(id: aSole.id)?.groupId == groupA.id
    }
    let groupB = try await stores.accountGroupStore.createGroup(
      from: bMember, name: "B", accountStore: stores.accountStore)
    await expectEventually("bMember joined group B") {
      stores.accountStore.accounts.by(id: bMember.id)?.groupId == groupB.id
    }

    try await SidebarDropDispatch.dropOntoGroup(
      sourceId: aSole.id,
      groupId: groupB.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    await expectEventually("aSole now in groupB and group A auto-deleted") {
      stores.accountStore.accounts.by(id: aSole.id)?.groupId == groupB.id
        && stores.accountGroupStore.by(id: groupA.id) == nil
    }
  }
}
