import Foundation
import SwiftUI
import Testing

@testable import Moolah

@Suite("SidebarView.renameBinding(for:editingId:)")
@MainActor
struct SidebarRenameBindingTests {
  @Test("Returns true when editingId matches the given id")
  func reportsEditingWhenIdMatches() {
    let idA = UUID()
    var editingId: UUID? = idA
    let editing = Binding<UUID?>(
      get: { editingId }, set: { editingId = $0 })

    #expect(SidebarView.renameBinding(for: idA, editingId: editing).wrappedValue)
  }

  @Test("Returns false when editingId does not match the given id")
  func reportsNotEditingWhenIdDiffers() {
    let idA = UUID()
    let idB = UUID()
    var editingId: UUID? = idA
    let editing = Binding<UUID?>(
      get: { editingId }, set: { editingId = $0 })

    #expect(!SidebarView.renameBinding(for: idB, editingId: editing).wrappedValue)
  }

  @Test("Setting true assigns this row's id to editingId")
  func settingTrueAssignsId() {
    let idA = UUID()
    var editingId: UUID?
    let editing = Binding<UUID?>(
      get: { editingId }, set: { editingId = $0 })

    SidebarView.renameBinding(for: idA, editingId: editing).wrappedValue = true
    #expect(editingId == idA)
  }

  @Test("Setting false on the editing row clears editingId to nil")
  func settingFalseClearsId() {
    let idA = UUID()
    var editingId: UUID? = idA
    let editing = Binding<UUID?>(
      get: { editingId }, set: { editingId = $0 })

    SidebarView.renameBinding(for: idA, editingId: editing).wrappedValue = false
    #expect(editingId == nil)
  }

  @Test("Setting true for B while A is editing replaces editingId with B")
  func switchingBetweenRowsReplacesEditingId() {
    let idA = UUID()
    let idB = UUID()
    var editingId: UUID? = idA
    let editing = Binding<UUID?>(
      get: { editingId }, set: { editingId = $0 })

    SidebarView.renameBinding(for: idB, editingId: editing).wrappedValue = true
    #expect(editingId == idB)
  }

  @Test(
    "Setting false on a non-editing row clears editingId (set(false) writes nil unconditionally)")
  func settingFalseOnNonEditingRowClearsEditingId() {
    let idA = UUID()
    let idB = UUID()
    var editingId: UUID? = idA
    let editing = Binding<UUID?>(
      get: { editingId }, set: { editingId = $0 })

    // The binding's set closure unconditionally writes nil for set(false),
    // regardless of which row id the binding was created for. Callers that
    // set false for the non-editing row therefore clear editingId as a
    // side effect — the one-at-a-time invariant is enforced only by
    // callers setting true.
    SidebarView.renameBinding(for: idB, editingId: editing).wrappedValue = false
    #expect(editingId == nil)
  }
}
