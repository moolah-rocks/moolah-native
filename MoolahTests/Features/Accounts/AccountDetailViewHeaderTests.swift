import Foundation
import Testing

@testable import Moolah

@Suite("AccountDetailView.showsSyncedHeader")
struct AccountDetailViewHeaderTests {
  @Test("a crypto account with a known chain shows the synced header")
  func cryptoWithChainShowsHeader() {
    let account = Account(
      name: "Wallet", type: .crypto, instrument: .AUD,
      valuationMode: .calculatedFromTrades,
      walletAddress: "0x0000000000000000000000000000000000000000", chainId: 1)
    #expect(AccountDetailView.showsSyncedHeader(for: account))
  }

  @Test("a crypto account with no chain hides the header")
  func cryptoWithoutChainHidesHeader() {
    let account = Account(
      name: "Wallet", type: .crypto, instrument: .AUD,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc", chainId: nil)
    #expect(!AccountDetailView.showsSyncedHeader(for: account))
  }

  @Test("an exchange account shows the synced header")
  func exchangeShowsHeader() {
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      valuationMode: .calculatedFromTrades, exchangeProvider: .coinstash)
    #expect(AccountDetailView.showsSyncedHeader(for: account))
  }

  @Test("a bank account hides the header")
  func bankHidesHeader() {
    let account = Account(name: "Checking", type: .bank, instrument: .AUD)
    #expect(!AccountDetailView.showsSyncedHeader(for: account))
  }
}
