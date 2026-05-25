import Foundation
import Testing

@testable import Moolah

@Suite("NavigationDestination.make")
struct NavigationDestinationMakeTests {

  @Test("nil sidebar produces nil")
  func nilSidebarProducesNil() {
    #expect(
      NavigationDestination.make(
        sidebar: nil,
        selectedTransaction: nil,
        analysis: nil,
        reports: nil) == nil)
  }

  @Test("transaction selection wins over sidebar")
  func transactionWinsOverSidebar() {
    let txn = UUID()
    let result = NavigationDestination.make(
      sidebar: .allTransactions,
      selectedTransaction: txn,
      analysis: nil,
      reports: nil)
    #expect(result == .transaction(txn))
  }

  @Test("transaction selection wins even with analysis params")
  func transactionWinsOverAnalysis() {
    let txn = UUID()
    let result = NavigationDestination.make(
      sidebar: .analysis,
      selectedTransaction: txn,
      analysis: AnalysisRouteParams(history: 12, forecast: 6),
      reports: nil)
    #expect(result == .transaction(txn))
  }

  @Test("sidebar alone produces the sidebar's destination")
  func sidebarAlone() {
    let acct = UUID()
    let result = NavigationDestination.make(
      sidebar: .account(acct),
      selectedTransaction: nil,
      analysis: nil,
      reports: nil)
    #expect(result == .account(acct))
  }

  @Test("analysis sidebar overlays analysis params")
  func analysisOverlaysParams() {
    let result = NavigationDestination.make(
      sidebar: .analysis,
      selectedTransaction: nil,
      analysis: AnalysisRouteParams(history: 12, forecast: 6),
      reports: nil)
    #expect(result == .analysis(history: 12, forecast: 6))
  }

  @Test("analysis sidebar with nil params produces parameterless analysis")
  func analysisSidebarNilParamsProducesParameterless() {
    let result = NavigationDestination.make(
      sidebar: .analysis, selectedTransaction: nil,
      analysis: nil, reports: nil)
    #expect(result == .analysis(history: nil, forecast: nil))
  }

  @Test("reports sidebar overlays reports params")
  func reportsOverlaysParams() {
    let from = Date(timeIntervalSince1970: 1_700_000_000)
    let to = Date(timeIntervalSince1970: 1_800_000_000)
    let result = NavigationDestination.make(
      sidebar: .reports,
      selectedTransaction: nil,
      analysis: nil,
      reports: ReportsRouteParams(from: from, to: to))
    #expect(result == .reports(from: from, to: to))
  }

  @Test("reports sidebar with nil params produces parameterless reports")
  func reportsSidebarNilParamsProducesParameterless() {
    let result = NavigationDestination.make(
      sidebar: .reports, selectedTransaction: nil,
      analysis: nil, reports: nil)
    #expect(result == .reports(from: nil, to: nil))
  }

  @Test("non-analysis sidebar ignores analysis params")
  func nonAnalysisIgnoresAnalysisParams() {
    let result = NavigationDestination.make(
      sidebar: .categories,
      selectedTransaction: nil,
      analysis: AnalysisRouteParams(history: 12, forecast: 6),
      reports: nil)
    #expect(result == .categories)
  }

  @Test("non-reports sidebar ignores reports params")
  func nonReportsIgnoresReportsParams() {
    let result = NavigationDestination.make(
      sidebar: .categories,
      selectedTransaction: nil,
      analysis: nil,
      reports: ReportsRouteParams(
        from: Date(timeIntervalSince1970: 1_700_000_000),
        to: nil))
    #expect(result == .categories)
  }
}
