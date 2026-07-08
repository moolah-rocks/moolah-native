import Foundation
import Testing

@testable import Moolah

@Suite("Profile")
struct ProfileTests {
  @Test("JSON round-trip preserves all fields")
  func jsonRoundTrip() throws {
    let profile = Profile(
      id: makeUUID("12345678-1234-1234-1234-123456789ABC"),
      label: "Work Profile",
      currencyCode: "USD",
      financialYearStartMonth: 1,
      createdAt: Date(timeIntervalSince1970: 1_700_000_000)
    )

    let data = try JSONEncoder().encode(profile)
    let decoded = try JSONDecoder().decode(Profile.self, from: data)

    #expect(decoded == profile)
    #expect(decoded.id == profile.id)
    #expect(decoded.label == "Work Profile")
    #expect(decoded.currencyCode == "USD")
    #expect(decoded.financialYearStartMonth == 1)
    #expect(decoded.defaultTaxOwnerId == profile.defaultTaxOwnerId)
    #expect(decoded.createdAt == Date(timeIntervalSince1970: 1_700_000_000))
  }

  @Test("defaults: AUD currency and July FY start")
  func defaults() {
    let profile = Profile(label: "My Profile")

    #expect(!profile.id.uuidString.isEmpty)
    #expect(profile.currencyCode == "AUD")
    #expect(profile.financialYearStartMonth == 7)
    #expect(profile.defaultTaxOwnerId == TaxOwner.defaultOwnerId(for: profile.id))
    #expect(profile.instrument == .AUD)
    #expect(profile.createdAt.timeIntervalSince1970 > 0)
  }

  @Test("instrument computed property maps known codes")
  func instrumentMapping() {
    var profile = Profile(label: "Test")

    profile.currencyCode = "AUD"
    #expect(profile.instrument == .AUD)

    profile.currencyCode = "USD"
    #expect(profile.instrument == .USD)

    profile.currencyCode = "GBP"
    #expect(profile.instrument.id == "GBP")
  }

  @Test("equality compares all fields")
  func equality() {
    let id = UUID()
    let date = Date()
    let first = Profile(id: id, label: "A", createdAt: date)
    let second = Profile(id: id, label: "A", createdAt: date)
    let third = Profile(id: id, label: "B", createdAt: date)

    #expect(first == second)
    #expect(first != third)
  }

  @Test("explicit default tax owner id is preserved")
  func explicitDefaultTaxOwnerId() {
    let ownerId = UUID()
    let profile = Profile(label: "Family", defaultTaxOwnerId: ownerId)

    #expect(profile.defaultTaxOwnerId == ownerId)
  }

  @Test("legacy JSON without default tax owner id derives deterministic default")
  func legacyJSONWithoutDefaultTaxOwnerId() throws {
    let profileId = makeUUID("12345678-1234-1234-1234-123456789ABC")
    let json = Data(
      #"""
      {"id":"\#(profileId.uuidString)",
       "label":"Legacy",
       "currencyCode":"AUD",
       "financialYearStartMonth":7,
       "createdAt":700000000,
       "dataFormatVersion":0}
      """#.utf8)

    let profile = try JSONDecoder().decode(Profile.self, from: json)

    #expect(profile.defaultTaxOwnerId == TaxOwner.defaultOwnerId(for: profileId))
  }
}
