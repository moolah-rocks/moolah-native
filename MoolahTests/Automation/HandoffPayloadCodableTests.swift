import Foundation
import Testing

@testable import Moolah

@Suite("HandoffPayload Codable")
struct HandoffPayloadCodableTests {

  private func roundTrip(_ payload: HandoffPayload) throws -> HandoffPayload {
    let data = try JSONEncoder().encode(payload)
    return try JSONDecoder().decode(HandoffPayload.self, from: data)
  }

  @Test("accounts case round-trips")
  func accountsRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .accounts)
    #expect(try roundTrip(payload) == payload)
  }

  @Test("account(id) case round-trips")
  func accountRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .account(UUID()))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("transaction(id) case round-trips")
  func transactionRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .transaction(UUID()))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("earmarks case round-trips")
  func earmarksRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .earmarks)
    #expect(try roundTrip(payload) == payload)
  }

  @Test("earmark(id) case round-trips")
  func earmarkRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .earmark(UUID()))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("analysis with both params round-trips")
  func analysisWithParamsRoundTrips() throws {
    let payload = HandoffPayload(
      profileID: UUID(),
      destination: .analysis(history: 12, forecast: 6))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("analysis with nil params round-trips")
  func analysisNilParamsRoundTrips() throws {
    let payload = HandoffPayload(
      profileID: UUID(),
      destination: .analysis(history: nil, forecast: nil))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("reports with both params round-trips")
  func reportsWithParamsRoundTrips() throws {
    let from = Date(timeIntervalSince1970: 1_700_000_000)
    let to = Date(timeIntervalSince1970: 1_800_000_000)
    let payload = HandoffPayload(
      profileID: UUID(),
      destination: .reports(from: from, to: to))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("reports with nil params round-trips")
  func reportsNilParamsRoundTrips() throws {
    let payload = HandoffPayload(
      profileID: UUID(),
      destination: .reports(from: nil, to: nil))
    #expect(try roundTrip(payload) == payload)
  }

  @Test("categories case round-trips")
  func categoriesRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .categories)
    #expect(try roundTrip(payload) == payload)
  }

  @Test("upcoming case round-trips")
  func upcomingRoundTrips() throws {
    let payload = HandoffPayload(profileID: UUID(), destination: .upcoming)
    #expect(try roundTrip(payload) == payload)
  }
}
