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

  @Test("decodes top-level scalar fields")
  func decodesTopLevelFields() throws {
    let payload = try JSONDecoder.importPayload.decode(
      ImportPayload.self, from: Data(sampleJSON.utf8))
    #expect(payload.schemaVersion == 1)
    #expect(payload.sourceHost == "chase.com")
  }

  @Test("decodes rows array correctly")
  func decodesRowsArray() throws {
    let payload = try JSONDecoder.importPayload.decode(
      ImportPayload.self, from: Data(sampleJSON.utf8))
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

  private func makePayload(sourceURL: String) -> ImportPayload {
    ImportPayload(
      schemaVersion: 1, sourceHost: "chase.com", sourceURL: sourceURL,
      capturedAt: Date(timeIntervalSince1970: 0),
      accountHint: nil, currencyHint: nil, rows: [])
  }

  @Test("strippingSourceURLQueryAndFragment removes query string")
  func stripsQueryString() {
    let stripped = makePayload(sourceURL: "https://chase.com/x?token=abc")
      .strippingSourceURLQueryAndFragment()
    #expect(stripped.sourceURL == "https://chase.com/x")
  }

  @Test("strippingSourceURLQueryAndFragment removes fragment")
  func stripsFragment() {
    let stripped = makePayload(sourceURL: "https://chase.com/x#section")
      .strippingSourceURLQueryAndFragment()
    #expect(stripped.sourceURL == "https://chase.com/x")
  }

  @Test("strippingSourceURLQueryAndFragment removes both query and fragment")
  func stripsBoth() {
    let stripped = makePayload(sourceURL: "https://chase.com/x?token=abc#foo")
      .strippingSourceURLQueryAndFragment()
    #expect(stripped.sourceURL == "https://chase.com/x")
  }

  @Test("strippingSourceURLQueryAndFragment leaves clean URL unchanged")
  func cleanURLUnchanged() {
    let stripped = makePayload(sourceURL: "https://chase.com/x")
      .strippingSourceURLQueryAndFragment()
    #expect(stripped.sourceURL == "https://chase.com/x")
  }

  @Test("strippingSourceURLQueryAndFragment preserves all other fields")
  func preservesOtherFields() {
    let original = ImportPayload(
      schemaVersion: 1, sourceHost: "chase.com",
      sourceURL: "https://chase.com/x?t=1",
      capturedAt: Date(timeIntervalSince1970: 1_716_000_000),
      accountHint: "1234", currencyHint: "USD",
      rows: [
        ImportPayloadRow(date: "2026-05-29", amount: "1.00", description: "x")
      ])
    let stripped = original.strippingSourceURLQueryAndFragment()
    #expect(stripped.schemaVersion == original.schemaVersion)
    #expect(stripped.sourceHost == original.sourceHost)
    #expect(stripped.capturedAt == original.capturedAt)
    #expect(stripped.accountHint == original.accountHint)
    #expect(stripped.currencyHint == original.currencyHint)
    #expect(stripped.rows == original.rows)
  }
}
