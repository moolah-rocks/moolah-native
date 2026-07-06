import Foundation
import Testing

@testable import Moolah

@Suite("AccountDetailLayout.showsSyncedHeader")
struct AccountDetailViewHeaderTests {
  @Test("a crypto account with a known chain shows the synced header")
  func cryptoWithChainShowsHeader() {
    let account = Account(
      name: "Wallet", type: .crypto, instrument: .AUD,
      valuationMode: .calculatedFromTrades,
      walletAddress: "0x0000000000000000000000000000000000000000", chainId: 1)
    #expect(AccountDetailLayout.showsSyncedHeader(for: account))
  }

  @Test("a crypto account with no chain hides the header")
  func cryptoWithoutChainHidesHeader() {
    let account = Account(
      name: "Wallet", type: .crypto, instrument: .AUD,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc", chainId: nil)
    #expect(!AccountDetailLayout.showsSyncedHeader(for: account))
  }

  @Test("an exchange account shows the synced header")
  func exchangeShowsHeader() {
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      valuationMode: .calculatedFromTrades, exchangeProvider: .coinstash)
    #expect(AccountDetailLayout.showsSyncedHeader(for: account))
  }

  @Test("a bank account hides the header")
  func bankHidesHeader() {
    let account = Account(name: "Checking", type: .bank, instrument: .AUD)
    #expect(!AccountDetailLayout.showsSyncedHeader(for: account))
  }

  // Account groups never reach this helper — the group dispatch passes
  // `syncedHeaderAccount: nil`, gating the header at the call site rather
  // than via this predicate.
  @Test("an investment account hides the synced header")
  func investmentHidesHeader() {
    let account = Account(
      name: "Portfolio", type: .investment, instrument: .AUD,
      valuationMode: .calculatedFromTrades)
    #expect(!AccountDetailLayout.showsSyncedHeader(for: account))
  }
}
