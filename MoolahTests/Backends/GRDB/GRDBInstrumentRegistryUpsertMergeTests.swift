import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("GRDBInstrumentRegistryRepository upsert preserves provider mapping")
struct GRDBInstrumentRegistryUpsertMergeTests {
  private func makeRegistry() throws -> GRDBInstrumentRegistryRepository {
    // The registry's canonical store is the profile-index DB — the
    // per-profile `instrument` table was removed by
    // `v10_drop_shared_instrument_legacy`.
    let queue = try ProfileIndexDatabase.openInMemory()
    return GRDBInstrumentRegistryRepository(database: queue)
  }

  private let eth = Instrument.crypto(
    chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)

  @Test("An empty-mapping re-register does not erase a resolved mapping")
  func emptyMappingDoesNotClobber() async throws {
    let registry = try makeRegistry()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id,
        coingeckoId: "ethereum",
        binanceSymbol: "ETHUSDT"))

    // Simulates `registerResolvable`'s all-nil crypto publish for the same id.
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id,
        coingeckoId: nil,
        binanceSymbol: nil))

    let reg = try await registry.cryptoRegistration(byId: eth.id)
    #expect(reg?.mapping.coingeckoId == "ethereum")
    #expect(reg?.mapping.binanceSymbol == "ETHUSDT")
  }

  @Test("A populated re-register still overwrites individual columns")
  func populatedMappingStillUpdates() async throws {
    let registry = try makeRegistry()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "old", binanceSymbol: nil))
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: "ETHUSDT"))
    let reg = try await registry.cryptoRegistration(byId: eth.id)
    #expect(reg?.mapping.coingeckoId == "ethereum")
    #expect(reg?.mapping.binanceSymbol == "ETHUSDT")
  }

  @Test("Partial re-register updates one column and preserves the others")
  func partialMappingPreservesOtherColumns() async throws {
    let registry = try makeRegistry()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "old-cg", binanceSymbol: nil))
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))
    let reg = try await registry.cryptoRegistration(byId: eth.id)
    #expect(reg?.mapping.coingeckoId == "ethereum")  // updated
    #expect(reg?.mapping.binanceSymbol == nil)  // stays nil
  }

  @Test("A thin re-register with empty name does not blank the stored name")
  func emptyNameDoesNotBlankStoredName() async throws {
    let registry = try makeRegistry()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))
    let thin = Instrument(
      id: eth.id, kind: .cryptoToken, name: "", decimals: 18,
      ticker: nil, exchange: nil, chainId: 1, contractAddress: nil)
    try await registry.registerCrypto(
      thin,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: nil, binanceSymbol: nil))
    let reg = try await registry.cryptoRegistration(byId: eth.id)
    #expect(reg?.instrument.name == "Ethereum")  // preserved
  }

  @Test("A nil incoming ticker does not blank the stored ticker")
  func nilTickerDoesNotBlankStoredTicker() async throws {
    let registry = try makeRegistry()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))
    let thin = Instrument(
      id: eth.id, kind: .cryptoToken, name: "", decimals: 18,
      ticker: nil, exchange: nil, chainId: 1, contractAddress: nil)
    try await registry.registerCrypto(
      thin,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: nil, binanceSymbol: nil))
    let reg = try await registry.cryptoRegistration(byId: eth.id)
    #expect(reg?.instrument.ticker == "ETH")  // preserved
  }

  // A real-mapping re-register makes a previously-clobbered
  // (project-filtered) row visible again.
  @Test(
    "A clobbered priced+no-mapping row is invisible until a real mapping re-register repairs it")
  func clobberedRowRepairedByReRegister() async throws {
    let registry = try makeRegistry()
    // Post-clobber state: priced (default) + all-nil provider mapping.
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: nil, binanceSymbol: nil))
    // Precondition: project() filters this shape → invisible to conversion.
    try #require(try await registry.cryptoRegistration(byId: eth.id) == nil)
    try #require(!(try await registry.allCryptoRegistrations().contains { $0.id == eth.id }))

    // Discovery re-resolves and re-registers with a real mapping. The
    // merge rule (a nil incoming provider column never clobbers a
    // populated stored one) means re-registering with a real mapping
    // restores the row to a visible, conversion-usable state.
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: "ETHUSDT"))
    let reg = try await registry.cryptoRegistration(byId: eth.id)
    #expect(reg?.mapping.coingeckoId == "ethereum")
    #expect(try await registry.allCryptoRegistrations().contains { $0.id == eth.id })
  }

  @Test("registerCrypto merge preserves encodedSystemFields (no spurious change-tag loss)")
  func mergePreservesEncodedSystemFields() async throws {
    let registry = try makeRegistry()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))
    let blob = Data([0xCA, 0xFE, 0xBA, 0xBE])
    _ = try registry.setEncodedSystemFieldsSync(id: eth.id, data: blob)
    // All-nil publish (the `registerResolvable` crypto pattern) must not blank it.
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: nil, binanceSymbol: nil))
    #expect(try registry.fetchRowSync(id: eth.id)?.encodedSystemFields == blob)
  }

  @Test("registerCrypto(forcingStatus:) preserves encodedSystemFields on the UPDATE path")
  func forcingStatusPreservesEncodedSystemFields() async throws {
    // The forcing overload's UPDATE branch fetches the full stored row,
    // merges resolved fields, sets `pricingStatus`, and writes it back.
    // The CloudKit change-tag (`encodedSystemFields`) must ride through
    // untouched — otherwise every discovery-driven status flip would
    // provoke a `serverRecordChanged` conflict on the next upload.
    let registry = try makeRegistry()
    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil))
    let blob = Data([0xCA, 0xFE, 0xBA, 0xBE])
    _ = try registry.setEncodedSystemFieldsSync(id: eth.id, data: blob)

    try await registry.registerCrypto(
      eth,
      mapping: CryptoProviderMapping(
        instrumentId: eth.id, coingeckoId: "ethereum", binanceSymbol: nil),
      forcingStatus: .spam)

    let row = try #require(try registry.fetchRowSync(id: eth.id))
    #expect(row.encodedSystemFields == blob)
    #expect(row.pricingStatus == TokenPricingStatus.spam.rawValue)
  }
}
