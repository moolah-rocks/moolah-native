import Foundation
import GRDB
import Testing

@testable import Moolah

/// Tests for `SidebarDropDispatch.dropOntoAccount` /
/// `SidebarDropDispatch.dropOntoGroup`.
///
/// The reorder primitives have their own suite
/// (`SidebarDropDispatchReorderTests`) so this file stays focused on
/// the membership-change policy gate (same-bucket, no self-drop, no
/// re-add). Shared fixtures live in
/// `SidebarDropDispatchTestSupport.swift`.
@Suite("SidebarDropDispatch — drop onto")
@MainActor
struct SidebarDropDispatchTests {

  // MARK: - dropOntoAccount

  @Test("dropOntoAccount on two standalone same-bucket accounts creates a 2-member group")
  func dropOntoAccountCreatesGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let target = SidebarDropDispatchTestSupport.bankAccount(name: "Target", position: 0)
    let source = SidebarDropDispatchTestSupport.bankAccount(name: "Source", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [target, source], in: database, backend: backend)

    let created = try await SidebarDropDispatch.dropOntoAccount(
      sourceId: source.id,
      targetId: target.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    let createdGroup = try #require(created)
    #expect(createdGroup.bucket == .current)
    try await stores.accountStore.waitForNextEmission(
      matching: {
        $0.accounts.by(id: target.id)?.groupId == createdGroup.id
          && $0.accounts.by(id: source.id)?.groupId == createdGroup.id
      },
      description: "both accounts joined the new group")
    try await stores.groupUIStateStore.waitForNextEmission(
      matching: { $0.expandedGroupIds.contains(createdGroup.id) },
      description: "new group auto-expanded")
  }

  @Test("dropOntoAccount where target is already a member adds source to target's group")
  func dropOntoMemberJoinsGroup() async throws {
    let (backend, database) = try TestBackend.create()
    let seedMember = SidebarDropDispatchTestSupport.bankAccount(name: "Seed", position: 0)
    let target = SidebarDropDispatchTestSupport.bankAccount(name: "Target", position: 1)
    let source = SidebarDropDispatchTestSupport.bankAccount(name: "Source", position: 2)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [seedMember, target, source], in: database, backend: backend)

    let preexisting = try await stores.accountGroupStore.createGroup(
      joining: seedMember, and: target, name: "Pre",
      accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: target.id)?.groupId == preexisting.id },
      description: "target observed as member")

    let result = try await SidebarDropDispatch.dropOntoAccount(
      sourceId: source.id,
      targetId: target.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    #expect(result == nil, "no new group when joining target's existing group")
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: source.id)?.groupId == preexisting.id },
      description: "source joined preexisting group")
  }

  @Test("dropOntoAccount with cross-bucket source is a no-op")
  func dropOntoAccountRejectsCrossBucket() async throws {
    let (backend, database) = try TestBackend.create()
    let target = SidebarDropDispatchTestSupport.bankAccount(name: "Target", position: 0)
    let source = Account(
      name: "InvestSource", type: .investment,
      instrument: .defaultTestInstrument, position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [target, source], in: database, backend: backend)

    let result = try await SidebarDropDispatch.dropOntoAccount(
      sourceId: source.id,
      targetId: target.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    #expect(result == nil)
    #expect(stores.accountStore.accounts.by(id: target.id)?.groupId == nil)
    #expect(stores.accountStore.accounts.by(id: source.id)?.groupId == nil)
    #expect(stores.accountGroupStore.groups.isEmpty)
  }

  @Test("dropOntoAccount with self-drop is a no-op")
  func dropOntoAccountRejectsSelf() async throws {
    let (backend, database) = try TestBackend.create()
    let account = SidebarDropDispatchTestSupport.bankAccount(name: "Solo", position: 0)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [account], in: database, backend: backend)

    let result = try await SidebarDropDispatch.dropOntoAccount(
      sourceId: account.id,
      targetId: account.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    #expect(result == nil)
    #expect(stores.accountGroupStore.groups.isEmpty)
  }

  @Test("dropOntoAccount with unknown source is a no-op")
  func dropOntoAccountRejectsMissingSource() async throws {
    let (backend, database) = try TestBackend.create()
    let target = SidebarDropDispatchTestSupport.bankAccount(name: "Target", position: 0)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [target], in: database, backend: backend)

    let result = try await SidebarDropDispatch.dropOntoAccount(
      sourceId: UUID(),
      targetId: target.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    #expect(result == nil)
    #expect(stores.accountGroupStore.groups.isEmpty)
  }

  // MARK: - dropOntoGroup

  @Test("dropOntoGroup adds the source account to the group")
  func dropOntoGroupAddsMember() async throws {
    let (backend, database) = try TestBackend.create()
    let seed = SidebarDropDispatchTestSupport.bankAccount(name: "Seed", position: 0)
    let source = SidebarDropDispatchTestSupport.bankAccount(name: "Source", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [seed, source], in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      from: seed, name: "G", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: seed.id)?.groupId == group.id },
      description: "seed member observed")

    try await SidebarDropDispatch.dropOntoGroup(
      sourceId: source.id,
      groupId: group.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: source.id)?.groupId == group.id },
      description: "source joined target group")
    #expect(stores.accountStore.accounts.by(id: source.id)?.position == 1)
    try await stores.groupUIStateStore.waitForNextEmission(
      matching: { $0.expandedGroupIds.contains(group.id) },
      description: "target group auto-expanded after drop")
  }

  @Test("dropOntoGroup auto-expands the target group so the new member is visible")
  func dropOntoGroupAutoExpands() async throws {
    let (backend, database) = try TestBackend.create()
    let seed = SidebarDropDispatchTestSupport.bankAccount(name: "Seed", position: 0)
    let source = SidebarDropDispatchTestSupport.bankAccount(name: "Source", position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [seed, source], in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      from: seed, name: "G", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: seed.id)?.groupId == group.id },
      description: "seed member observed")
    // Collapse the target group so the auto-expand effect is observable.
    await stores.groupUIStateStore.setExpanded(false, for: group.id)
    try await stores.groupUIStateStore.waitForNextEmission(
      matching: { !$0.expandedGroupIds.contains(group.id) },
      description: "target group starts collapsed")

    try await SidebarDropDispatch.dropOntoGroup(
      sourceId: source.id,
      groupId: group.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    try await stores.groupUIStateStore.waitForNextEmission(
      matching: { $0.expandedGroupIds.contains(group.id) },
      description: "target group auto-expanded after drop")
    #expect(stores.groupUIStateStore.expandedGroupIds.contains(group.id))
  }

  @Test("dropOntoGroup is a no-op when the account is already in the target group")
  func dropOntoGroupRejectsReAdd() async throws {
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
      description: "both members observed")

    let originalA = try #require(stores.accountStore.accounts.by(id: memberA.id))
    await stores.accountStore.drainPendingEmissions()
    try await SidebarDropDispatch.dropOntoGroup(
      sourceId: memberA.id,
      groupId: group.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    let emitted = await stores.accountStore.didEmitWithin(timeout: .milliseconds(200))
    #expect(!emitted, "accountStore should not emit on rejected re-add")
    #expect(stores.accountStore.accounts.by(id: memberA.id)?.position == originalA.position)
    #expect(stores.accountStore.accounts.by(id: memberA.id)?.groupId == group.id)
  }

  @Test("dropOntoGroup rejects cross-bucket")
  func dropOntoGroupRejectsCrossBucket() async throws {
    let (backend, database) = try TestBackend.create()
    let seed = SidebarDropDispatchTestSupport.bankAccount(name: "Seed", position: 0)
    let crossSource = Account(
      name: "Invest", type: .investment,
      instrument: .defaultTestInstrument, position: 1)
    let stores = try await SidebarDropDispatchTestSupport.makeStores(
      seedAccounts: [seed, crossSource], in: database, backend: backend)

    let group = try await stores.accountGroupStore.createGroup(
      from: seed, name: "Current Group", accountStore: stores.accountStore)
    try await stores.accountStore.waitForNextEmission(
      matching: { $0.accounts.by(id: seed.id)?.groupId == group.id },
      description: "seed observed in group")

    await stores.accountStore.drainPendingEmissions()
    try await SidebarDropDispatch.dropOntoGroup(
      sourceId: crossSource.id,
      groupId: group.id,
      accountStore: stores.accountStore,
      accountGroupStore: stores.accountGroupStore,
      groupUIStateStore: stores.groupUIStateStore)

    let emitted = await stores.accountStore.didEmitWithin(timeout: .milliseconds(200))
    #expect(!emitted, "accountStore should not emit on rejected cross-bucket drop")
    #expect(stores.accountStore.accounts.by(id: crossSource.id)?.groupId == nil)
  }
}
