// MoolahTests/App/ProfileSessionInstrumentRegistryTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("ProfileSession — instrumentRegistry wiring")
@MainActor
struct ProfileSessionInstrumentRegistryTests {
  @Test("CloudKit profile has both registry and cryptoTokenStore")
  func cloudKitProfileHasRegistry() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(
      label: "iCloud",
      currencyCode: "AUD",
      financialYearStartMonth: 7
    )
    let session = try ProfileSession(
      resources: .disconnected,
      profile: profile,
      containerManager: containerManager)

    #expect(session.instrumentRegistry != nil)
    #expect(session.cryptoTokenStore != nil)
  }
}
