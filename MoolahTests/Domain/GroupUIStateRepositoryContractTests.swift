import Foundation
import Testing

@testable import Moolah

@Suite("GroupUIStateRepository contract")
struct GroupUIStateRepositoryContractTests {
  @Test("unknown group defaults to collapsed")
  func defaultIsCollapsed() async throws {
    let (backend, _) = try TestBackend.create()
    let expanded = try await backend.groupUIState.isExpanded(groupId: UUID())
    #expect(expanded == false)
  }

  @Test("set then read returns true")
  func setThenReadTrue() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Trust Fund Crypto", bucket: .investments,
        instrument: .defaultTestInstrument))
    try await backend.groupUIState.setExpanded(true, for: group.id)
    let expanded = try await backend.groupUIState.isExpanded(groupId: group.id)
    #expect(expanded == true)
  }

  @Test("set false then read returns false")
  func setFalseThenReadFalse() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Personal Crypto", bucket: .investments,
        instrument: .defaultTestInstrument))
    try await backend.groupUIState.setExpanded(true, for: group.id)
    try await backend.groupUIState.setExpanded(false, for: group.id)
    let expanded = try await backend.groupUIState.isExpanded(groupId: group.id)
    #expect(expanded == false)
  }

  @Test("repeated set is idempotent (upsert)")
  func setIsIdempotent() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Stocks", bucket: .investments,
        instrument: .defaultTestInstrument))
    try await backend.groupUIState.setExpanded(true, for: group.id)
    try await backend.groupUIState.setExpanded(true, for: group.id)
    let expanded = try await backend.groupUIState.isExpanded(groupId: group.id)
    #expect(expanded == true)
  }

  @Test("expandedGroupIds returns only expanded entries")
  func expandedGroupIdsReturnsOnlyExpanded() async throws {
    let (backend, _) = try TestBackend.create()
    let groupA = try await backend.accountGroups.create(
      AccountGroup(
        name: "A", bucket: .investments,
        instrument: .defaultTestInstrument, position: 0))
    let groupB = try await backend.accountGroups.create(
      AccountGroup(
        name: "B", bucket: .investments,
        instrument: .defaultTestInstrument, position: 1))
    let groupC = try await backend.accountGroups.create(
      AccountGroup(
        name: "C", bucket: .investments,
        instrument: .defaultTestInstrument, position: 2))

    try await backend.groupUIState.setExpanded(true, for: groupA.id)
    try await backend.groupUIState.setExpanded(false, for: groupB.id)
    try await backend.groupUIState.setExpanded(true, for: groupC.id)

    let expanded = try await backend.groupUIState.expandedGroupIds()
    #expect(expanded == [groupA.id, groupC.id])
  }

  @Test("expandedGroupIds is empty when nothing has been set")
  func expandedGroupIdsEmpty() async throws {
    let (backend, _) = try TestBackend.create()
    let expanded = try await backend.groupUIState.expandedGroupIds()
    #expect(expanded.isEmpty)
  }

  @Test("deleting a group cascades the UI-state row away")
  func cascadeReapsUIStateRow() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Doomed", bucket: .investments,
        instrument: .defaultTestInstrument))
    try await backend.groupUIState.setExpanded(true, for: group.id)
    try await backend.accountGroups.delete(id: group.id)
    let expanded = try await backend.groupUIState.isExpanded(groupId: group.id)
    #expect(expanded == false)
    let allExpanded = try await backend.groupUIState.expandedGroupIds()
    #expect(allExpanded.contains(group.id) == false)
  }

  @Test("observeExpandedGroupIds emits initial snapshot")
  func observeInitialSnapshot() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Seeded", bucket: .investments,
        instrument: .defaultTestInstrument))
    try await backend.groupUIState.setExpanded(true, for: group.id)

    var iterator = backend.groupUIState.observeExpandedGroupIds().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial == [group.id])
  }

  @Test("observeExpandedGroupIds emits on set")
  func observeEmitsOnSet() async throws {
    let (backend, _) = try TestBackend.create()
    let group = try await backend.accountGroups.create(
      AccountGroup(
        name: "Watched", bucket: .investments,
        instrument: .defaultTestInstrument))

    var iterator = backend.groupUIState.observeExpandedGroupIds().makeAsyncIterator()
    let initial = await iterator.next()
    #expect(initial?.isEmpty == true)

    try await backend.groupUIState.setExpanded(true, for: group.id)
    let afterSet = await iterator.next()
    #expect(afterSet == [group.id])
  }
}
