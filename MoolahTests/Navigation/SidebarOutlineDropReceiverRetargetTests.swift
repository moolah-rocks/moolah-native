#if os(macOS)
  import Foundation
  import Testing

  @testable import Moolah

  /// Covers row 13 of the `SidebarOutlineDropReceiver` decision table —
  /// hover-near-the-bottom-of-an-account-row retargets to either root or
  /// the hovered account's parent group — together with the pure
  /// `DropOutcome.asValidationResult()` cases that translate each
  /// outcome variant to the vendored `ValidationResult` shape.
  @MainActor
  @Suite("SidebarOutlineDropReceiver — retarget & validation mapping")
  struct SidebarOutlineDropReceiverRetargetTests {
    private typealias Support = SidebarOutlineDropReceiverTestSupport

    // MARK: - Retargeting cases (row 13)

    @Test("childIndex on standalone account at root → retargetRoot(insertionIndex: rootIndex+1)")
    func retargetStandaloneAccountToRoot() {
      // Bucket order: alpha (pos 0, standalone), group (pos 1), bravo (pos 2, standalone).
      let alpha = Support.bankAccount(name: "A", position: 0)
      let group = AccountGroup(
        name: "G",
        bucket: .current,
        instrument: .defaultTestInstrument,
        position: 1)
      let bravo = Support.bankAccount(name: "B", position: 2)
      let source = Support.bankAccount(name: "S", position: 3)
      // Hovering near the bottom of alpha's row reports
      // intoElement = .account(alpha), childIndex non-nil. alpha is at
      // root index 0, so the retargeted insertion goes to index 1.
      let outcome = SidebarOutlineDropReceiver.outcome(
        for: Support.target(
          dragged: .account(source.id),
          intoElement: .account(alpha.id),
          childIndex: 0),
        bucket: .current,
        accounts: Accounts(from: [alpha, bravo, source]),
        groups: [group])
      #expect(outcome == .retargetRoot(insertionIndex: 1))
    }

    @Test("childIndex on member account → retargetGroup(parentId, memberIndex+1)")
    func retargetMemberAccountToParentGroup() {
      let group = Support.currentGroup(position: 0)
      let memberA = Support.bankAccount(name: "MA", position: 0, groupId: group.id)
      let memberB = Support.bankAccount(name: "MB", position: 1, groupId: group.id)
      let source = Support.bankAccount(name: "S", position: 2)
      // Hovering near the bottom of memberA's row reports
      // intoElement = .account(memberA), childIndex non-nil. memberA is
      // member-index 0, so retarget to the parent group at index 1.
      let outcome = SidebarOutlineDropReceiver.outcome(
        for: Support.target(
          dragged: .account(source.id),
          intoElement: .account(memberA.id),
          childIndex: 0),
        bucket: .current,
        accounts: Accounts(from: [memberA, memberB, source]),
        groups: [group])
      #expect(
        outcome == .retargetGroup(groupId: group.id, insertionIndex: 1))
    }

    // MARK: - asValidationResult mapping

    @Test("DropOutcome.deny maps to ValidationResult.deny")
    func validationDeny() {
      switch SidebarOutlineDropReceiver.DropOutcome.deny.asValidationResult() {
      case .deny: break
      default: Issue.record("expected .deny")
      }
    }

    @Test("DropOutcome.addToGroup maps to .move")
    func validationAddToGroup() {
      let outcome: SidebarOutlineDropReceiver.DropOutcome = .addToGroup(
        sourceAccountId: UUID(), groupId: UUID())
      switch outcome.asValidationResult() {
      case .move: break
      default: Issue.record("expected .move")
      }
    }

    @Test("DropOutcome.retargetRoot maps to .moveRedirect(item: nil, childIndex: idx)")
    func validationRetargetRoot() {
      let outcome = SidebarOutlineDropReceiver.DropOutcome.retargetRoot(
        insertionIndex: 3)
      switch outcome.asValidationResult() {
      case let .moveRedirect(item, childIndex):
        #expect(item == nil)
        #expect(childIndex == 3)
      default: Issue.record("expected .moveRedirect")
      }
    }

    @Test("DropOutcome.retargetGroup maps to .moveRedirect(item: group, childIndex: idx)")
    func validationRetargetGroup() {
      let groupId = UUID()
      let outcome = SidebarOutlineDropReceiver.DropOutcome.retargetGroup(
        groupId: groupId, insertionIndex: 2)
      switch outcome.asValidationResult() {
      case let .moveRedirect(item, childIndex):
        #expect(item?.kind == .group(groupId))
        #expect(childIndex == 2)
      default: Issue.record("expected .moveRedirect")
      }
    }
  }
#endif
