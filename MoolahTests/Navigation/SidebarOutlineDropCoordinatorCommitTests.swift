#if os(macOS)
  import Foundation
  import GRDB
  import Testing

  @testable import Moolah

  /// Covers `SidebarOutlineDropCoordinator.commit(_:bucket:)` —
  /// dispatch of each `DropOutcome` case to the matching
  /// `SidebarDropDispatch` entry point, plus the `onCreatedGroup`
  /// callback when `dropOntoAccount` creates a new group.
  @Suite("SidebarOutlineDropCoordinator — commit")
  @MainActor
  struct SidebarOutlineDropCoordinatorCommitTests {
    private typealias DispatchSupport = SidebarDropDispatchTestSupport

    @Test("commit .deny is a no-op")
    func commitDeny() async throws {
      let (backend, database) = try TestBackend.create()
      let stores = try await DispatchSupport.makeStores(
        seedAccounts: [], in: database, backend: backend)
      let coordinator = SidebarOutlineDropCoordinator(
        accountStore: stores.accountStore,
        accountGroupStore: stores.accountGroupStore,
        groupUIStateStore: stores.groupUIStateStore)

      let result = await coordinator.commit(.deny, bucket: .current)

      #expect(result == false)
    }

    @Test("commit .dropOntoAccount creates group and fires onCreatedGroup")
    func commitDropOntoAccount() async throws {
      let (backend, database) = try TestBackend.create()
      let target = DispatchSupport.bankAccount(name: "Target", position: 0)
      let source = DispatchSupport.bankAccount(name: "Source", position: 1)
      let stores = try await DispatchSupport.makeStores(
        seedAccounts: [target, source], in: database, backend: backend)
      let coordinator = SidebarOutlineDropCoordinator(
        accountStore: stores.accountStore,
        accountGroupStore: stores.accountGroupStore,
        groupUIStateStore: stores.groupUIStateStore)

      var captured: AccountGroup?
      coordinator.onCreatedGroup = { captured = $0 }

      let result = await coordinator.commit(
        .dropOntoAccount(sourceAccountId: source.id, targetAccountId: target.id),
        bucket: .current)

      #expect(result == true)
      let created = try #require(captured)
      try await stores.accountStore.waitForNextEmission(
        matching: {
          $0.accounts.by(id: target.id)?.groupId == created.id
            && $0.accounts.by(id: source.id)?.groupId == created.id
        },
        description: "both accounts joined the new group")
    }

    @Test("commit .addToGroup adds source to existing group")
    func commitAddToGroup() async throws {
      let (backend, database) = try TestBackend.create()
      let seedMember = DispatchSupport.bankAccount(name: "Seed", position: 0)
      let source = DispatchSupport.bankAccount(name: "Source", position: 1)
      let stores = try await DispatchSupport.makeStores(
        seedAccounts: [seedMember, source], in: database, backend: backend)
      let group = try await stores.accountGroupStore.createGroup(
        from: seedMember, name: "G", accountStore: stores.accountStore)
      try await stores.accountStore.waitForNextEmission(
        matching: { $0.accounts.by(id: seedMember.id)?.groupId == group.id },
        description: "seed member observed")
      // Collapse the target group so the auto-expand effect is observable.
      await stores.groupUIStateStore.setExpanded(false, for: group.id)
      try await stores.groupUIStateStore.waitForNextEmission(
        matching: { !$0.expandedGroupIds.contains(group.id) },
        description: "target group starts collapsed")
      let coordinator = SidebarOutlineDropCoordinator(
        accountStore: stores.accountStore,
        accountGroupStore: stores.accountGroupStore,
        groupUIStateStore: stores.groupUIStateStore)

      let result = await coordinator.commit(
        .addToGroup(sourceAccountId: source.id, groupId: group.id),
        bucket: .current)

      #expect(result == true)
      try await stores.accountStore.waitForNextEmission(
        matching: { $0.accounts.by(id: source.id)?.groupId == group.id },
        description: "source joined existing group")
      try await stores.groupUIStateStore.waitForNextEmission(
        matching: { $0.expandedGroupIds.contains(group.id) },
        description: "target group auto-expanded after commit")
    }

    @Test("commit .reorderRoot reassigns positions")
    func commitReorderRoot() async throws {
      let (backend, database) = try TestBackend.create()
      let accA = DispatchSupport.bankAccount(name: "A", position: 0)
      let accB = DispatchSupport.bankAccount(name: "B", position: 1)
      let accC = DispatchSupport.bankAccount(name: "C", position: 2)
      let stores = try await DispatchSupport.makeStores(
        seedAccounts: [accA, accB, accC], in: database, backend: backend)
      let coordinator = SidebarOutlineDropCoordinator(
        accountStore: stores.accountStore,
        accountGroupStore: stores.accountGroupStore,
        groupUIStateStore: stores.groupUIStateStore)

      // Move 'A' (position 0) to the pre-removal insertion slot after C.
      let result = await coordinator.commit(
        .reorderRoot(
          item: DraggableSidebarItem(kind: .account, id: accA.id),
          insertionIndex: 3),
        bucket: .current)

      #expect(result == true)
      try await stores.accountStore.waitForNextEmission(
        matching: {
          let ordered = $0.accounts.ordered
            .filter { $0.bucket == .current }
            .sorted(by: { $0.position < $1.position })
            .map(\.id)
          return ordered == [accB.id, accC.id, accA.id]
        },
        description: "root reorder applied")
    }

    @Test("commit .reorderMembers reorders within a group")
    func commitReorderMembers() async throws {
      let (backend, database) = try TestBackend.create()
      let accA = DispatchSupport.bankAccount(name: "A", position: 0)
      let accB = DispatchSupport.bankAccount(name: "B", position: 1)
      let accC = DispatchSupport.bankAccount(name: "C", position: 2)
      let stores = try await DispatchSupport.makeStores(
        seedAccounts: [accA, accB, accC], in: database, backend: backend)
      let group = try await stores.accountGroupStore.createGroup(
        joining: accA, and: accB, name: "G", accountStore: stores.accountStore)
      try await stores.accountStore.waitForNextEmission(
        matching: { $0.accounts.by(id: accB.id)?.groupId == group.id },
        description: "members observed")
      try await stores.accountGroupStore.addAccount(
        accC, to: group, accountStore: stores.accountStore)
      try await stores.accountStore.waitForNextEmission(
        matching: { $0.accounts.by(id: accC.id)?.groupId == group.id },
        description: "C joined group")
      let coordinator = SidebarOutlineDropCoordinator(
        accountStore: stores.accountStore,
        accountGroupStore: stores.accountGroupStore,
        groupUIStateStore: stores.groupUIStateStore)

      // Move 'A' to the pre-removal insertion slot after C.
      let result = await coordinator.commit(
        .reorderMembers(
          groupId: group.id, sourceAccountId: accA.id, insertionIndex: 3),
        bucket: .current)

      #expect(result == true)
      try await stores.accountStore.waitForNextEmission(
        matching: {
          let members = $0.accounts.ordered
            .filter { $0.groupId == group.id }
            .sorted(by: { $0.position < $1.position })
            .map(\.id)
          return members == [accB.id, accC.id, accA.id]
        },
        description: "member reorder applied")
    }

    @Test("commit .retargetRoot is a no-op (visual hint, never reaches accept)")
    func commitRetargetRoot() async throws {
      let (backend, database) = try TestBackend.create()
      let stores = try await DispatchSupport.makeStores(
        seedAccounts: [], in: database, backend: backend)
      let coordinator = SidebarOutlineDropCoordinator(
        accountStore: stores.accountStore,
        accountGroupStore: stores.accountGroupStore,
        groupUIStateStore: stores.groupUIStateStore)

      let result = await coordinator.commit(
        .retargetRoot(insertionIndex: 0), bucket: .current)

      #expect(result == false)
    }

    @Test("commit .retargetGroup is a no-op")
    func commitRetargetGroup() async throws {
      let (backend, database) = try TestBackend.create()
      let stores = try await DispatchSupport.makeStores(
        seedAccounts: [], in: database, backend: backend)
      let coordinator = SidebarOutlineDropCoordinator(
        accountStore: stores.accountStore,
        accountGroupStore: stores.accountGroupStore,
        groupUIStateStore: stores.groupUIStateStore)

      let result = await coordinator.commit(
        .retargetGroup(groupId: UUID(), insertionIndex: 0), bucket: .current)

      #expect(result == false)
    }

    @Test("commit .reorderMembers routes a cross-group move through the throwing dispatch")
    func commitReorderMembersCrossGroup() async throws {
      let (backend, database) = try TestBackend.create()
      let aSole = DispatchSupport.bankAccount(name: "ASole", position: 0)
      let accB1 = DispatchSupport.bankAccount(name: "B1", position: 1)
      let accB2 = DispatchSupport.bankAccount(name: "B2", position: 2)
      let stores = try await DispatchSupport.makeStores(
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
      let coordinator = SidebarOutlineDropCoordinator(
        accountStore: stores.accountStore,
        accountGroupStore: stores.accountGroupStore,
        groupUIStateStore: stores.groupUIStateStore)

      let result = await coordinator.commit(
        .reorderMembers(groupId: groupB.id, sourceAccountId: aSole.id, insertionIndex: 1),
        bucket: .current)

      #expect(result == true)
      try await stores.accountStore.waitForNextEmission(
        matching: { $0.accounts.by(id: aSole.id)?.groupId == groupB.id },
        description: "aSole moved to B via coordinator commit")
      try await stores.accountGroupStore.waitForNextEmission(
        matching: { $0.by(id: groupA.id) == nil },
        description: "group A auto-deleted via coordinator commit")
    }

    @Test("commit .reorderEarmark handles upward, adjacent, and downward drops")
    func commitReorderEarmark() async throws {
      let first = Earmark(
        name: "First", instrument: .defaultTestInstrument, position: 0)
      let second = Earmark(
        name: "Second", instrument: .defaultTestInstrument, position: 1)
      let third = Earmark(
        name: "Third", instrument: .defaultTestInstrument, position: 2)
      let (backend, database) = try TestBackend.create()
      TestBackend.seed(earmarks: [first, second, third], in: database)
      let stores = try await DispatchSupport.makeStores(
        seedAccounts: [], in: database, backend: backend)
      let earmarkStore = EarmarkStore(
        repository: backend.earmarks,
        conversionService: FakeConversionService.fixedRates([:]),
        targetInstrument: .defaultTestInstrument)
      try await earmarkStore.waitForNextEmission(
        matching: { $0.earmarks.count == 3 },
        description: "seeded earmarks observed")
      let coordinator = SidebarOutlineDropCoordinator(
        accountStore: stores.accountStore,
        accountGroupStore: stores.accountGroupStore,
        earmarkStore: earmarkStore,
        groupUIStateStore: stores.groupUIStateStore)

      let result = await coordinator.commit(
        .reorderEarmark(sourceId: third.id, insertionIndex: 0),
        bucket: nil)

      #expect(result == true)
      await expectEventually("earmark reorder applied") {
        earmarkStore.visibleEarmarks.map(\.id) == [third.id, first.id, second.id]
      }

      let adjacentResult = await coordinator.commit(
        .reorderEarmark(sourceId: third.id, insertionIndex: 1),
        bucket: nil)

      #expect(adjacentResult == true)
      #expect(earmarkStore.visibleEarmarks.map(\.id) == [third.id, first.id, second.id])

      let downwardResult = await coordinator.commit(
        .reorderEarmark(sourceId: third.id, insertionIndex: 2),
        bucket: nil)

      #expect(downwardResult == true)
      await expectEventually("downward earmark reorder applied") {
        earmarkStore.visibleEarmarks.map(\.id) == [first.id, third.id, second.id]
      }
    }
  }
#endif
