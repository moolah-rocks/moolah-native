import Foundation
import Testing

@testable import Moolah

@Suite("ProfileSession — updateProfile")
@MainActor
struct ProfileSessionUpdateProfileTests {
  @Test("updateProfile updates the in-memory profile value")
  func updatesValue() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let original = Profile(label: "Test")
    let session = try ProfileSession(
      profile: original, containerManager: containerManager)

    var bumped = original
    bumped.dataFormatVersion = 1
    session.updateProfile(bumped)

    #expect(session.profile.dataFormatVersion == 1)
    #expect(session.profile.id == original.id)
  }

  @Test("updateProfile refreshes reporting default tax owner")
  func updateProfileRefreshesReportingDefaultTaxOwner() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let original = Profile(label: "Test")
    let session = try ProfileSession(
      profile: original, containerManager: containerManager)
    let newDefaultOwnerId = UUID()

    var bumped = original
    bumped.defaultTaxOwnerId = newDefaultOwnerId
    session.updateProfile(bumped)

    #expect(session.reportingStore.defaultTaxOwnerId == newDefaultOwnerId)
  }
}
