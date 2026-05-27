import Foundation
import Testing

@testable import Moolah

@Suite("SidebarRow ↔ SidebarSelection mapping")
struct SidebarOutlineSelectionMappingTests {
  @Test("Account row maps to .account selection and back")
  func accountRoundTrip() {
    let id = UUID()
    #expect(SidebarRow.account(id).asSelection == .account(id))
    #expect(SidebarRow(selection: .account(id)) == .account(id))
  }

  @Test("Group row maps to .group selection and back")
  func groupRoundTrip() {
    let id = UUID()
    #expect(SidebarRow.group(id).asSelection == .group(id))
    #expect(SidebarRow(selection: .group(id)) == .group(id))
  }

  @Test("Earmark row maps to .earmark selection and back")
  func earmarkRoundTrip() {
    let id = UUID()
    #expect(SidebarRow.earmark(id).asSelection == .earmark(id))
    #expect(SidebarRow(selection: .earmark(id)) == .earmark(id))
  }

  @Test("Section and total rows have no selection equivalent")
  func nonSelectableRows() {
    #expect(SidebarRow.section(.current).asSelection == nil)
    #expect(SidebarRow.section(.earmarks).asSelection == nil)
    #expect(SidebarRow.total(.netWorth).asSelection == nil)
    #expect(SidebarRow.total(.availableFunds).asSelection == nil)
  }

  @Test("All navigation selections round-trip through the mapping")
  func navigationRoundTrip() {
    let pairs: [(SidebarSelection, SidebarRow)] = [
      (.analysis, .navigation(.analysis)),
      (.reports, .navigation(.reports)),
      (.categories, .navigation(.categories)),
      (.upcomingTransactions, .navigation(.upcoming)),
      (.recentlyAdded, .navigation(.recentlyAdded)),
      (.allTransactions, .navigation(.allTransactions)),
    ]
    for (selection, row) in pairs {
      #expect(SidebarRow(selection: selection) == row)
      #expect(row.asSelection == selection)
    }
  }
}
