import Foundation
import Testing

@testable import Moolah

@Suite("Sidebar expansion mapping")
struct SidebarOutlineExpansionMappingTests {
  @Test("rows(for:) lifts a set of group UUIDs to .group rows")
  func liftToRows() {
    let firstGroup = UUID()
    let secondGroup = UUID()
    let rows = SidebarOutlineExpansion.rows(for: [firstGroup, secondGroup])
    #expect(rows == Set([.group(firstGroup), .group(secondGroup)]))
  }

  @Test("groupIds(in:) filters non-group rows out")
  func filterRows() {
    let groupId = UUID()
    let mixed: Set<SidebarRow> = [
      .group(groupId),
      .section(.current),
      .account(UUID()),
      .total(.netWorth),
    ]
    #expect(SidebarOutlineExpansion.groupIds(in: mixed) == [groupId])
  }

  @Test("rows(for:) / groupIds(in:) round-trip a set of group ids")
  func roundTrip() {
    let ids: Set<UUID> = [UUID(), UUID(), UUID()]
    let rows = SidebarOutlineExpansion.rows(for: ids)
    #expect(SidebarOutlineExpansion.groupIds(in: rows) == ids)
  }
}
