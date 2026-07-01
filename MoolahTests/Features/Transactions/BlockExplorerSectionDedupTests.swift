import Foundation
import Testing

@testable import Moolah

/// Tests for `BlockExplorerLink.explorerURLs(for:)`.
///
/// A wallet-imported transaction typically has multiple legs (e.g. an
/// outbound transfer plus its gas leg) that all carry the same on-chain
/// hash, so the canonical block-explorer URL is the same. The detail
/// section must collapse those to a single row — the user thinks of
/// the transaction as one event with one explorer link, not one link
/// per leg.
@Suite("BlockExplorerLink.explorerURLs")
struct BlockExplorerSectionDedupTests {
  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  private let usdc = Instrument.crypto(
    chainId: 1,
    contractAddress: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
    symbol: "USDC", name: "USD Coin", decimals: 6)
  private static let txHash =
    "0x1234567890abcdef1234567890abcdef1234567890abcdef1234567890abcdef"
  private static let otherTxHash =
    "0xabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcdefabcd"

  /// Outbound ERC-20 transfer + gas leg sharing the same on-chain
  /// hash: collapsed to a single explorer URL. Reproduces the user-
  /// reported "two links per transaction" symptom.
  @Test("collapses transfer + gas legs sharing one hash to one URL")
  func collapsesTransferAndGasLegs() {
    let transferLeg = TransactionLeg(
      accountId: UUID(),
      instrument: usdc, quantity: -100,
      externalId: "\(Self.txHash):erc20:0",
      type: .expense)
    let gasLeg = TransactionLeg(
      accountId: UUID(),
      instrument: eth, quantity: Decimal(string: "-0.0015") ?? 0,
      externalId: "\(Self.txHash):gas",
      type: .expense)
    let urls = BlockExplorerLink.explorerURLs(
      for: [transferLeg, gasLeg])
    #expect(urls.count == 1)
    #expect(urls.first?.absoluteString == "https://etherscan.io/tx/\(Self.txHash)")
  }

  /// Multi-event transfer (e.g. swap-like contract emitting two
  /// transfer events to this wallet) plus the gas leg, all sharing a
  /// single hash: still one URL.
  @Test("collapses multiple transfer events from one hash to one URL")
  func collapsesMultipleTransferEvents() {
    let event0 = TransactionLeg(
      accountId: UUID(),
      instrument: usdc, quantity: -100,
      externalId: "\(Self.txHash):erc20:0",
      type: .expense)
    let event1 = TransactionLeg(
      accountId: UUID(),
      instrument: eth, quantity: Decimal(string: "0.05") ?? 0,
      externalId: "\(Self.txHash):external:1",
      type: .income)
    let gasLeg = TransactionLeg(
      accountId: UUID(),
      instrument: eth, quantity: Decimal(string: "-0.0015") ?? 0,
      externalId: "\(Self.txHash):gas",
      type: .expense)
    let urls = BlockExplorerLink.explorerURLs(
      for: [event0, event1, gasLeg])
    #expect(urls.count == 1)
    #expect(urls.first?.absoluteString == "https://etherscan.io/tx/\(Self.txHash)")
  }

  /// Defensive: should the rare path land here where legs span two
  /// distinct on-chain hashes (e.g. a manual merge of two crypto
  /// transactions), each unique URL renders once. Order is first-seen.
  @Test("keeps distinct URLs when legs span more than one hash")
  func keepsDistinctHashes() {
    let legA = TransactionLeg(
      accountId: UUID(),
      instrument: eth, quantity: Decimal(string: "-0.5") ?? 0,
      externalId: "\(Self.txHash):external:0",
      type: .expense)
    let legB = TransactionLeg(
      accountId: UUID(),
      instrument: eth, quantity: Decimal(string: "-0.0015") ?? 0,
      externalId: "\(Self.otherTxHash):gas",
      type: .expense)
    let urls = BlockExplorerLink.explorerURLs(for: [legA, legB])
    #expect(urls.count == 2)
    #expect(urls[0].absoluteString == "https://etherscan.io/tx/\(Self.txHash)")
    #expect(urls[1].absoluteString == "https://etherscan.io/tx/\(Self.otherTxHash)")
  }

  /// Legs without an `externalId` (manually-entered cash transactions)
  /// or without a chain id (non-crypto legs) contribute no rows.
  @Test("skips legs without externalId or chain id")
  func skipsNonCryptoLegs() {
    let manualCashLeg = TransactionLeg(
      accountId: UUID(), instrument: .AUD, quantity: 100, type: .income)
    let cryptoLeg = TransactionLeg(
      accountId: UUID(),
      instrument: eth, quantity: Decimal(string: "-0.5") ?? 0,
      externalId: "\(Self.txHash):external:0",
      type: .expense)
    let urls = BlockExplorerLink.explorerURLs(
      for: [manualCashLeg, cryptoLeg])
    #expect(urls.count == 1)
    #expect(urls.first?.absoluteString == "https://etherscan.io/tx/\(Self.txHash)")
  }

  /// All-non-crypto transaction → no rows, section collapses entirely.
  @Test("returns empty when no leg has an explorer URL")
  func returnsEmptyForNonCryptoTransaction() {
    let leg1 = TransactionLeg(
      accountId: UUID(), instrument: .AUD, quantity: -50, type: .expense)
    let leg2 = TransactionLeg(
      accountId: UUID(), instrument: .AUD, quantity: 50, type: .income)
    #expect(BlockExplorerLink.explorerURLs(for: [leg1, leg2]).isEmpty)
  }

  /// The owning account's chain — not the leg instrument's chain — is
  /// authoritative for a wallet transaction. This simulates the future
  /// unified-identity world where a single instrument spans chains and
  /// `instrument.chainId` no longer identifies the holding's chain: the
  /// account sits on Optimism (10) while the instrument reports Ethereum
  /// (1). The explorer link must point at Optimism, matching the same
  /// `BlockExplorerLink.transactionURL(chainId:externalId:)` the section
  /// uses under the hood.
  @Test("account chain wins over instrument chain")
  func accountChainWinsOverInstrumentChain() {
    let accountId = UUID()
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: eth,  // instrument.chainId == 1 (Ethereum)
      quantity: Decimal(string: "-0.5") ?? 0,
      externalId: "\(Self.txHash):external:0",
      type: .expense)
    let urls = BlockExplorerLink.explorerURLs(for: [leg]) { id in
      id == accountId ? 10 : nil  // account sits on Optimism
    }
    #expect(urls.count == 1)
    #expect(
      urls.first?.absoluteString == "https://optimistic.etherscan.io/tx/\(Self.txHash)")
  }

  /// A leg with no owning account (`accountId == nil`) and a non-crypto
  /// instrument yields no chain from either tier, so it contributes no
  /// explorer link — even though the account-chain resolver is present.
  @Test("no accountId and no instrument chain yields no URL")
  func noAccountIdAndNoInstrumentChainYieldsNoURL() {
    let leg = TransactionLeg(
      accountId: nil,
      instrument: .AUD,
      quantity: 100,
      externalId: "\(Self.txHash):external:0",
      type: .income)
    let urls = BlockExplorerLink.explorerURLs(for: [leg]) { _ in 10 }
    #expect(urls.isEmpty)
  }
}
