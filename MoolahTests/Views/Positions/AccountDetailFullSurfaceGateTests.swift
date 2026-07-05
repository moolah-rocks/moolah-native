import Foundation
import Testing

@testable import Moolah

@Suite("AccountDetailLayout.showsFullSurface")
struct AccountDetailFullSurfaceGateTests {
  @Test("always-full forces the surface on even when the base gate is false")
  func alwaysForcesOn() {
    #expect(
      AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface: true, otherwiseShows: false))
  }

  @Test("without always-full, the base gate decides")
  func fallsThroughToBase() {
    #expect(
      AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface: false, otherwiseShows: true))
    #expect(
      !AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface: false, otherwiseShows: false))
  }

  @Test("always-full and a true base still show")
  func bothTrue() {
    #expect(
      AccountDetailLayout.showsFullSurface(alwaysShowsFullSurface: true, otherwiseShows: true))
  }
}
