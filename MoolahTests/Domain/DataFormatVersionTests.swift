import Foundation
import Testing

@testable import Moolah

@Suite("DataFormatVersion")
struct DataFormatVersionTests {
  @Test("current is at least 1 — the gate has shipped")
  func currentIsAtLeastOne() {
    #expect(DataFormatVersion.current >= 1)
  }

  @Test("current fences synced tax owner records")
  func currentFencesSyncedTaxOwnerRecords() {
    #expect(DataFormatVersion.current >= 9)
  }

  @Test("current fences automatic sync preferences")
  func currentFencesAutomaticSyncPreferences() {
    #expect(DataFormatVersion.current >= 11)
  }

  @Test("Profile gets a default dataFormatVersion of 0 — pre-gate baseline")
  func profileDefaultsToZero() {
    let profile = Profile(label: "Test")
    #expect(profile.dataFormatVersion == 0)
  }
}
