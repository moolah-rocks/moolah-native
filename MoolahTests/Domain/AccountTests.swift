import Foundation
import Testing

@testable import Moolah

@Suite("Account")
struct AccountTests {
  @Test
  func cryptoAccountRoundTripsViaCodable() throws {
    let account = Account(
      id: UUID(),
      name: "Hardware Wallet — Ethereum",
      type: .crypto,
      instrument: Instrument.crypto(
        chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      positions: [],
      position: 7,
      isHidden: false,
      walletAddress: "0x" + String(repeating: "a", count: 40),
      chainId: 1
    )
    let data = try JSONEncoder().encode(account)
    let decoded = try JSONDecoder().decode(Account.self, from: data)
    #expect(decoded.walletAddress == account.walletAddress)
    #expect(decoded.chainId == account.chainId)
    #expect(decoded.type == .crypto)
  }

  @Test
  func nonCryptoAccountOmitsWalletFields() throws {
    let account = Account(
      id: UUID(),
      name: "Cheque",
      type: .bank,
      instrument: .AUD
    )
    #expect(account.walletAddress == nil)
    #expect(account.chainId == nil)
    let data = try JSONEncoder().encode(account)
    let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(json["walletAddress"] == nil)
    #expect(json["chainId"] == nil)
  }

  @Test
  func legacyAccountWithoutWalletFieldsDecodesWithNil() throws {
    let json = Data(
      """
      {"id":"\(UUID().uuidString)","name":"Old","type":"bank","instrument":{"id":"AUD","kind":"fiatCurrency","name":"AUD","decimals":2},"position":0,"hidden":false}
      """.utf8)
    let decoded = try JSONDecoder().decode(Account.self, from: json)
    #expect(decoded.walletAddress == nil)
    #expect(decoded.chainId == nil)
  }

  @Test
  func unknownAccountTypeIsRejectedByCodable() {
    // Forward-compat is the `Profile.dataFormatVersion` gate's job — a
    // newer client must bump the gate before writing records that use a
    // future `AccountType`. The in-memory `Account.Codable` decode is
    // strict and throws on unknown values rather than silently
    // misclassifying them as `.asset`.
    let json = Data(
      """
      {"id":"\(UUID().uuidString)","name":"Future","type":"future-type","instrument":{"id":"AUD","kind":"fiatCurrency","name":"AUD","decimals":2},"position":0,"hidden":false}
      """.utf8)
    #expect(throws: DecodingError.self) {
      _ = try JSONDecoder().decode(Account.self, from: json)
    }
  }

  @Test
  func accountBucketForwardsToType() {
    let bank = Account(name: "Chequing", type: .bank, instrument: .AUD)
    let crypto = Account(
      name: "ETH Wallet", type: .crypto, instrument: .AUD,
      walletAddress: "0x" + String(repeating: "a", count: 40), chainId: 1)
    let exchange = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    #expect(bank.bucket == .current)
    #expect(crypto.bucket == .investments)
    #expect(exchange.bucket == .investments)
  }
}
