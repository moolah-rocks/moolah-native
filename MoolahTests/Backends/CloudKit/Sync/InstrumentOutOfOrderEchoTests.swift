@preconcurrency import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Reproductions for the #1085 out-of-order self-echo loss on the
/// instrument apply path (`GRDBInstrumentRegistryRepository.applyRemoteChangesSync`)
/// — the shared-registry path the crypto migration's `register-instrument`
/// and pricing mutations flow through. The modification-date gate protects
/// identity / provider-mapping fields and the cached system-fields blob;
/// `pricingStatus` is EXEMPT and always flows through `PricingStatusMerge`.
@Suite("instrument out-of-order echo gate (issue #1085)")
struct InstrumentOutOfOrderEchoTests {
  private static let zoneID = CKRecordZone.ID(
    zoneName: "profile-index", ownerName: CKCurrentUserDefaultName)
  private static let tOlder = Date(timeIntervalSince1970: 1_700_000_000)
  private static let tNewer = Date(timeIntervalSince1970: 1_700_000_060)
  private static let tokenId = "1:0x0000000000000000000000000000000000000abc"

  private func makeRegistry() throws -> (any DatabaseWriter, GRDBInstrumentRegistryRepository) {
    let database = try ProfileIndexDatabase.openInMemory()
    return (database, GRDBInstrumentRegistryRepository(database: database))
  }

  /// Builds a crypto `InstrumentRow` for the shared token id, stamped with a
  /// server modification date so the gate can order it.
  private func row(
    name: String,
    decimals: Int = 18,
    ticker: String? = nil,
    coingeckoId: String? = nil,
    status: TokenPricingStatus = .priced,
    date: Date
  ) -> InstrumentRow {
    var row = InstrumentRow(
      id: Self.tokenId,
      recordName: InstrumentRow.recordName(for: Self.tokenId),
      kind: "cryptoToken",
      name: name,
      decimals: decimals,
      ticker: ticker,
      exchange: nil,
      chainId: 1,
      contractAddress: "0x0000000000000000000000000000000000000abc",
      coingeckoId: coingeckoId,
      cryptocompareSymbol: nil,
      binanceSymbol: nil,
      encodedSystemFields: nil,
      pricingStatus: status.rawValue)
    row.encodedSystemFields =
      row.toCKRecord(in: Self.zoneID).withModificationDate(date).encodedSystemFields
    return row
  }

  private func stored(
    _ database: any DatabaseWriter
  ) async throws -> InstrumentRow? {
    try await database.read {
      try InstrumentRow.filter(InstrumentRow.Columns.id == Self.tokenId).fetchOne($0)
    }
  }

  @Test("identity/mapping fields survive an out-of-order stale instrument echo")
  func identitySurvivesStaleEcho() async throws {
    let (database, registry) = try makeRegistry()

    let vCreate = row(name: "Placeholder", decimals: 18, status: .priced, date: Self.tOlder)
    try registry.applyRemoteChangesSync(saved: [vCreate], deleted: [])

    let vUpdate = row(
      name: "RealToken", decimals: 8, ticker: "RT", coingeckoId: "real-token",
      status: .priced, date: Self.tNewer)
    try registry.applyRemoteChangesSync(saved: [vUpdate], deleted: [])

    // Stale echo of V_create arrives last on a clean row.
    try registry.applyRemoteChangesSync(saved: [vCreate], deleted: [])

    let result = try #require(try await stored(database))
    #expect(result.name == "RealToken")
    #expect(result.decimals == 8)
    #expect(result.ticker == "RT")
    #expect(result.coingeckoId == "real-token")
  }

  @Test("a sticky .spam classification survives a stale echo carrying .priced")
  func stickySpamSurvivesStaleEcho() async throws {
    let (database, registry) = try makeRegistry()

    // Current version is .spam at the newer date.
    try registry.applyRemoteChangesSync(
      saved: [row(name: "Token", status: .spam, date: Self.tNewer)], deleted: [])

    // Stale echo (older date) carrying .priced — identity gated, and
    // pricingStatus merge keeps the sticky .spam.
    try registry.applyRemoteChangesSync(
      saved: [row(name: "Token", status: .priced, date: Self.tOlder)], deleted: [])

    #expect(
      try #require(try await stored(database)).pricingStatus
        == TokenPricingStatus.spam.rawValue)
  }

  @Test("pricingStatus is exempt: a stale echo's .spam still wins over local .priced")
  func pricingStatusExemptFromGate() async throws {
    let (database, registry) = try makeRegistry()

    // Current version is .priced at the newer date.
    try registry.applyRemoteChangesSync(
      saved: [row(name: "Token", status: .priced, date: Self.tNewer)], deleted: [])

    // Stale echo (older date) carrying .spam: identity is date-rejected, but
    // pricingStatus is NOT gated — spam wins through the merge.
    try registry.applyRemoteChangesSync(
      saved: [row(name: "Token", status: .spam, date: Self.tOlder)], deleted: [])

    #expect(
      try #require(try await stored(database)).pricingStatus
        == TokenPricingStatus.spam.rawValue)
  }

  @Test("within one batch: identity ends newest and pricingStatus stays sticky (order A)")
  func withinBatchNewestIdentityAndStickySpamOrderA() async throws {
    try await assertWithinBatch(reversed: false)
  }

  @Test("within one batch: identity ends newest and pricingStatus stays sticky (order B)")
  func withinBatchNewestIdentityAndStickySpamOrderB() async throws {
    try await assertWithinBatch(reversed: true)
  }

  /// Delivers a same-batch `[older .spam, newer .priced]` pair (in either
  /// array order) and asserts the identity fields converge to the newer
  /// version while `pricingStatus` stays sticky `.spam` — the instrument
  /// site is within-batch-correct WITHOUT dedup because the per-row
  /// fetchOne + merge + upsert loop folds every duplicate's status.
  private func assertWithinBatch(reversed: Bool) async throws {
    let (database, registry) = try makeRegistry()
    let older = row(name: "Placeholder", status: .spam, date: Self.tOlder)
    let newer = row(name: "RealToken", status: .priced, date: Self.tNewer)
    let batch = reversed ? [newer, older] : [older, newer]

    try registry.applyRemoteChangesSync(saved: batch, deleted: [])

    let result = try #require(try await stored(database))
    #expect(result.name == "RealToken")
    #expect(result.pricingStatus == TokenPricingStatus.spam.rawValue)
  }
}
