import Foundation
import Testing

@testable import Moolah

@Suite("NavigationDestination Codable wire format")
struct NavigationDestinationCodableTests {

  // The encoder must produce stable, sorted keys for byte-equality
  // assertions. Tests configure their own encoder per case rather than
  // sharing one, so each test reads as a self-contained spec.

  private func encoded(_ destination: NavigationDestination) throws -> [String: Any] {
    let data = try JSONEncoder().encode(destination)
    let raw = try JSONSerialization.jsonObject(with: data)
    return try #require(raw as? [String: Any])
  }

  private func decoded(_ json: [String: Any]) throws -> NavigationDestination {
    let data = try JSONSerialization.data(withJSONObject: json)
    return try JSONDecoder().decode(NavigationDestination.self, from: data)
  }

  @Test("accounts encodes as {type: accounts}")
  func accountsWireShape() throws {
    let json = try encoded(.accounts)
    #expect(json.count == 1)
    #expect(json["type"] as? String == "accounts")
  }

  @Test("account encodes as {type: account, id: <uuid-string>}")
  func accountWireShape() throws {
    let id = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
    let json = try encoded(.account(id))
    #expect(json.count == 2)
    #expect(json["type"] as? String == "account")
    #expect(json["id"] as? String == "11111111-1111-1111-1111-111111111111")
  }

  @Test("transaction encodes as {type: transaction, id: <uuid-string>}")
  func transactionWireShape() throws {
    let id = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))
    let json = try encoded(.transaction(id))
    #expect(json.count == 2)
    #expect(json["type"] as? String == "transaction")
    #expect(json["id"] as? String == "22222222-2222-2222-2222-222222222222")
  }

  @Test("earmarks encodes as {type: earmarks}")
  func earmarksWireShape() throws {
    let json = try encoded(.earmarks)
    #expect(json.count == 1)
    #expect(json["type"] as? String == "earmarks")
  }

  @Test("earmark encodes as {type: earmark, id: <uuid-string>}")
  func earmarkWireShape() throws {
    let id = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
    let json = try encoded(.earmark(id))
    #expect(json.count == 2)
    #expect(json["type"] as? String == "earmark")
    #expect(json["id"] as? String == "33333333-3333-3333-3333-333333333333")
  }

  @Test("analysis with non-nil params encodes both fields")
  func analysisFullWireShape() throws {
    let json = try encoded(.analysis(history: 12, forecast: 6))
    #expect(json.count == 3)
    #expect(json["type"] as? String == "analysis")
    #expect(json["history"] as? Int == 12)
    #expect(json["forecast"] as? Int == 6)
  }

  @Test("analysis with nil params omits both fields")
  func analysisNilWireShape() throws {
    let json = try encoded(.analysis(history: nil, forecast: nil))
    #expect(json.count == 1)
    #expect(json["type"] as? String == "analysis")
    #expect(json["history"] == nil)
    #expect(json["forecast"] == nil)
  }

  @Test("analysis with one nil param omits only that field")
  func analysisPartialWireShape() throws {
    let json = try encoded(.analysis(history: 12, forecast: nil))
    #expect(json.count == 2)
    #expect(json["type"] as? String == "analysis")
    #expect(json["history"] as? Int == 12)
    #expect(json["forecast"] == nil)
  }

  @Test("reports with non-nil params encodes both fields")
  func reportsFullWireShape() throws {
    let from = Date(timeIntervalSince1970: 1_700_000_000)
    let to = Date(timeIntervalSince1970: 1_800_000_000)
    let json = try encoded(.reports(from: from, to: to))
    #expect(json.count == 3)
    #expect(json["type"] as? String == "reports")
    // JSONEncoder uses Double-seconds-since-1970 by default.
    #expect(json["from"] != nil)
    #expect(json["to"] != nil)
  }

  @Test("reports with nil params omits both fields")
  func reportsNilWireShape() throws {
    let json = try encoded(.reports(from: nil, to: nil))
    #expect(json.count == 1)
    #expect(json["type"] as? String == "reports")
  }

  @Test("categories encodes as {type: categories}")
  func categoriesWireShape() throws {
    let json = try encoded(.categories)
    #expect(json.count == 1)
    #expect(json["type"] as? String == "categories")
  }

  @Test("upcoming encodes as {type: upcoming}")
  func upcomingWireShape() throws {
    let json = try encoded(.upcoming)
    #expect(json.count == 1)
    #expect(json["type"] as? String == "upcoming")
  }

  @Test("decoding an unknown type discriminator throws")
  func unknownTypeThrows() {
    let json: [String: Any] = ["type": "somethingelse"]
    #expect(throws: DecodingError.self) {
      _ = try decoded(json)
    }
  }

  @Test("decoding account without id throws")
  func accountMissingIDThrows() {
    let json: [String: Any] = ["type": "account"]
    #expect(throws: DecodingError.self) {
      _ = try decoded(json)
    }
  }
}
