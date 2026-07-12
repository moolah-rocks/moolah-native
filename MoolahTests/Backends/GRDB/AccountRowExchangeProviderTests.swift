// MoolahTests/Backends/GRDB/AccountRowExchangeProviderTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("AccountRow.exchangeProvider")
struct AccountRowExchangeProviderTests {
  @Test("init(domain:) writes exchangeProvider raw value")
  func initFromDomain() {
    let account = Account(
      name: "Coinstash", type: .exchange, instrument: .AUD,
      exchangeProvider: .coinstash)
    let row = AccountRow(domain: account)
    #expect(row.exchangeProvider == "coinstash")
  }

  @Test("toDomain reads exchangeProvider back")
  func toDomain() throws {
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "Coinstash",
      type: "exchange", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      walletAddress: nil, chainId: nil,
      exchangeProvider: "coinstash")
    let account = try row.toDomain()
    #expect(account.exchangeProvider == .coinstash)
  }

  @Test("toDomain silently maps unknown provider to nil (forward-compat)")
  func toDomainUnknownProvider() throws {
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "FutureExchange",
      type: "exchange", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      walletAddress: nil, chainId: nil,
      exchangeProvider: "future-unknown-provider")
    let account = try row.toDomain()
    #expect(account.exchangeProvider == nil)
  }

  @Test("toDomain passes nil exchangeProvider through as nil")
  func toDomainNilProvider() throws {
    let row = AccountRow(
      id: UUID(), recordName: "AccountRecord|x", name: "NilExchange",
      type: "exchange", instrumentId: "AUD", position: 0,
      isHidden: false, encodedSystemFields: nil,
      walletAddress: nil, chainId: nil,
      exchangeProvider: nil)
    let account = try row.toDomain()
    #expect(account.exchangeProvider == nil)
  }
}
