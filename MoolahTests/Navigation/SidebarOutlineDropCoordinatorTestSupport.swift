#if os(macOS)
  import Foundation

  @testable import Moolah

  /// Shared fixtures for the `SidebarOutlineDropCoordinator` pure
  /// helper test suites. Re-exports the account / group factories from
  /// `SidebarDropPolicyTestSupport` as call-throughs so the coordinator
  /// suites can keep a single `Support` namespace, and adds
  /// `investmentGroup(position:)` which the policy suites don't need.
  enum SidebarOutlineDropCoordinatorTestSupport {

    static func bankAccount(
      name: String, position: Int, groupId: UUID? = nil
    ) -> Account {
      SidebarDropPolicyTestSupport.bankAccount(
        name: name, position: position, groupId: groupId)
    }

    static func investmentAccount(name: String, position: Int) -> Account {
      SidebarDropPolicyTestSupport.investmentAccount(
        name: name, position: position)
    }

    static func currentGroup(position: Int) -> AccountGroup {
      SidebarDropPolicyTestSupport.currentGroup(position: position)
    }

    static func investmentGroup(position: Int) -> AccountGroup {
      AccountGroup(
        name: "G",
        bucket: .investments,
        instrument: .defaultTestInstrument,
        position: position)
    }
  }
#endif
