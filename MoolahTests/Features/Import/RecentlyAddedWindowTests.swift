import Foundation
import Testing

@testable import Moolah

@Suite("Recently Added time window")
struct RecentlyAddedWindowTests {
  @Test("rolling windows use the injected reference date")
  func rollingWindowsUseInjectedNow() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    #expect(
      RecentlyAddedWindow.last24Hours.importedAtRange(now: now).lowerBound
        == now.addingTimeInterval(-86_400))
    #expect(
      RecentlyAddedWindow.lastWeek.importedAtRange(now: now).lowerBound
        == now.addingTimeInterval(-7 * 86_400))
  }

  @Test("rolling window admits imports that land while the view is open")
  func rollingWindowHasFutureUpperBound() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    #expect(
      RecentlyAddedWindow.last24Hours.importedAtRange(now: now).contains(
        now.addingTimeInterval(60)))
  }
}
