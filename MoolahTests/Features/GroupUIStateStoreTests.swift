import Foundation
import Testing

@testable import Moolah

@Suite("GroupUIStateStore — load, observe, toggle")
@MainActor
struct GroupUIStateStoreTests {
  @Test("initial emission is empty")
  func initialEmissionEmpty() async throws {
    let (backend, _) = try TestBackend.create()
    let store = GroupUIStateStore(repository: backend.groupUIState)
    try await store.waitForFirstEmission()
    #expect(store.expandedGroupIds.isEmpty)
  }

  @Test("setExpanded(true) is reflected via the observation stream")
  func setExpandedTrueObserved() async throws {
    let (backend, _) = try TestBackend.create()
    let store = GroupUIStateStore(repository: backend.groupUIState)
    try await store.waitForFirstEmission()

    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "G", bucket: .investments, instrument: .defaultTestInstrument))

    await store.setExpanded(true, for: group.id)
    await expectEventually("expanded set is exactly the group with no error") {
      store.expandedGroupIds == [group.id] && store.error == nil
    }
  }

  @Test("setExpanded(false) removes from the snapshot")
  func setExpandedFalseObserved() async throws {
    let (backend, _) = try TestBackend.create()
    let store = GroupUIStateStore(repository: backend.groupUIState)
    try await store.waitForFirstEmission()

    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "G", bucket: .investments, instrument: .defaultTestInstrument))

    await store.setExpanded(true, for: group.id)
    try await store.waitForNextEmission(
      matching: { $0.expandedGroupIds.contains(group.id) },
      description: "expanded observed")

    await store.setExpanded(false, for: group.id)
    await expectEventually("collapse removes the group from the snapshot") {
      store.expandedGroupIds.isEmpty
    }
  }

  @Test("toggle flips the expand state")
  func toggleFlipsState() async throws {
    let (backend, _) = try TestBackend.create()
    let store = GroupUIStateStore(repository: backend.groupUIState)
    try await store.waitForFirstEmission()

    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "G", bucket: .investments, instrument: .defaultTestInstrument))

    await store.toggle(group.id)
    await expectEventually("toggle expands to exactly the group") {
      store.expandedGroupIds == [group.id]
    }

    await store.toggle(group.id)
    await expectEventually("toggle collapses back to empty") {
      store.expandedGroupIds.isEmpty
    }
  }

  @Test("multiple expanded groups all appear in the snapshot")
  func multipleExpandedGroups() async throws {
    let (backend, _) = try TestBackend.create()
    let store = GroupUIStateStore(repository: backend.groupUIState)
    try await store.waitForFirstEmission()

    let groupA = try await backend.accountGroups.create(
      AccountGroup(
        name: "A", bucket: .investments,
        instrument: .defaultTestInstrument, position: 0))
    let groupB = try await backend.accountGroups.create(
      AccountGroup(
        name: "B", bucket: .investments,
        instrument: .defaultTestInstrument, position: 1))

    await store.setExpanded(true, for: groupA.id)
    await store.setExpanded(true, for: groupB.id)
    await expectEventually("both groups appear in the snapshot") {
      store.expandedGroupIds == [groupA.id, groupB.id]
    }
  }

  @Test("deleting a group reaps its expand state through the cascade")
  func deletedGroupReapedFromStore() async throws {
    let (backend, _) = try TestBackend.create()
    let store = GroupUIStateStore(repository: backend.groupUIState)
    try await store.waitForFirstEmission()

    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Doomed", bucket: .investments,
        instrument: .defaultTestInstrument))
    await store.setExpanded(true, for: group.id)
    try await store.waitForNextEmission(
      matching: { $0.expandedGroupIds.contains(group.id) },
      description: "expanded observed")

    try await backend.accountGroups.delete(id: group.id)
    await expectEventually("delete cascade reaps the expand state") {
      store.expandedGroupIds.isEmpty
    }
  }
}
