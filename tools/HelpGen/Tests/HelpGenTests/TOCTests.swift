import Foundation
import Testing

@testable import HelpGen

@Suite("TOC decoding")
struct TOCTests {
  @Test("decodes a single-entry TOC")
  func decodesSingleEntry() throws {
    let json = """
      {
        "version": "1",
        "entries": [
          { "slug": "welcome", "title": "Welcome to Moolah", "parent": null }
        ]
      }
      """.data(using: .utf8)!
    let toc = try JSONDecoder().decode(TOC.self, from: json)
    #expect(toc.version == "1")
    #expect(toc.entries.count == 1)
    #expect(toc.entries[0].slug == "welcome")
    #expect(toc.entries[0].title == "Welcome to Moolah")
    #expect(toc.entries[0].parent == nil)
  }

  @Test("decodes nested entries via parent")
  func decodesParent() throws {
    let json = """
      {
        "version": "1",
        "entries": [
          { "slug": "accounts", "title": "Accounts", "parent": null },
          { "slug": "creating-an-account", "title": "Creating an Account", "parent": "accounts" }
        ]
      }
      """.data(using: .utf8)!
    let toc = try JSONDecoder().decode(TOC.self, from: json)
    #expect(toc.entries[1].parent == "accounts")
  }

  @Test("rejects malformed JSON")
  func rejectsMalformed() {
    let json = #"{ "version": "1" }"#.data(using: .utf8)!
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode(TOC.self, from: json)
    }
  }
}
