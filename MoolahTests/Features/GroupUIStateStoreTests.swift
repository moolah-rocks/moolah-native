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
    try await store.waitForNextEmission(
      matching: { $0.expandedGroupIds.contains(group.id) },
      description: "expanded observed")

    #expect(store.expandedGroupIds == [group.id])
    #expect(store.error == nil)
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
    try await store.waitForNextEmission(
      matching: { $0.expandedGroupIds.isEmpty },
      description: "collapsed observed")

    #expect(store.expandedGroupIds.isEmpty)
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
    try await store.waitForNextEmission(
      matching: { $0.expandedGroupIds.contains(group.id) },
      description: "toggle to expanded")
    #expect(store.expandedGroupIds == [group.id])

    await store.toggle(group.id)
    try await store.waitForNextEmission(
      matching: { $0.expandedGroupIds.isEmpty },
      description: "toggle to collapsed")
    #expect(store.expandedGroupIds.isEmpty)
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
    try await store.waitForNextEmission(
      matching: { $0.expandedGroupIds.count == 2 },
      description: "both observed")

    #expect(store.expandedGroupIds == [groupA.id, groupB.id])
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
    try await store.waitForNextEmission(
      matching: { $0.expandedGroupIds.isEmpty },
      description: "cascade observed")

    #expect(store.expandedGroupIds.isEmpty)
  }
}
