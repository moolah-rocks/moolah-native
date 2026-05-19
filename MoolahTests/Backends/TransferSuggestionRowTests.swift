import Foundation
import Testing

@testable import Moolah

@Suite("TransferSuggestionRow ⇄ TransferSuggestion")
struct TransferSuggestionRowTests {
  private let idLow = UUID(
    uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1))
  private let idHigh = UUID(
    uuid: (255, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2))
  private let suggestedAt = Date(timeIntervalSince1970: 1_700_000_000)

  @Test("init(domain:).toDomain() round-trips id, transactionIds, suggestedAt")
  func roundTripsDomain() {
    let suggestion = TransferSuggestion(
      transactionIds: [idLow, idHigh], suggestedAt: suggestedAt)
    let back = TransferSuggestionRow(domain: suggestion).toDomain()
    #expect(back.id == suggestion.id)
    #expect(back.transactionIds == suggestion.transactionIds)
    #expect(back.suggestedAt == suggestion.suggestedAt)
  }

  @Test("init(domain:) sorts the two ids so transactionIdA < transactionIdB")
  func sortsIdPair() {
    let ascending = TransferSuggestion(
      transactionIds: [idLow, idHigh], suggestedAt: suggestedAt)
    let descending = TransferSuggestion(
      transactionIds: [idHigh, idLow], suggestedAt: suggestedAt)
    let rowAsc = TransferSuggestionRow(domain: ascending)
    let rowDesc = TransferSuggestionRow(domain: descending)

    #expect(rowAsc.transactionIdA.uuidString < rowAsc.transactionIdB.uuidString)
    #expect(rowAsc.transactionIdA == rowDesc.transactionIdA)
    #expect(rowAsc.transactionIdB == rowDesc.transactionIdB)
    #expect(rowAsc.recordName == rowDesc.recordName)
    #expect(rowAsc.id == rowDesc.id)
  }

  @Test("init(domain:) sets recordName to TransferSuggestionRecord|<id>")
  func recordNameFormat() {
    let suggestion = TransferSuggestion(
      transactionIds: [idLow, idHigh], suggestedAt: suggestedAt)
    let row = TransferSuggestionRow(domain: suggestion)
    #expect(row.recordName == "TransferSuggestionRecord|\(suggestion.id.uuidString)")
  }

  @Test("init(domain:) sets encodedSystemFields to nil")
  func encodedSystemFieldsNil() {
    let suggestion = TransferSuggestion(
      transactionIds: [idLow, idHigh], suggestedAt: suggestedAt)
    let row = TransferSuggestionRow(domain: suggestion)
    #expect(row.encodedSystemFields == nil)
  }
}
