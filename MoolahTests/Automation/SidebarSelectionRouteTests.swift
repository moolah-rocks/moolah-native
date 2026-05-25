import Foundation
import Testing

@testable import Moolah

@Suite("SidebarSelection → NavigationDestination")
struct SidebarSelectionRouteTests {

  @Test("account selection maps to .account")
  func accountMaps() {
    let id = UUID()
    #expect(SidebarSelection.account(id).navigationDestination == .account(id))
  }

  @Test("earmark selection maps to .earmark")
  func earmarkMaps() {
    let id = UUID()
    #expect(SidebarSelection.earmark(id).navigationDestination == .earmark(id))
  }

  @Test("allTransactions maps to .accounts")
  func allTransactionsMaps() {
    #expect(SidebarSelection.allTransactions.navigationDestination == .accounts)
  }

  @Test("recentlyAdded maps to .accounts")
  func recentlyAddedMaps() {
    #expect(SidebarSelection.recentlyAdded.navigationDestination == .accounts)
  }

  @Test("upcomingTransactions maps to .upcoming")
  func upcomingMaps() {
    #expect(SidebarSelection.upcomingTransactions.navigationDestination == .upcoming)
  }

  @Test("categories maps to .categories")
  func categoriesMaps() {
    #expect(SidebarSelection.categories.navigationDestination == .categories)
  }

  @Test("reports maps to .reports with nil params")
  func reportsMaps() {
    #expect(SidebarSelection.reports.navigationDestination == .reports(from: nil, to: nil))
  }

  @Test("analysis maps to .analysis with nil params")
  func analysisMaps() {
    #expect(
      SidebarSelection.analysis.navigationDestination == .analysis(history: nil, forecast: nil))
  }
}
