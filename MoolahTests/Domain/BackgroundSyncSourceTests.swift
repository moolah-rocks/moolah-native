import Testing

@testable import Moolah

@Suite("BackgroundSyncSource")
struct BackgroundSyncSourceTests {
  @Test
  func parserIdentifierRoundTrips() {
    for source in BackgroundSyncSource.allCases {
      #expect(BackgroundSyncSource(parserIdentifier: source.parserIdentifier) == source)
    }
  }

  @Test
  func unknownParserIdentifierResolvesToNil() {
    #expect(BackgroundSyncSource(parserIdentifier: "generic-bank") == nil)
    #expect(BackgroundSyncSource(parserIdentifier: "") == nil)
    #expect(BackgroundSyncSource(parserIdentifier: "web/example.com") == nil)
  }

  @Test
  func displayNames() {
    #expect(BackgroundSyncSource.wallet.displayName == "Wallet")
    #expect(BackgroundSyncSource.coinstash.displayName == "Coinstash")
  }
}
