import Foundation
import Testing

@testable import ImportExtensionKit

@Suite("ImportPayload")
struct ImportPayloadTests {

  private let sampleJSON = #"""
    {
      "schemaVersion": 1,
      "sourceHost": "chase.com",
      "sourceURL": "https://secure.chase.com/web/auth/dashboard",
      "capturedAt": "2026-05-30T10:15:00Z",
      "accountHint": "1234",
      "currencyHint": "USD",
      "rows": [
        {
          "date": "2026-05-29",
          "amount": "-42.50",
          "description": "Coffee shop",
          "balance": "1234.56",
          "reference": "TXN-0001"
        }
      ]
    }
    """#

  @Test("decodes a well-formed payload")
  func decodesWellFormed() throws {
    let payload = try JSONDecoder.importPayload.decode(
      ImportPayload.self, from: Data(sampleJSON.utf8))
    #expect(payload.schemaVersion == 1)
    #expect(payload.sourceHost == "chase.com")
    #expect(payload.rows.count == 1)
    #expect(payload.rows[0].amount == "-42.50")
    #expect(payload.rows[0].reference == "TXN-0001")
  }

  @Test("encode → decode round-trip preserves all fields")
  func roundTrip() throws {
    let original = try JSONDecoder.importPayload.decode(
      ImportPayload.self, from: Data(sampleJSON.utf8))
    let encoded = try JSONEncoder.importPayload.encode(original)
    let decoded = try JSONDecoder.importPayload.decode(ImportPayload.self, from: encoded)
    #expect(decoded == original)
  }

  @Test("optional fields decode as nil when absent")
  func optionalFieldsNilWhenAbsent() throws {
    let json = #"""
      { "schemaVersion": 1, "sourceHost": "x.com", "sourceURL": "https://x.com",
        "capturedAt": "2026-05-30T10:15:00Z",
        "rows": [ { "date": "2026-05-29", "amount": "1", "description": "y" } ] }
      """#
    let payload = try JSONDecoder.importPayload.decode(
      ImportPayload.self, from: Data(json.utf8))
    #expect(payload.accountHint == nil)
    #expect(payload.currencyHint == nil)
    #expect(payload.rows[0].balance == nil)
    #expect(payload.rows[0].reference == nil)
  }

  @Test("decode rejects unknown schemaVersion")
  func rejectsFutureSchema() {
    let json = sampleJSON.replacingOccurrences(
      of: "\"schemaVersion\": 1", with: "\"schemaVersion\": 2")
    #expect(throws: ImportPayloadDecodingError.unsupportedSchemaVersion(2)) {
      try JSONDecoder.importPayload.decode(ImportPayload.self, from: Data(json.utf8))
    }
  }
}
