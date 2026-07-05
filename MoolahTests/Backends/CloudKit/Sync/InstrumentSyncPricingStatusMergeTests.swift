// MoolahTests/Backends/CloudKit/Sync/InstrumentSyncPricingStatusMergeTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// End-to-end tests for the `pricingStatus` cross-device merge applied
/// inside `GRDBInstrumentRegistryRepository.applyRemoteChangesSync` —
/// the GRDB write path the CKSyncEngine apply-batch handler routes
/// remote `InstrumentRecord` changes through. Pure-helper coverage for
/// the truth table lives in `PricingStatusMergeRuleTests`; these tests
/// guarantee the helper actually runs on the persistence path and that
/// non-`pricingStatus` columns remain server-authoritative.
@Suite("InstrumentRow sync pricingStatus merge")
struct InstrumentSyncPricingStatusMergeTests {
  // MARK: - Fixture helpers

  /// Builds a fresh in-memory database + registry for one test.
  ///
  /// The registry is backed by a profile-index DB — instrument identity
  /// lives there; there is no per-profile `instrument` table. The
  /// returned handle is the registry's own DB, so the `InstrumentRow` read-backs
  /// observe exactly what the registry persisted.
  private func makeRegistry() throws -> (
    database: any DatabaseWriter,
    registry: GRDBInstrumentRegistryRepository
  ) {
    let database = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: database)
    return (database, registry)
  }

  /// Seeds a crypto registration into the registry with a chosen
  /// `pricingStatus`, returning the seeded `Instrument` for use by the
  /// caller. `registerCrypto` always seeds with the default `.priced`,
  /// so the seed is followed by `update(_:)` when a different status is
  /// required.
  private func seedRegistration(
    in registry: GRDBInstrumentRegistryRepository,
    status: TokenPricingStatus
  ) async throws -> CryptoRegistration {
    let preset = CryptoRegistration.builtInPresets[1]  // ETH
    try await registry.registerCrypto(preset.instrument, mapping: preset.mapping)
    var stored = preset
    stored.pricingStatus = status
    if status != .priced {
      try await registry.update(stored)
    }
    return stored
  }

  /// Reads back the persisted `pricing_status` for a row id.
  private func storedStatus(
    in database: any DatabaseWriter, id: String
  ) async throws -> String? {
    try await database.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == id)
        .fetchOne(database)?
        .pricingStatus
    }
  }

  /// Builds an incoming `InstrumentRow` mirroring the seeded one but
  /// with a chosen `pricingStatus` — the shape CKSyncEngine would deliver
  /// from another device.
  private func incomingRow(
    for registration: CryptoRegistration,
    status: TokenPricingStatus
  ) -> InstrumentRow {
    var row = InstrumentRow(domain: registration.instrument)
    row.coingeckoId = registration.mapping.coingeckoId
    row.binanceSymbol = registration.mapping.binanceSymbol
    row.pricingStatus = status.rawValue
    return row
  }

  // MARK: - Merge rule on the apply path

  @Test("Local .spam survives an incoming .priced from another device")
  func localSpamSurvivesIncomingPriced() async throws {
    let (database, registry) = try makeRegistry()
    let registration = try await seedRegistration(in: registry, status: .spam)

    let incoming = incomingRow(for: registration, status: .priced)
    try registry.applyRemoteChangesSync(saved: [incoming], deleted: [])

    #expect(
      try await storedStatus(in: database, id: registration.instrument.id)
        == TokenPricingStatus.spam.rawValue)
  }

  @Test("Incoming .spam from another device overwrites a local .priced")
  func incomingSpamOverwritesLocalPriced() async throws {
    let (database, registry) = try makeRegistry()
    let registration = try await seedRegistration(in: registry, status: .priced)

    let incoming = incomingRow(for: registration, status: .spam)
    try registry.applyRemoteChangesSync(saved: [incoming], deleted: [])

    #expect(
      try await storedStatus(in: database, id: registration.instrument.id)
        == TokenPricingStatus.spam.rawValue)
  }

  @Test("Incoming .priced beats a stale local .unpriced (resolution sticks)")
  func incomingPricedBeatsLocalUnpriced() async throws {
    let (database, registry) = try makeRegistry()
    let registration = try await seedRegistration(in: registry, status: .unpriced)

    let incoming = incomingRow(for: registration, status: .priced)
    try registry.applyRemoteChangesSync(saved: [incoming], deleted: [])

    #expect(
      try await storedStatus(in: database, id: registration.instrument.id)
        == TokenPricingStatus.priced.rawValue)
  }

  @Test("Local .priced is preserved when an incoming row regresses to .unpriced")
  func localPricedSurvivesIncomingUnpriced() async throws {
    let (database, registry) = try makeRegistry()
    let registration = try await seedRegistration(in: registry, status: .priced)

    let incoming = incomingRow(for: registration, status: .unpriced)
    try registry.applyRemoteChangesSync(saved: [incoming], deleted: [])

    #expect(
      try await storedStatus(in: database, id: registration.instrument.id)
        == TokenPricingStatus.priced.rawValue)
  }

  // MARK: - Non-pricingStatus fields stay server-authoritative

  @Test("Non-pricingStatus columns remain server-authoritative on apply")
  func incomingNameAndMappingStillWinForServerAuthoritativeFields() async throws {
    let (database, registry) = try makeRegistry()
    // Seed a registration with one provider mapping.
    let registration = try await seedRegistration(in: registry, status: .spam)

    // Build an incoming row that mirrors the seeded id but rewrites a
    // server-authoritative column (`name`) to confirm the merge rule
    // affects only `pricingStatus`.
    var incoming = InstrumentRow(domain: registration.instrument)
    incoming.coingeckoId = registration.mapping.coingeckoId
    incoming.binanceSymbol = registration.mapping.binanceSymbol
    incoming.name = "Renamed-By-Other-Device"
    incoming.pricingStatus = TokenPricingStatus.priced.rawValue

    try registry.applyRemoteChangesSync(saved: [incoming], deleted: [])

    let row = try await database.read { database in
      try InstrumentRow
        .filter(InstrumentRow.Columns.id == registration.instrument.id)
        .fetchOne(database)
    }
    let stored = try #require(row)
    // pricingStatus: merge rule kept the local `.spam`.
    #expect(stored.pricingStatus == TokenPricingStatus.spam.rawValue)
    // name: server-authoritative — incoming value wins.
    #expect(stored.name == "Renamed-By-Other-Device")
  }

  // MARK: - Defensive: legacy / unknown raw values

  @Test("An unrecognised incoming raw value is treated as .priced for the merge")
  func unknownIncomingRawValueTreatedAsPriced() async throws {
    let (database, registry) = try makeRegistry()
    // Local .unpriced — so an incoming `.priced` (or anything decoded
    // as `.priced`) should win per the merge rule.
    let registration = try await seedRegistration(in: registry, status: .unpriced)

    var incoming = incomingRow(for: registration, status: .priced)
    // Simulate a future-version device sending an enum case this build
    // doesn't compile against. The legacy fallback at decode is
    // `.priced`, and the merge rule should therefore promote the row.
    incoming.pricingStatus = "future-status-x"
    try registry.applyRemoteChangesSync(saved: [incoming], deleted: [])

    #expect(
      try await storedStatus(in: database, id: registration.instrument.id)
        == TokenPricingStatus.priced.rawValue)
  }
}
