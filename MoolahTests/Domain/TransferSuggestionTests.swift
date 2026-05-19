import Foundation
import Testing

@testable import Moolah

@Suite("TransferSuggestion")
struct TransferSuggestionTests {
  private let txOne = makeUUID("00000000-0000-0000-0000-000000000001")
  private let txTwo = makeUUID("00000000-0000-0000-0000-000000000002")
  private let txThree = makeUUID("00000000-0000-0000-0000-000000000003")
  private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("contentAddressedID(for:) equals the id of an instance built from the same pair")
  func contentAddressedIDMatchesInstance() {
    let instance = TransferSuggestion(transactionIds: [txOne, txTwo], suggestedAt: stamp)
    #expect(TransferSuggestion.contentAddressedID(for: [txOne, txTwo]) == instance.id)
  }

  @Test("distinct transaction pairs produce distinct ids")
  func distinctPairsDistinctIds() {
    let first = TransferSuggestion(transactionIds: [txOne, txTwo], suggestedAt: stamp)
    let second = TransferSuggestion(transactionIds: [txOne, txThree], suggestedAt: stamp)
    #expect(first.id != second.id)
  }

  @Test("Codable round-trip preserves id and transactionIds")
  func codableRoundTrip() throws {
    let original = TransferSuggestion(transactionIds: [txOne, txTwo], suggestedAt: stamp)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(TransferSuggestion.self, from: data)
    #expect(decoded.id == original.id)
    #expect(decoded.transactionIds == original.transactionIds)
    #expect(decoded.suggestedAt == original.suggestedAt)
  }

  @Test("counterpart(of:) returns the other id in the pair")
  func counterpartReturnsOther() {
    let suggestion = TransferSuggestion(transactionIds: [txOne, txTwo], suggestedAt: stamp)
    #expect(suggestion.counterpart(of: txOne) == txTwo)
    #expect(suggestion.counterpart(of: txTwo) == txOne)
  }

  @Test("counterpart(of:) returns nil for a non-member")
  func counterpartNilForNonMember() {
    let suggestion = TransferSuggestion(transactionIds: [txOne, txTwo], suggestedAt: stamp)
    #expect(suggestion.counterpart(of: txThree) == nil)
  }
}
