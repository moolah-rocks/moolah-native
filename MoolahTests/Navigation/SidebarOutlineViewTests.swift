#if os(macOS)
  import Foundation
  import Testing

  @testable import Moolah

  /// Exercises the static `SidebarOutlineView.expansionBinding(groupStore:)`
  /// translation between the vendored OutlineView's
  /// `Set<SidebarOutlineItem.Kind>` and `GroupUIStateStore.expandedGroupIds`.
  ///
  /// The binding is a pure function over the store, so the tests construct
  /// a real `GroupUIStateStore` against an in-memory `TestBackend` — the
  /// same pattern `MoolahTests/Features/GroupUIStateStoreTests.swift` uses
  /// — and assert against the live emission stream rather than mocking.
  @Suite("SidebarOutlineView.expansionBinding")
  @MainActor
  struct SidebarOutlineViewTests {
    @Test("Getter reports currently-expanded groups")
    func expansionBindingReportsCurrentlyExpandedGroups() async throws {
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

      let binding = SidebarOutlineView.expansionBinding(groupStore: store)
      let expanded = binding.wrappedValue
      // Only `.group(id)` kinds are tracked now — section headers
      // moved out of the tree into SwiftUI sections, so they no
      // longer appear in the bound set.
      #expect(expanded == [.group(group.id)])
    }

    @Test("Setter writes a newly-inserted group through to the store")
    func expansionBindingExpandsGroupOnInsert() async throws {
      let (backend, _) = try TestBackend.create()
      let store = GroupUIStateStore(repository: backend.groupUIState)
      try await store.waitForFirstEmission()

      let group = try await backend.accountGroups.create(
        AccountGroup(
          name: "G", bucket: .investments, instrument: .defaultTestInstrument))

      let binding = SidebarOutlineView.expansionBinding(groupStore: store)
      binding.wrappedValue = [.group(group.id)]

      // The setter dispatches `setExpanded(true:)` asynchronously; wait
      // for the observation stream to reflect the persisted state.
      try await store.waitForNextEmission(
        matching: { $0.expandedGroupIds.contains(group.id) },
        description: "expanded observed")
      #expect(store.expandedGroupIds.contains(group.id))
    }

    @Test("Setter writes a removed group through to the store")
    func expansionBindingCollapsesGroupOnRemove() async throws {
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

      let binding = SidebarOutlineView.expansionBinding(groupStore: store)
      #expect(binding.wrappedValue.contains(.group(group.id)))

      binding.wrappedValue = []

      try await store.waitForNextEmission(
        matching: { !$0.expandedGroupIds.contains(group.id) },
        description: "collapsed observed")
      #expect(!store.expandedGroupIds.contains(group.id))
    }
  }
#endif
