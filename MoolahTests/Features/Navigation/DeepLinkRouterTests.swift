import Foundation
import Testing

@testable import Moolah

@Suite("DeepLinkRouter.parse")
struct DeepLinkRouterTests {

  @Test("valid moolah://import?inbox=<uuid> parses to .importInbox")
  func validImportInboxRoute() {
    let id = UUID()
    let url = makeURL("moolah://import?inbox=\(id.uuidString)")
    #expect(DeepLinkRouter.parse(url) == .importInbox(id))
  }

  @Test("invalid uuid is rejected")
  func invalidInboxId() {
    let url = makeURL("moolah://import?inbox=not-a-uuid")
    #expect(DeepLinkRouter.parse(url) == nil)
  }

  @Test("missing inbox query is rejected")
  func missingInboxQuery() {
    let url = makeURL("moolah://import")
    #expect(DeepLinkRouter.parse(url) == nil)
  }

  @Test("wrong scheme is rejected")
  func wrongScheme() {
    let url = makeURL("https://import?inbox=\(UUID().uuidString)")
    #expect(DeepLinkRouter.parse(url) == nil)
  }

  @Test("unknown host is rejected")
  func unknownHost() {
    let url = makeURL("moolah://unknown")
    #expect(DeepLinkRouter.parse(url) == nil)
  }
}
