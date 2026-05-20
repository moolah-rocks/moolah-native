import Foundation
import Testing

@testable import Moolah

@Suite("TransactionStore/SpamFilter")
@MainActor
struct TransactionStoreSpamFilterTests {
  private let accountId = UUID()
  private let spamA = Instrument.crypto(
    chainId: 1,
    contractAddress: "0xspamAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA",
    symbol: "SPAM", name: "Spam Token", decimals: 18)
  private let spamB = Instrument.crypto(
    chainId: 1,
    contractAddress: "0xscamBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB",
    symbol: "SCAM", name: "Scam Token", decimals: 18)
  private let usd = Instrument.fiat(code: "USD")

  private func makeStore() throws -> (CloudKitBackend, TransactionStore) {
    let (backend, _) = try TestBackend.create()
    let store = TransactionStore(
      repository: backend.transactions,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument
    )
    return (backend, store)
  }

  private func leg(_ instrument: Instrument, quantity: Decimal) -> TransactionLeg {
    TransactionLeg(
      accountId: accountId, instrument: instrument, quantity: quantity, type: .trade)
  }

  private func makeTransaction(legs: [TransactionLeg]) throws -> Transaction {
    Transaction(
      date: try TransactionStoreTestSupport.makeDate("2024-01-15"),
      payee: "test",
      legs: legs)
  }

  @Test
  func singleLegAllSpamIsHiddenByDefault() async throws {
    let (_, store) = try makeStore()
    store.setSpamInstruments([spamA])

    _ = await store.create(try makeTransaction(legs: [leg(spamA, quantity: 100)]))
    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.isEmpty)
  }

  @Test
  func multiLegAllSpamIsHiddenByDefault() async throws {
    let (_, store) = try makeStore()
    store.setSpamInstruments([spamA, spamB])

    _ = await store.create(
      try makeTransaction(legs: [leg(spamA, quantity: -50), leg(spamB, quantity: 50)]))
    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.isEmpty)
  }

  @Test
  func mixedLegTransactionIsAlwaysVisible() async throws {
    let (_, store) = try makeStore()
    store.setSpamInstruments([spamA])

    _ = await store.create(
      try makeTransaction(legs: [leg(spamA, quantity: -50), leg(usd, quantity: 100)]))
    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 1)
  }

  @Test
  func togglingShowSpamRepublishesHiddenRows() async throws {
    let (_, store) = try makeStore()
    store.setSpamInstruments([spamA])

    _ = await store.create(try makeTransaction(legs: [leg(spamA, quantity: 100)]))
    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.isEmpty)

    store.showSpam = true
    #expect(store.transactions.count == 1)

    store.showSpam = false
    #expect(store.transactions.isEmpty)
  }

  @Test
  func changingSpamSetReFiltersLive() async throws {
    let (_, store) = try makeStore()
    // Start with empty spam set — transaction is visible.
    _ = await store.create(try makeTransaction(legs: [leg(spamA, quantity: 100)]))
    await store.load(filter: TransactionFilter(accountId: accountId))
    #expect(store.transactions.count == 1)

    // User marks spamA as spam — transaction should disappear.
    store.setSpamInstruments([spamA])
    #expect(store.transactions.isEmpty)
  }

  @Test
  func emptySpamSetShowsAllTransactions() async throws {
    let (_, store) = try makeStore()
    // spamInstruments defaults to empty.
    _ = await store.create(try makeTransaction(legs: [leg(spamA, quantity: 100)]))
    _ = await store.create(try makeTransaction(legs: [leg(usd, quantity: 200)]))
    await store.load(filter: TransactionFilter(accountId: accountId))

    #expect(store.transactions.count == 2)
  }
}
