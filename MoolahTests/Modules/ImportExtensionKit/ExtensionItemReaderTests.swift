import Foundation
import Testing

@testable import ImportExtensionKit

@Suite("ExtensionItemReader.decode")
struct ExtensionItemReaderTests {

  private let validJSON: [String: Any] = [
    "schemaVersion": 1,
    "sourceHost": "chase.com",
    "sourceURL": "https://chase.com/",
    "capturedAt": "2026-05-30T10:00:00Z",
    "rows": [["date": "2026-05-29", "amount": "1.00", "description": "x"]],
  ]

  @Test("decodes a well-formed dictionary")
  func decodesValid() throws {
    let payload = try ExtensionItemReader.decode(jsResult: validJSON)
    #expect(payload.sourceHost == "chase.com")
    #expect(payload.rows.count == 1)
  }

  @Test("error sentinel from dispatcher throws .noPlugin")
  func dispatcherErrorBecomesNoPlugin() {
    let dict: [String: Any] = ["error": "no-plugin", "host": "x.com"]
    #expect(throws: ExtensionItemReaderError.noPlugin) {
      try ExtensionItemReader.decode(jsResult: dict)
    }
  }

  @Test("unsupported schemaVersion throws .schemaMismatch")
  func schemaMismatch() {
    var dict = validJSON
    dict["schemaVersion"] = 2
    #expect(throws: ExtensionItemReaderError.schemaMismatch) {
      try ExtensionItemReader.decode(jsResult: dict)
    }
  }
}
