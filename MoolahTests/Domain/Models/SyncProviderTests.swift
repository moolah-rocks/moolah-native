// MoolahTests/Domain/Models/SyncProviderTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("SyncProvider")
struct SyncProviderTests {
  @Test("Raw values are stable tokens")
  func rawValuesAreStable() {
    #expect(SyncProvider.alchemy.rawValue == "alchemy")
    #expect(SyncProvider.blockExplorer.rawValue == "blockExplorer")
    #expect(SyncProvider.coinstash.rawValue == "coinstash")
    #expect(SyncProvider.coinGecko.rawValue == "coinGecko")
    #expect(SyncProvider.cryptoCompare.rawValue == "cryptoCompare")
    #expect(SyncProvider.binance.rawValue == "binance")
  }

  @Test("Display names are the user-facing brand strings")
  func displayNames() {
    #expect(SyncProvider.alchemy.displayName == "Alchemy")
    #expect(SyncProvider.blockExplorer.displayName == "Blockscout")
    #expect(SyncProvider.coinstash.displayName == "Coinstash")
    #expect(SyncProvider.coinGecko.displayName == "CoinGecko")
    #expect(SyncProvider.cryptoCompare.displayName == "CryptoCompare")
    #expect(SyncProvider.binance.displayName == "Binance")
  }

  @Test("Pegged stablecoin provider has a user-facing display name")
  func peggedStablecoinDisplayName() {
    #expect(SyncProvider.peggedStablecoin.displayName == "Pegged Stablecoin")
  }

  @Test("Pegged stablecoin is enumerated in allCases")
  func peggedStablecoinIsACase() {
    #expect(SyncProvider.allCases.contains(.peggedStablecoin))
  }

  @Test("Round-trips through JSON as its raw token")
  func jsonRoundTrip() throws {
    let data = try JSONEncoder().encode(SyncProvider.blockExplorer)
    #expect(String(bytes: data, encoding: .utf8) == "\"blockExplorer\"")
    let decoded = try JSONDecoder().decode(SyncProvider.self, from: data)
    #expect(decoded == .blockExplorer)
  }
}
