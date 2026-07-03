import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.backgroundSyncedLegSources()")
struct TransactionBackgroundSyncSourcesTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: "0xeth", symbol: "ETH", name: "Ether", decimals: 18)

  private func origin(_ parserIdentifier: String) -> ImportOrigin {
    ImportOrigin(
      rawDescription: "", rawAmount: 0, importedAt: Date(timeIntervalSince1970: 0),
      importSessionId: UUID(), parserIdentifier: parserIdentifier)
  }

  private func leg(
    _ id: UUID = UUID(), quantity: Decimal, externalId: String?
  ) -> TransactionLeg {
    TransactionLeg(
      id: id, accountId: UUID(), instrument: eth, quantity: quantity,
      externalId: externalId, type: .transfer)
  }

  private func transaction(
    legs: [TransactionLeg], origin: TransactionImportOrigin?
  ) -> Transaction {
    Transaction(date: Date(timeIntervalSince1970: 0), legs: legs, importOrigin: origin)
  }

  @Test
  func manualTransactionHasNoSyncedLegs() {
    let subject = transaction(
      legs: [leg(quantity: 1, externalId: "0xhash")], origin: nil)
    #expect(subject.backgroundSyncedLegSources().isEmpty)
  }

  @Test
  func singleWalletOriginMapsSyncedLeg() {
    let synced = leg(quantity: 1, externalId: "0xhash")
    let subject = transaction(
      legs: [synced], origin: .single(origin("alchemy-wallet-sync")))
    #expect(subject.backgroundSyncedLegSources() == [synced.id: .wallet])
  }

  @Test
  func singleCoinstashOriginMapsSyncedLeg() {
    let synced = leg(quantity: 1, externalId: "order-42")
    let subject = transaction(
      legs: [synced], origin: .single(origin("coinstash")))
    #expect(subject.backgroundSyncedLegSources() == [synced.id: .coinstash])
  }

  @Test
  func csvImportOriginIsNotBackgroundSync() {
    // A user-initiated bank/CSV import carries an origin and could even set an
    // externalId, but its parserIdentifier is not a background-sync source.
    let imported = leg(quantity: 1, externalId: "row-7")
    let subject = transaction(
      legs: [imported], origin: .single(origin("generic-bank")))
    #expect(subject.backgroundSyncedLegSources().isEmpty)
  }

  @Test
  func manuallyAddedLegOnSyncedTransactionIsNotFlagged() {
    let synced = leg(quantity: -1, externalId: "order-1")
    let manual = leg(quantity: 1, externalId: nil)
    let subject = transaction(
      legs: [synced, manual], origin: .single(origin("coinstash")))
    #expect(subject.backgroundSyncedLegSources() == [synced.id: .coinstash])
  }

  @Test
  func mergedTransferMapsEachSideToItsOwnSource() {
    let outgoing = leg(quantity: -1, externalId: "0xhash")  // wallet side
    let incoming = leg(quantity: 1, externalId: "order-9")  // exchange side
    let merged = MergedImportOrigin(
      outgoing: origin("alchemy-wallet-sync"), incoming: origin("coinstash"))
    let subject = transaction(legs: [outgoing, incoming], origin: .merged(merged))
    #expect(
      subject.backgroundSyncedLegSources() == [
        outgoing.id: .wallet, incoming.id: .coinstash,
      ])
  }

  @Test
  func mergedWithOneUnknownSideFallsBackToTheKnownSource() {
    // Incoming side had no import origin (a manually-created counterpart);
    // both synced legs fall back to the one resolved source.
    let outgoing = leg(quantity: -1, externalId: "order-1")
    let incoming = leg(quantity: 1, externalId: "order-2")
    let merged = MergedImportOrigin(outgoing: origin("coinstash"), incoming: nil)
    let subject = transaction(legs: [outgoing, incoming], origin: .merged(merged))
    #expect(
      subject.backgroundSyncedLegSources() == [
        outgoing.id: .coinstash, incoming.id: .coinstash,
      ])
  }

  @Test
  func mergedWithOnlyIncomingSourceFallsBackToIncoming() {
    // Outgoing side had no import origin; both synced legs fall back to the
    // one resolved source (exercises the `?? incoming` tail of the fallback).
    let outgoing = leg(quantity: -1, externalId: "order-1")
    let incoming = leg(quantity: 1, externalId: "order-2")
    let merged = MergedImportOrigin(outgoing: nil, incoming: origin("coinstash"))
    let subject = transaction(legs: [outgoing, incoming], origin: .merged(merged))
    #expect(
      subject.backgroundSyncedLegSources() == [
        outgoing.id: .coinstash, incoming.id: .coinstash,
      ])
  }

  @Test
  func mergedWithBothSidesUnknownHasNoSyncedLegs() {
    let outgoing = leg(quantity: -1, externalId: "row-1")
    let incoming = leg(quantity: 1, externalId: "row-2")
    let merged = MergedImportOrigin(outgoing: origin("generic-bank"), incoming: nil)
    let subject = transaction(legs: [outgoing, incoming], origin: .merged(merged))
    #expect(subject.backgroundSyncedLegSources().isEmpty)
  }
}
