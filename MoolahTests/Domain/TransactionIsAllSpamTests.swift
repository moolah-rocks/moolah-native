import Foundation
import Testing

@testable import Moolah

@Suite("Transaction.isAllSpam(in:)")
struct TransactionIsAllSpamTests {
  let aud = Instrument.AUD
  let usd = Instrument.fiat(code: "USD")
  let spamA = Instrument.crypto(
    chainId: 1, contractAddress: "0xspama", symbol: "SPAM", name: "Spam Token", decimals: 18)
  let spamB = Instrument.crypto(
    chainId: 1, contractAddress: "0xspamb", symbol: "SCAM", name: "Scam Token", decimals: 18)
  let account = UUID()

  private func leg(_ instrument: Instrument, quantity: Decimal) -> TransactionLeg {
    TransactionLeg(
      accountId: account, instrument: instrument, quantity: quantity, type: .trade)
  }

  private func transaction(legs: [TransactionLeg]) -> Transaction {
    Transaction(date: Date(timeIntervalSince1970: 0), legs: legs)
  }

  @Test
  func singleSpamLegIsAllSpam() {
    let subject = transaction(legs: [leg(spamA, quantity: 100)])
    #expect(subject.isAllSpam(in: [spamA]))
  }

  @Test
  func multipleSpamLegsAllInSetIsAllSpam() {
    let subject = transaction(legs: [leg(spamA, quantity: -50), leg(spamB, quantity: 50)])
    #expect(subject.isAllSpam(in: [spamA, spamB]))
  }

  @Test
  func mixedSpamAndNonSpamIsNotAllSpam() {
    let subject = transaction(legs: [leg(spamA, quantity: -50), leg(usd, quantity: 100)])
    #expect(!subject.isAllSpam(in: [spamA]))
  }

  @Test
  func nonSpamOnlyIsNotAllSpam() {
    let subject = transaction(legs: [leg(usd, quantity: 100)])
    #expect(!subject.isAllSpam(in: [spamA]))
  }

  @Test
  func emptyLegsIsNotAllSpam() {
    let subject = transaction(legs: [])
    #expect(!subject.isAllSpam(in: [spamA]))
  }

  @Test
  func emptySpamSetIsNotAllSpam() {
    let subject = transaction(legs: [leg(spamA, quantity: 100)])
    #expect(!subject.isAllSpam(in: []))
  }

  @Test
  func spamLegOutsideSpamSetIsNotAllSpam() {
    let subject = transaction(legs: [leg(spamA, quantity: 100)])
    #expect(!subject.isAllSpam(in: [spamB]))
  }
}
