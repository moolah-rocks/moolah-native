import Foundation
import Testing

@testable import Moolah

/// Unit tests for the local, name-based crypto spam heuristics (issue #1102,
/// bullets 4 & 5: URL/domain in the name, and airdrop/"invitation" scam
/// phrasing). The heuristics are deterministic and operate purely on the
/// token's name and symbol — no network. They are only consulted for tokens
/// that did not resolve to a price provider, so the false-positive risk for
/// domain-branded but legitimately listed tokens is handled by the caller.
@Suite("CryptoSpamHeuristics")
struct CryptoSpamHeuristicsTests {
  // MARK: - URL / domain in the name

  @Test(
    "Explicit URLs and domains in the name are flagged",
    arguments: [
      "Visit https://op-rewards.xyz to claim",
      "claim at usdc-claim.com",
      "www.free-eth.io",
      "Rewards | t.me/scamchannel",
      "ETHFI.app airdrop",
      "1000 USDC at sushi-claim.finance",
      "Bonus pool — claimusdc.top",
    ])
  func flagsEmbeddedDomains(name: String) {
    #expect(CryptoSpamHeuristics.spamSignal(name: name, symbol: nil) == .embeddedURL)
  }

  @Test("A domain in the symbol is flagged even when the name is clean")
  func flagsDomainInSymbol() {
    #expect(
      CryptoSpamHeuristics.spamSignal(name: "Reward", symbol: "claim.com") == .embeddedURL)
  }

  // MARK: - Scam keyword phrasing

  @Test(
    "Airdrop / invitation / voucher scam phrasing is flagged",
    arguments: [
      "Invitation Token",
      "You can claim your airdrop",
      "USDC Voucher",
      "Free giveaway — redeem now",
      "Presale access token",
      "OP Airdrop",
    ])
  func flagsScamKeywords(name: String) {
    #expect(CryptoSpamHeuristics.spamSignal(name: name, symbol: nil) == .scamKeyword)
  }

  // MARK: - Mixed-script (homoglyph) symbols

  /// A spam contract spoofs a popular ASCII ticker by swapping one Latin
  /// letter for a visually identical character from another script — e.g.
  /// `USD` + Cyrillic `Es` (U+0421) renders as "USDC" but is not byte-equal
  /// to it, so the canonical-registry impersonation check misses it. A ticker
  /// that mixes Latin with another script is therefore itself a spam signal.
  @Test(
    "A symbol mixing Latin with another script (homoglyph spoof) is flagged",
    arguments: [
      "USD\u{0421}",  // USD + Cyrillic Es — spoofs USDC
      "\u{0410}AVE",  // Cyrillic A + Latin AVE — spoofs AAVE
      "L\u{0406}NK",  // Cyrillic Byelorussian-Ukrainian I — spoofs LINK
    ])
  func flagsMixedScriptSymbol(symbol: String) {
    #expect(
      CryptoSpamHeuristics.spamSignal(name: symbol, symbol: symbol) == .mixedScriptSymbol)
  }

  @Test("A mixed-script symbol is flagged even when the name is plain ASCII")
  func flagsMixedScriptSymbolWithCleanName() {
    #expect(
      CryptoSpamHeuristics.spamSignal(name: "USD Coin", symbol: "USD\u{0421}")
        == .mixedScriptSymbol)
  }

  @Test("Pure-ASCII symbols are never flagged as mixed-script")
  func pureASCIISymbolNotMixedScript() {
    #expect(CryptoSpamHeuristics.spamSignal(name: "USDC", symbol: "USDC") == nil)
    #expect(CryptoSpamHeuristics.spamSignal(name: "Chainlink", symbol: "LINK") == nil)
  }

  // MARK: - Legitimate tokens are not flagged

  @Test(
    "Well-known legitimate token names are not flagged",
    arguments: [
      ("USD Coin", "USDC"),
      ("Ethereum", "ETH"),
      ("Optimism", "OP"),
      ("Uniswap", "UNI"),
      ("Wrapped Bitcoin", "WBTC"),
      ("Dai Stablecoin", "DAI"),
      ("Aave Token", "AAVE"),
      ("Lido DAO Token", "LDO"),
      ("Chainlink", "LINK"),
      ("AirSwap", "AST"),
      // Keyword detection anchors to the start of a word: "claim" must not
      // fire on "Reclaim" or "Disclaimer".
      ("Reclaim Protocol", "RCM"),
      ("Disclaimer", "DSC"),
    ])
  func doesNotFlagLegitimateTokens(name: String, symbol: String) {
    #expect(CryptoSpamHeuristics.spamSignal(name: name, symbol: symbol) == nil)
    #expect(!CryptoSpamHeuristics.isLikelySpam(name: name, symbol: symbol))
  }

  @Test("Empty name and symbol are not flagged")
  func emptyInputsAreClean() {
    #expect(CryptoSpamHeuristics.spamSignal(name: "", symbol: nil) == nil)
    #expect(CryptoSpamHeuristics.spamSignal(name: "", symbol: "") == nil)
  }

  @Test("isLikelySpam agrees with spamSignal")
  func isLikelySpamMatchesSignal() {
    #expect(CryptoSpamHeuristics.isLikelySpam(name: "claim at evil.com", symbol: nil))
    #expect(CryptoSpamHeuristics.isLikelySpam(name: "Invitation", symbol: nil))
    #expect(!CryptoSpamHeuristics.isLikelySpam(name: "Ethereum", symbol: "ETH"))
  }
}
