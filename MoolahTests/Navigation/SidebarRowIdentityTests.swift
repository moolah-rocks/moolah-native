import Foundation
import Testing

@testable import Moolah

@Suite("SidebarRow identity")
struct SidebarRowIdentityTests {
  @Test("Two rows for the same account are equal and hash equally")
  func accountIdentityRoundTrip() {
    let id = UUID()
    let first = SidebarRow.account(id)
    let second = SidebarRow.account(id)
    #expect(first == second)
    #expect(first.hashValue == second.hashValue)
    #expect(first.id == second.id)
  }

  @Test("Account and group with the same UUID are distinct rows")
  func accountAndGroupAreDistinct() {
    let id = UUID()
    #expect(SidebarRow.account(id) != SidebarRow.group(id))
    #expect(SidebarRow.account(id).id != SidebarRow.group(id).id)
  }

  @Test("Section / total / navigation cases have stable identifiers")
  func staticCaseIdentifiers() {
    let currentSection = SidebarRow.section(.current)
    let currentSectionDup = SidebarRow.section(.current)
    #expect(currentSection == currentSectionDup)
    #expect(SidebarRow.section(.current) != SidebarRow.section(.earmarks))
    #expect(SidebarRow.total(.currentTotal) != SidebarRow.total(.netWorth))
    #expect(SidebarRow.navigation(.analysis) != SidebarRow.navigation(.reports))
  }
}
