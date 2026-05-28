#if os(macOS)
  import Foundation

  @testable import Moolah

  /// Shared fixtures for the `SidebarOutlineDropCoordinator` pure
  /// helper test suites. Borrows the account / group factory shape
  /// from `SidebarDropPolicyTestSupport` so the policy suites and the
  /// coordinator suites can be read side-by-side.
  enum SidebarOutlineDropCoordinatorTestSupport {

    static func bankAccount(
      name: String, position: Int, groupId: UUID? = nil
    ) -> Account {
      Account(
        id: UUID(),
        name: name,
        type: .bank,
        instrument: .defaultTestInstrument,
        position: position,
        groupId: groupId)
    }

    static func investmentAccount(name: String, position: Int) -> Account {
      Account(
        id: UUID(),
        name: name,
        type: .investment,
        instrument: .defaultTestInstrument,
        position: position)
    }

    static func currentGroup(position: Int) -> AccountGroup {
      AccountGroup(
        name: "G",
        bucket: .current,
        instrument: .defaultTestInstrument,
        position: position)
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
