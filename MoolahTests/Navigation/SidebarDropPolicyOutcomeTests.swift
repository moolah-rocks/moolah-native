#if os(macOS)
  import Foundation
  import Testing

  @testable import Moolah

  /// Covers the deny / accept / reorder rows of the
  /// `SidebarDropPolicy.outcome(for:bucket:accounts:groups:)` decision
  /// table — one test per row, asserting the resolved `DropOutcome`
  /// against hand-built `DropTarget` fixtures.
  @MainActor
  @Suite("SidebarDropPolicy — outcome")
  struct SidebarDropPolicyOutcomeTests {
    private typealias Support = SidebarDropPolicyTestSupport

    // MARK: - Deny rows

    @Test("row 1: nil intoElement + nil childIndex denies (drop-onto-root)")
    func denyDropOntoRoot() {
      let account = Support.bankAccount(name: "A", position: 0)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(account.id), intoElement: nil, childIndex: nil),
        bucket: .current,
        accounts: Accounts(from: [account]),
        groups: [])
      #expect(outcome == .deny)
    }

    @Test("row 11: self-drop on account denies")
    func denySelfDropOnAccount() {
      let account = Support.bankAccount(name: "A", position: 0)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(account.id),
          intoElement: .account(account.id),
          childIndex: nil),
        bucket: .current,
        accounts: Accounts(from: [account]),
        groups: [])
      #expect(outcome == .deny)
    }

    @Test("row 12: group onto account denies")
    func denyGroupDroppedOntoAccount() {
      let group = Support.currentGroup(position: 0)
      let target = Support.bankAccount(name: "T", position: 1)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .group(group.id),
          intoElement: .account(target.id),
          childIndex: nil),
        bucket: .current,
        accounts: Accounts(from: [target]),
        groups: [group])
      #expect(outcome == .deny)
    }

    @Test("rows 7+10: group onto group denies (no nesting)")
    func denyGroupDroppedOntoGroup() {
      let dragged = Support.currentGroup(position: 0)
      let targetGroup = Support.currentGroup(position: 1)
      // dragged group dropped onto another group (intoElement = group, childIndex = nil)
      let ontoOutcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .group(dragged.id),
          intoElement: .group(targetGroup.id),
          childIndex: nil),
        bucket: .current,
        accounts: Accounts(from: []),
        groups: [dragged, targetGroup])
      #expect(ontoOutcome == .deny)
      // dragged group dropped between members of a group denies too.
      let betweenOutcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .group(dragged.id),
          intoElement: .group(targetGroup.id),
          childIndex: 0),
        bucket: .current,
        accounts: Accounts(from: []),
        groups: [dragged, targetGroup])
      #expect(betweenOutcome == .deny)
    }

    @Test("row 5: cross-bucket root reorder denies")
    func denyCrossBucketRootReorder() {
      let invest = Support.investmentAccount(name: "I", position: 0)
      let bank = Support.bankAccount(name: "B", position: 1)
      // Investment account dragged into .current bucket's root.
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(invest.id), intoElement: nil, childIndex: 0),
        bucket: .current,
        accounts: Accounts(from: [invest, bank]),
        groups: [])
      #expect(outcome == .deny)
    }

    @Test("row 3: member dragged to root insertion slot → reorderRoot")
    func memberDroppedAtRootReorders() {
      let group = Support.currentGroup(position: 0)
      let member = Support.bankAccount(name: "M", position: 1, groupId: group.id)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(member.id), intoElement: nil, childIndex: 1),
        bucket: .current,
        accounts: Accounts(from: [member]),
        groups: [group])
      #expect(
        outcome
          == .reorderRoot(
            item: DraggableSidebarItem(kind: .account, id: member.id),
            insertionIndex: 1))
    }

    @Test("row 6 variant: drop onto same group as current membership denies")
    func denyDropOntoOwnGroup() {
      let group = Support.currentGroup(position: 0)
      let member = Support.bankAccount(name: "M", position: 0, groupId: group.id)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(member.id),
          intoElement: .group(group.id),
          childIndex: nil),
        bucket: .current,
        accounts: Accounts(from: [member]),
        groups: [group])
      #expect(outcome == .deny)
    }

    // MARK: - Valid drop-onto cases

    @Test("row 6: standalone account onto group adds source to group")
    func addToGroupFromStandalone() {
      let group = Support.currentGroup(position: 0)
      let member = Support.bankAccount(name: "M", position: 0, groupId: group.id)
      let source = Support.bankAccount(name: "S", position: 1)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(source.id),
          intoElement: .group(group.id),
          childIndex: nil),
        bucket: .current,
        accounts: Accounts(from: [member, source]),
        groups: [group])
      #expect(
        outcome == .addToGroup(sourceAccountId: source.id, groupId: group.id))
    }

    @Test("row 11: standalone account onto another standalone same bucket → dropOntoAccount")
    func dropOntoStandalone() {
      let target = Support.bankAccount(name: "T", position: 0)
      let source = Support.bankAccount(name: "S", position: 1)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(source.id),
          intoElement: .account(target.id),
          childIndex: nil),
        bucket: .current,
        accounts: Accounts(from: [target, source]),
        groups: [])
      #expect(
        outcome
          == .dropOntoAccount(
            sourceAccountId: source.id, targetAccountId: target.id))
    }

    @Test("row 11: standalone account onto member account → dropOntoAccount (joins group)")
    func dropOntoMemberAccount() {
      let group = Support.currentGroup(position: 0)
      let member = Support.bankAccount(name: "M", position: 0, groupId: group.id)
      let source = Support.bankAccount(name: "S", position: 1)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(source.id),
          intoElement: .account(member.id),
          childIndex: nil),
        bucket: .current,
        accounts: Accounts(from: [member, source]),
        groups: [group])
      #expect(
        outcome
          == .dropOntoAccount(
            sourceAccountId: source.id, targetAccountId: member.id))
    }

    // MARK: - Reorder cases

    @Test("row 2: standalone account at root childIndex → reorderRoot(.account, idx)")
    func reorderRootStandalone() {
      let alpha = Support.bankAccount(name: "A", position: 0)
      let bravo = Support.bankAccount(name: "B", position: 1)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(bravo.id), intoElement: nil, childIndex: 0),
        bucket: .current,
        accounts: Accounts(from: [alpha, bravo]),
        groups: [])
      #expect(
        outcome
          == .reorderRoot(
            item: DraggableSidebarItem(kind: .account, id: bravo.id),
            insertionIndex: 0))
    }

    @Test("row 4: group at root childIndex → reorderRoot(.group, idx)")
    func reorderRootGroup() {
      let groupOne = Support.currentGroup(position: 0)
      let groupTwo = Support.currentGroup(position: 1)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .group(groupTwo.id), intoElement: nil, childIndex: 0),
        bucket: .current,
        accounts: Accounts(from: []),
        groups: [groupOne, groupTwo])
      #expect(
        outcome
          == .reorderRoot(
            item: DraggableSidebarItem(kind: .group, id: groupTwo.id),
            insertionIndex: 0))
    }

    @Test("row 8: member dropped between members of its group → reorderMembers")
    func reorderMembers() {
      let group = Support.currentGroup(position: 0)
      let memberA = Support.bankAccount(name: "MA", position: 0, groupId: group.id)
      let memberB = Support.bankAccount(name: "MB", position: 1, groupId: group.id)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(memberB.id),
          intoElement: .group(group.id),
          childIndex: 0),
        bucket: .current,
        accounts: Accounts(from: [memberA, memberB]),
        groups: [group])
      #expect(
        outcome
          == .reorderMembers(
            groupId: group.id, sourceAccountId: memberB.id, insertionIndex: 0))
    }

    @Test("rows 8 & 9: cross-group account dropped between target group members → reorderMembers")
    func outsiderDroppedBetweenGroupMembersReorders() {
      let groupA = Support.currentGroup(position: 0)
      let groupB = Support.currentGroup(position: 1)
      let source = Support.bankAccount(name: "S", position: 0, groupId: groupA.id)
      let member = Support.bankAccount(name: "M", position: 0, groupId: groupB.id)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(source.id),
          intoElement: .group(groupB.id),
          childIndex: 1),
        bucket: .current,
        accounts: Accounts(from: [source, member]),
        groups: [groupA, groupB])
      #expect(
        outcome
          == .reorderMembers(
            groupId: groupB.id, sourceAccountId: source.id, insertionIndex: 1))
    }

    @Test("rows 8 & 9: standalone source dropped between group members → reorderMembers")
    func standaloneBetweenGroupMembersReorders() {
      let group = Support.currentGroup(position: 0)
      let member = Support.bankAccount(name: "M", position: 0, groupId: group.id)
      let standalone = Support.bankAccount(name: "L", position: 1)
      let outcome = SidebarDropPolicy.outcome(
        for: Support.target(
          dragged: .account(standalone.id),
          intoElement: .group(group.id),
          childIndex: 0),
        bucket: .current,
        accounts: Accounts(from: [member, standalone]),
        groups: [group])
      #expect(
        outcome
          == .reorderMembers(
            groupId: group.id, sourceAccountId: standalone.id, insertionIndex: 0))
    }
  }
#endif
