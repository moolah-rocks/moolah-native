import Foundation
import Testing

@testable import Moolah

@Suite("AnalysisStore — effective load window")
struct AnalysisStoreDisplayWindowTests {

  @Test("a narrow display filter still loads the insight floor")
  func narrowFilterLoadsFloor() {
    #expect(
      AnalysisStore.effectiveLoadMonths(historyMonths: 3, floorMonths: 36) == 36)
  }

  @Test("a wide display filter loads the wider window, not the floor")
  func wideFilterLoadsRequested() {
    #expect(
      AnalysisStore.effectiveLoadMonths(historyMonths: 60, floorMonths: 36) == 60)
  }

  @Test("All (0) loads everything")
  func allLoadsEverything() {
    #expect(
      AnalysisStore.effectiveLoadMonths(historyMonths: 0, floorMonths: 36) == Int.max)
  }
}
