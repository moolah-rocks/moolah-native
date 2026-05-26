import Foundation
import Testing

@testable import Moolah

@Suite("aggregatedGroupPositions")
struct GroupAggregatedPositionsTests {

  private func makeAccount(
    id: UUID = UUID(), positions: [Position] = []
  ) -> Account {
    Account(
      id: id, name: "Account", type: .crypto,
      instrument: .defaultTestInstrument,
      positions: positions)
  }

  @Test("members holding the same instrument coalesce to one row")
  func sameInstrumentCoalesces() {
    let memberA = makeAccount(positions: [
      Position(instrument: .defaultTestInstrument, quantity: 100)
    ])
    let memberB = makeAccount(positions: [
      Position(instrument: .defaultTestInstrument, quantity: 250)
    ])
    let accounts = Accounts(from: [memberA, memberB])

    let result = aggregatedGroupPositions(
      across: [memberA.id, memberB.id], in: accounts)

    #expect(result.count == 1)
    #expect(result.first?.instrument == .defaultTestInstrument)
    #expect(result.first?.quantity == 350)
  }

  @Test("multi-instrument groups expose a row per instrument")
  func multiInstrumentRows() {
    let usd = Instrument.fiat(code: "USD")
    let memberA = makeAccount(positions: [
      Position(instrument: .defaultTestInstrument, quantity: 100)
    ])
    let memberB = makeAccount(positions: [
      Position(instrument: usd, quantity: 50)
    ])
    let accounts = Accounts(from: [memberA, memberB])

    let result = aggregatedGroupPositions(
      across: [memberA.id, memberB.id], in: accounts)

    #expect(result.count == 2)
    #expect(Set(result.map(\.instrument)) == [.defaultTestInstrument, usd])
  }

  @Test("unknown ids are skipped silently")
  func unknownIdsSkipped() {
    let member = makeAccount(positions: [
      Position(instrument: .defaultTestInstrument, quantity: 100)
    ])
    let accounts = Accounts(from: [member])

    let result = aggregatedGroupPositions(
      across: [member.id, UUID()], in: accounts)

    #expect(result.count == 1)
    #expect(result.first?.quantity == 100)
  }

  @Test("empty member list returns empty positions")
  func emptyMembers() {
    let accounts = Accounts(from: [])
    #expect(aggregatedGroupPositions(across: [], in: accounts).isEmpty)
  }

  @Test("members with no positions contribute nothing")
  func emptyPositions() {
    let member = makeAccount(positions: [])
    let accounts = Accounts(from: [member])
    #expect(aggregatedGroupPositions(across: [member.id], in: accounts).isEmpty)
  }
}
