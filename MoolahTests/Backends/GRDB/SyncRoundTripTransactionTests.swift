// MoolahTests/Backends/GRDB/SyncRoundTripTransactionTests.swift

import CloudKit
import Foundation
import GRDB
import Testing

@testable import Moolah

/// CKSyncEngine ↔ GRDB round-trip tests for `TransactionRow` and
/// `TransactionLegRow`. Sibling file to
/// `CoreFinancialGraphSyncRoundTripTests.swift`, which covers the other
/// six core financial graph row types. Same flow: device A produces a
/// CKRecord via `Row.toCKRecord(in:)`, device B's data handler applies
/// it via `applyRemoteChanges`, and we assert the GRDB row on device B
/// matches the source — including the cached `encodedSystemFields` blob
/// bit-for-bit.
@Suite("CKSyncEngine ↔ GRDB round trip — transactions and legs")
@MainActor
struct SyncRoundTripTransactionTests {

  private static let zoneID = CKRecordZone.ID(
    zoneName: "TestZone", ownerName: CKCurrentUserDefaultName)

  // MARK: - TransactionRow

  @Test("Transaction upsert round-trips through CKSyncEngine apply")
  func transactionRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let source = TransactionRow(
      id: id,
      recordName: TransactionRow.recordName(for: id),
      date: date,
      payee: "Rent",
      notes: "Monthly",
      recurPeriod: RecurPeriod.month.rawValue,
      recurEvery: 1,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let row = try await harness.database.read { database in
      try TransactionRow.filter(TransactionRow.Columns.id == id).fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.id == id)
    #expect(resolved.payee == "Rent")
    #expect(resolved.recurPeriod == RecurPeriod.month.rawValue)
    #expect(resolved.recurEvery == 1)
    #expect(resolved.encodedSystemFields == ckRecord.encodedSystemFields)
  }

  /// Builds an `ImportOrigin` from integer cents so the decimals are
  /// exact and the test body stays focused on the round-trip assertion.
  /// `bankReference`, `sourceFilename`, and `importedAt` are derived
  /// from `tag` — they are fixtures, not asserted individually, but the
  /// round-trip equality check still covers them.
  private static func makeOrigin(
    tag: String,
    amountCents: Int,
    balanceCents: Int
  ) -> ImportOrigin {
    ImportOrigin(
      rawDescription: "TFR \(tag)",
      bankReference: "\(tag)-REF",
      rawAmount: Decimal(amountCents) / 100,
      rawBalance: Decimal(balanceCents) / 100,
      importedAt: Date(timeIntervalSince1970: 1_699_000_000),
      importSessionId: UUID(),
      sourceFilename: "\(tag).csv",
      parserIdentifier: "generic-csv")
  }

  @Test("Merged importOrigin survives the CK round trip")
  func mergedOriginRoundTrip() throws {
    let id = UUID()
    let date = Date(timeIntervalSince1970: 1_700_000_000)
    let outgoing = Self.makeOrigin(
      tag: "OUT", amountCents: -25075, balanceCents: 100_000)
    let incoming = Self.makeOrigin(
      tag: "IN", amountCents: 25075, balanceCents: 200_000)
    let source = TransactionRow(
      domain: Transaction(
        id: id,
        date: date,
        payee: "Transfer",
        notes: nil,
        recurPeriod: nil,
        recurEvery: nil,
        legs: [],
        importOrigin: .merged(
          MergedImportOrigin(outgoing: outgoing, incoming: incoming))))
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let projected = try #require(TransactionRow.fieldValues(from: ckRecord))
    let resolved = try projected.toDomain(legs: [])

    #expect(
      resolved.importOrigin
        == .merged(MergedImportOrigin(outgoing: outgoing, incoming: incoming)))
  }

  @Test("Single importOrigin survives the CK round trip")
  func singleOriginRoundTrip() throws {
    let id = UUID()
    let origin = Self.makeOrigin(
      tag: "GROCERIES", amountCents: -4210, balanceCents: 50000)
    let source = TransactionRow(
      domain: Transaction(
        id: id,
        date: Date(timeIntervalSince1970: 1_700_000_000),
        payee: "Market",
        notes: nil,
        recurPeriod: nil,
        recurEvery: nil,
        legs: [],
        importOrigin: .single(origin)))
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let projected = try #require(TransactionRow.fieldValues(from: ckRecord))
    let resolved = try projected.toDomain(legs: [])

    #expect(resolved.importOrigin == .single(origin))
  }

  // MARK: - TransactionLegRow

  /// Seeds the `account` and `transaction` rows the leg references so
  /// the test asserts a fully-resolved round-trip. The schema does not
  /// enforce FKs, so this seeding is an *optional* setup detail — the
  /// apply path itself does not require either parent to exist. Tests
  /// of leg sync apply against missing parents live in
  /// `MoolahTests/Sync/ApplyRemoteChangesOutOfOrderTests.swift`.
  private static func seedLegParents(
    database: any DatabaseWriter,
    txnId: UUID,
    accountId: UUID
  ) async throws {
    try await database.write { database in
      try AccountRow(
        domain: Account(id: accountId, name: "Cash", type: .bank, instrument: .AUD)
      )
      .insert(database)
      try TransactionRow(
        id: txnId,
        recordName: TransactionRow.recordName(for: txnId),
        date: Date(),
        payee: "Coffee",
        notes: nil,
        recurPeriod: nil,
        recurEvery: nil,
        importOriginRawDescription: nil,
        importOriginBankReference: nil,
        importOriginRawAmount: nil,
        importOriginRawBalance: nil,
        importOriginImportedAt: nil,
        importOriginImportSessionId: nil,
        importOriginSourceFilename: nil,
        importOriginParserIdentifier: nil,
        encodedSystemFields: nil
      ).insert(database)
    }
  }

  @Test("TransactionLeg upsert round-trips through CKSyncEngine apply")
  func transactionLegRoundTrip() async throws {
    let harness = try ProfileDataSyncHandlerTestSupport.makeHandlerWithDatabase()
    let txnId = UUID()
    let accountId = UUID()
    let legId = UUID()
    try await Self.seedLegParents(
      database: harness.database, txnId: txnId, accountId: accountId)

    let source = TransactionLegRow(
      id: legId,
      recordName: TransactionLegRow.recordName(for: legId),
      transactionId: txnId,
      accountId: accountId,
      instrumentId: Instrument.AUD.id,
      quantity: -1000,
      type: TransactionType.expense.rawValue,
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)
    let ckRecord = source.toCKRecord(in: Self.zoneID)

    let result = harness.handler.applyRemoteChanges(saved: [ckRecord], deleted: [])
    if case .saveFailed(let message) = result {
      Issue.record("applyRemoteChanges reported saveFailed: \(message)")
    }

    let row = try await harness.database.read { database in
      try TransactionLegRow.filter(TransactionLegRow.Columns.id == legId)
        .fetchOne(database)
    }
    let resolved = try #require(row)
    #expect(resolved.id == legId)
    #expect(resolved.transactionId == txnId)
    #expect(resolved.accountId == accountId)
    #expect(resolved.quantity == -1000)
    #expect(resolved.encodedSystemFields == ckRecord.encodedSystemFields)
  }
}
