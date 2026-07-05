// MoolahTests/Backends/UnknownEnumRawValueTests.swift
import Foundation
import Testing

@testable import Moolah

/// Asserts that the row→domain mappers for the enum-shaped TEXT columns
/// (`account.type`, `transaction_leg.type`, `instrument.kind`,
/// `import_rule.match_mode`, `transaction.recur_period`) refuse to
/// silently fall back when an unrecognised raw value arrives.
///
/// The schema's `CHECK` constraints prevent unknown values from being
/// *written*, but a forward-incompatible schema migration could leave
/// old clients reading raw values their compiled enum doesn't know.
/// Per `guides/DATABASE_CODE_GUIDE.md` §3 the mapper must throw rather
/// than silently misclassify rows.
@Suite("Unknown enum raw value handling")
struct UnknownEnumRawValueTests {
  // MARK: - GRDB row mappers

  @Test
  func grdbAccountRowThrowsOnUnknownType() async throws {
    let row = AccountRow(
      id: UUID(),
      recordName: "AccountRecord|\(UUID().uuidString)",
      name: "Future Account",
      type: "future_account_type",
      instrumentId: "AUD",
      position: 0,
      isHidden: false,
      encodedSystemFields: nil,
      valuationMode: ValuationMode.recordedValue.rawValue)

    #expect(
      throws: BackendError.dataCorrupted("Unknown AccountType raw value: future_account_type")
    ) {
      _ = try row.toDomain()
    }
  }

  @Test
  func grdbTransactionLegRowThrowsOnUnknownType() async throws {
    let row = TransactionLegRow(
      id: UUID(),
      recordName: "TransactionLegRecord|\(UUID().uuidString)",
      transactionId: UUID(),
      accountId: nil,
      instrumentId: "AUD",
      quantity: 1_000,
      type: "future_leg_type",
      categoryId: nil,
      earmarkId: nil,
      sortOrder: 0,
      encodedSystemFields: nil)

    #expect(
      throws: BackendError.dataCorrupted("Unknown TransactionType raw value: future_leg_type")
    ) {
      _ = try row.toDomain(instrument: .AUD)
    }
  }

  @Test
  func grdbInstrumentRowThrowsOnUnknownKind() async throws {
    let row = InstrumentRow(
      id: "FUT",
      recordName: "FUT",
      kind: "future_kind",
      name: "Future",
      decimals: 2,
      ticker: nil,
      exchange: nil,
      chainId: nil,
      contractAddress: nil,
      coingeckoId: nil,
      binanceSymbol: nil,
      encodedSystemFields: nil)

    #expect(
      throws: BackendError.dataCorrupted("Unknown Instrument.Kind raw value: future_kind")
    ) {
      _ = try row.toDomain()
    }
  }

  @Test
  func grdbImportRuleRowThrowsOnUnknownMatchMode() async throws {
    let row = ImportRuleRow(
      id: UUID(),
      recordName: "ImportRuleRecord|\(UUID().uuidString)",
      name: "Future rule",
      enabled: true,
      position: 0,
      matchMode: "future_match_mode",
      conditionsJSON: Data(),
      actionsJSON: Data(),
      accountScope: nil,
      encodedSystemFields: nil)

    #expect(
      throws: BackendError.dataCorrupted("Unknown MatchMode raw value: future_match_mode")
    ) {
      _ = try row.toDomain()
    }
  }

  @Test
  func grdbTransactionRowThrowsOnUnknownRecurPeriod() async throws {
    let row = TransactionRow(
      id: UUID(),
      recordName: "TransactionRecord|\(UUID().uuidString)",
      date: Date(),
      payee: nil,
      notes: nil,
      recurPeriod: "future_period",
      recurEvery: nil,
      importOriginRawDescription: nil,
      importOriginBankReference: nil,
      importOriginRawAmount: nil,
      importOriginRawBalance: nil,
      importOriginImportedAt: nil,
      importOriginImportSessionId: nil,
      importOriginSourceFilename: nil,
      importOriginParserIdentifier: nil,
      encodedSystemFields: nil)

    #expect(
      throws: BackendError.dataCorrupted("Unknown RecurPeriod raw value: future_period")
    ) {
      _ = try row.toDomain(legs: [])
    }
  }
}
