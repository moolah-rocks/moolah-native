import Foundation
import Testing

@testable import Moolah

@Suite("AccountBucket")
struct AccountBucketTests {
  @Test
  func rawValuesAreStableTokens() {
    #expect(AccountBucket.current.rawValue == "current")
    #expect(AccountBucket.investments.rawValue == "investments")
  }

  @Test
  func allCasesIsExhaustive() {
    #expect(Set(AccountBucket.allCases) == [.current, .investments])
  }

  @Test
  func decodesFromStableTokens() throws {
    let json = Data(#"["current","investments"]"#.utf8)
    let buckets = try JSONDecoder().decode([AccountBucket].self, from: json)
    #expect(buckets == [.current, .investments])
  }

  @Test
  func throwsOnUnknownRawValue() {
    let json = Data(#""savings""#.utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(AccountBucket.self, from: json)
    }
  }
}
