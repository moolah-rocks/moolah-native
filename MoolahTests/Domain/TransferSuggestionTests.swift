import Foundation
import Testing

@testable import Moolah

@Suite("TransferSuggestion")
struct TransferSuggestionTests {
  @Test("id is order-independent for the same two ids")
  func deterministicId() {
    let idA = UUID()
    let idB = UUID()
    let first = TransferSuggestion(transactionIds: [idA, idB], suggestedAt: Date())
    let second = TransferSuggestion(transactionIds: [idB, idA], suggestedAt: Date())
    #expect(first.id == second.id)
  }

  @Test("contentAddressedID(for:) matches the instance id and is order-independent")
  func contentAddressedIDMatchesInstance() {
    let idA = UUID()
    let idB = UUID()
    let instance = TransferSuggestion(transactionIds: [idA, idB], suggestedAt: Date())
    #expect(TransferSuggestion.contentAddressedID(for: [idA, idB]) == instance.id)
    #expect(TransferSuggestion.contentAddressedID(for: [idB, idA]) == instance.id)
  }

  @Test("counterpart(of:) returns the other id")
  func counterpart() {
    let idA = UUID()
    let idB = UUID()
    let suggestion = TransferSuggestion(transactionIds: [idA, idB], suggestedAt: Date())
    #expect(suggestion.counterpart(of: idA) == idB)
    #expect(suggestion.counterpart(of: idB) == idA)
    #expect(suggestion.counterpart(of: UUID()) == nil)
  }
}
