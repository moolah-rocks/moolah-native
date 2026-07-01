// MoolahTests/Backends/GRDB/InstrumentRegistryAliasFilterTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Aliased (retired) rows are hidden from the registry/picker display
/// queries but retained for FK resolution (`fetchInstrumentMap`).
///
/// Seeds a canonical `1:native` row (alias_of NULL) and a retired `10:native`
/// row (alias_of = "1:native", set by `CanonicalInstrumentResolver` during
/// `applyRemoteChangesSync`). The first two tests assert the display queries
/// hide the aliased row; the third guards that the FK resolver still resolves
/// the retired id — migration-window legs that still reference `10:native` must
/// not become unresolvable.
@Suite("Instrument registry — alias display filter")
struct InstrumentRegistryAliasFilterTests {

  // MARK: - Display queries hide aliased rows

  @Test("all() excludes aliased rows from the picker list")
  func allExcludesAliasedRows() async throws {
    let registry = try makeRegistry()
    let ids = try await registry.all().map(\.id)
    #expect(ids.contains("1:native"))
    #expect(!ids.contains("10:native"))
  }

  @Test("allCryptoRegistrations() excludes aliased rows from the Settings registry")
  func allCryptoRegistrationsExcludesAliasedRows() async throws {
    let registry = try makeRegistry()
    let ids = try await registry.allCryptoRegistrations().map(\.instrument.id)
    #expect(ids.contains("1:native"))
    #expect(!ids.contains("10:native"))
  }

  // MARK: - FK resolver retains aliased rows (must NOT be filtered)

  @Test("fetchInstrumentMap resolves both canonical and aliased ids (unfiltered)")
  func fetchInstrumentMapRetainsAliasedRows() async throws {
    let registry = try makeRegistry()
    // `fetchInstrumentMap` issues a bare `SELECT * FROM instrument` with no
    // `alias_of IS NULL` filter — a not-yet-rewritten migration-window leg
    // that still references a retired id (e.g. "10:native") must still resolve
    // to an `Instrument` rather than silently producing nil and breaking the
    // transaction display. This test is the guard that keeps `fetchInstrumentMap`
    // unfiltered: if someone adds `WHERE alias_of IS NULL` there, this fails.
    let map = try await registry.database.read { queue in
      try InstrumentRow.fetchInstrumentMap(database: queue)
    }
    #expect(map["10:native"] != nil)
    #expect(map["1:native"] != nil)
  }
}

extension InstrumentRegistryAliasFilterTests {
  private func makeRegistry() throws -> GRDBInstrumentRegistryRepository {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(
      database: database, canonicalResolver: CanonicalInstrumentResolver())
    // Seed a canonical + a retired-and-aliased crypto row.
    // `CanonicalInstrumentResolver.staticBaseMap` maps "10:native" → "1:native",
    // so `applyRemoteChangesSync` calls `setAliasOf("10:native", to: "1:native")`
    // as part of the upsert, leaving `alias_of = "1:native"` on the retired row.
    try registry.applyRemoteChangesSync(
      saved: [
        InstrumentRow(
          id: "1:native", recordName: "1:native", kind: "cryptoToken",
          name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
          chainId: 1, contractAddress: nil, coingeckoId: "ethereum",
          cryptocompareSymbol: nil, binanceSymbol: nil, encodedSystemFields: nil),
        InstrumentRow(
          id: "10:native", recordName: "10:native", kind: "cryptoToken",
          name: "Ethereum", decimals: 18, ticker: "ETH", exchange: nil,
          chainId: 10, contractAddress: nil, coingeckoId: "ethereum",
          cryptocompareSymbol: nil, binanceSymbol: nil, encodedSystemFields: nil),
      ], deleted: [])
    return registry
  }
}
