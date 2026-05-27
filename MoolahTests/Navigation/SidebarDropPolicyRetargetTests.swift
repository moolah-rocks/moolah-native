#if os(macOS)
  import Foundation
  import Testing

  @testable import Moolah

  /// Covers row 13 of the `SidebarDropPolicy` decision table —
  /// hover-near-the-bottom-of-an-account-row retargets to either root or
  /// the hovered account's parent group.
  @MainActor
  @Suite("SidebarDropPolicy — retarget")
  struct SidebarDropPolicyRetargetTests {
    private typealias Support = SidebarDropPolicyTestSupport

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
      let outcome = SidebarDropPolicy.outcome(
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
      let outcome = SidebarDropPolicy.outcome(
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
  }
#endif
