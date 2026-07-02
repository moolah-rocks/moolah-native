import Foundation
import Testing

@testable import Moolah

/// Wallet-imported legs carry an `externalId` (the on-chain dedup key) and a
/// `counterpartyAddress`. The importer dedups on `(accountId, externalId)`, so
/// if an inspector edit round-trips a transaction through `TransactionDraft` and
/// drops `externalId`, the next wallet sync re-imports the transaction as a
/// duplicate. These tests pin that the draft round-trip preserves both fields.
@Suite("TransactionDraft wallet-import field round-trips")
struct TransactionDraftExternalIdRoundTripTests {
  private let support = TransactionDraftTestSupport()

  @Test
  func roundTripPreservesExternalIdAndCounterpartyAddress() throws {
    let accounts = support.makeAccounts([
      support.makeAccount(id: support.accountA),
      support.makeAccount(id: support.accountB),
    ])
    let original = Transaction(
      id: UUID(),
      date: Date(),
      payee: "On-chain transfer",
      legs: [
        TransactionLeg(
          accountId: support.accountA, instrument: support.instrument,
          quantity: -100, externalId: "0xabc:erc20:0",
          counterpartyAddress: "0xcounterparty", type: .expense),
        TransactionLeg(
          accountId: support.accountB, instrument: support.instrument,
          quantity: -1, externalId: "0xabc:gas", type: .expense),
      ]
    )

    let draft = TransactionDraft(from: original, accounts: accounts)
    let roundTripped = try #require(
      draft.toTransaction(id: original.id, accounts: accounts))

    #expect(roundTripped.legs[0].externalId == "0xabc:erc20:0")
    #expect(roundTripped.legs[0].counterpartyAddress == "0xcounterparty")
    #expect(roundTripped.legs[1].externalId == "0xabc:gas")
    #expect(roundTripped.legs[1].counterpartyAddress == nil)
  }
}
