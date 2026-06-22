// MoolahTests/Backends/GRDB/GRDBCreatePathRegistersInstrumentTests.swift

import Foundation
import GRDB
import Testing

@testable import Moolah

/// Pins the cross-transaction atomicity boundary: instrument
/// registration commits in its OWN transaction BEFORE the per-profile
/// write that inserts the transaction/leg rows. If the per-profile
/// write later fails and rolls back, the instrument row persists —
/// safe because `registerResolvable` is idempotent and a retry will
/// succeed. The fiat-only rollback tests don't cover this asymmetric
/// boundary because they go through `registerResolvable` as a no-op.
///
/// The in-transaction throw is forced by a `BEFORE INSERT ON "transaction"`
/// SQLite trigger so the abort fires inside the per-profile write block,
/// after `registerResolvable` has already committed on its separate DB
/// queue write.
@Suite("Cross-transaction atomicity: registration persists when per-profile write rolls back")
struct GRDBInstrumentRegistrationRollbackTests {

  @Test(
    """
    instrument row persists after per-profile write rolls back (register-then-write contract)
    """
  )
  func instrumentRowPersistsAfterPerProfileWriteRollback() async throws {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedQueue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: sharedQueue)

    // The shared registry writes the instrument row into the
    // profile-index DB in its own separate transaction BEFORE the
    // per-profile transaction/leg write. This is the boundary under
    // test: the registration write is NOT part of the per-profile
    // write transaction, so a per-profile rollback cannot undo it.
    let repo = GRDBTransactionRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "USD"),
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    // Install a trigger that aborts every INSERT into the `transaction`
    // table. The per-profile write inserts the transaction header first,
    // so the trigger fires there and rolls back the entire per-profile
    // write (header + legs). The registration write has already
    // committed by the time this trigger fires.
    try await perProfile.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_txn_insert
          BEFORE INSERT ON "transaction"
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    let leg = TransactionLeg(
      accountId: UUID(), instrument: eth, quantity: 1, type: .income)
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000), payee: "Buy ETH",
      legs: [leg])

    await #expect(throws: (any Error).self) {
      try await repo.create(txn)
    }

    // The registrar committed its write into the shared registry
    // before the per-profile write; that registration is NOT rolled
    // back with the failing write. This is the intentional
    // cross-transaction atomicity contract: register then write;
    // registration is not rolled back with a failed per-profile write;
    // safe because idempotent.
    // Resolvable from the shared registry (the per-profile-zero
    // invariant is pinned by `transactionCreateRegistersInSharedRegistry`).
    let resolved = try await registry.instrumentMap()[eth.id]
    #expect(
      resolved == eth,
      "instrument must remain resolvable from the shared registry after per-profile write rolls back"
    )

    // The per-profile transaction write did roll back: no transaction
    // header and no legs on disk.
    let txnRows = try await perProfile.read { database in
      try TransactionRow.fetchAll(database)
    }
    let legRows = try await perProfile.read { database in
      try TransactionLegRow.fetchAll(database)
    }
    #expect(txnRows.isEmpty, "transaction row must not persist after per-profile write rolls back")
    #expect(legRows.isEmpty, "leg row must not persist after per-profile write rolls back")
  }
}

/// Pins that `create` (transaction and account) does not plant a
/// per-profile placeholder `instrument` row. Instead it awaits
/// `InstrumentRegistering.registerResolvable` *before* the per-profile
/// write, so an immediately-following read resolves the instrument.
///
/// Production-shaped wiring: a SHARED `GRDBInstrumentRegistryRepository`
/// over `ProfileIndexDatabase.openInMemory()` is injected as BOTH the
/// `instrumentResolver` and the `instrumentRegistrar`; the txn / leg /
/// account rows land in a separate `ProfileDatabase.openInMemory()`. The
/// proof is two-sided:
///   1. the instrument is resolvable from the shared registry after
///      `create` — `instrumentMap()` (the exact read every production
///      resolver path consults) returns the full crypto `Instrument`,
///      not the `Instrument.fiat(code:)` fallback. (A priced /
///      no-mapping registration is intentionally hidden from
///      `cryptoRegistration(byId:)` — that is the inbox projection — so
///      resolvability must be probed via the resolver the read paths
///      actually use.)
///   2. there is no per-profile `instrument` table at all — a strictly
///      stronger guarantee than "zero placeholder rows".
@Suite("create registers the instrument via the shared registry, not a per-profile placeholder")
struct GRDBCreatePathRegistersInstrumentTests {
  /// There is no per-profile `instrument` table, so the "no
  /// per-profile placeholder" contract is the structural fact that the
  /// table does not exist. Returns `true` when the table is absent
  /// (the expected, stronger guarantee).
  private func perProfileInstrumentTableAbsent(
    _ database: any DatabaseWriter
  ) async throws -> Bool {
    try await database.read { database in
      try
        !(Bool.fetchOne(
          database,
          sql: """
            SELECT EXISTS(
              SELECT 1 FROM sqlite_master WHERE type='table' AND name='instrument')
            """) ?? true)
    }
  }

  @Test("transaction create registers a new crypto leg in the shared registry")
  func transactionCreateRegistersInSharedRegistry() async throws {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedQueue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: sharedQueue)

    let repo = GRDBTransactionRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "USD"),
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    let account = Account(
      name: "Trust - Ethereum", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc",
      chainId: 1)
    let leg = TransactionLeg(
      accountId: account.id, instrument: eth, quantity: 3, type: .income)
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000), payee: "in",
      legs: [leg])

    _ = try await repo.create(txn)

    // (1) resolvable from the shared registry after create — the
    // resolver returns the full crypto instrument, not a fiat fallback.
    let resolved = try await registry.instrumentMap()[eth.id]
    #expect(resolved == eth, "create must register the crypto so the resolver resolves it")
    #expect(resolved?.kind == .cryptoToken)

    // (2) the per-profile `instrument` table is gone (v10) — no place
    // for a placeholder row to exist.
    let absent = try await perProfileInstrumentTableAbsent(perProfile)
    #expect(absent, "the per-profile instrument table must be dropped post-v10")
  }

  @Test("account create registers a new crypto denomination in the shared registry")
  func accountCreateRegistersInSharedRegistry() async throws {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedQueue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: sharedQueue)

    let repo = GRDBAccountRepository(
      database: perProfile,
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    let account = Account(
      name: "Trust - Ethereum", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc",
      chainId: 1)

    _ = try await repo.create(account)

    let resolved = try await registry.instrumentMap()[eth.id]
    #expect(
      resolved == eth,
      "account create must register the crypto so the resolver resolves it")
    #expect(resolved?.kind == .cryptoToken)

    let absent = try await perProfileInstrumentTableAbsent(perProfile)
    #expect(absent, "the per-profile instrument table must be dropped post-v10")
  }

  @Test("shared registry keeps create→read resolvable behind the seam")
  func sharedRegistryPreservesResolution() async throws {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedQueue = try ProfileIndexDatabase.openInMemory()
    // One registry instance used as BOTH seams so a registration is
    // resolvable on the subsequent read — the production wiring.
    let registry = GRDBInstrumentRegistryRepository(database: sharedQueue)

    let repo = GRDBTransactionRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "USD"),
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    let account = Account(
      name: "Trust - Ethereum", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xabc",
      chainId: 1)
    let leg = TransactionLeg(
      accountId: account.id, instrument: eth, quantity: 3, type: .income)
    let txn = Transaction(
      date: Date(timeIntervalSince1970: 1_700_000_000), payee: "in",
      legs: [leg])

    try await perProfile.write { database in
      try AccountRow(domain: account).insert(database)
    }
    _ = try await repo.create(txn)

    // The registrar wrote the row into the shared registry behind the
    // seam, so the resolver still resolves the full crypto instrument
    // — without any per-profile `instrument` row.
    let fetched = try await repo.fetchAll(
      filter: TransactionFilter(accountId: account.id))
    let resolvedLeg = try #require(fetched.first?.legs.first)
    #expect(resolvedLeg.instrument == eth)
    #expect(resolvedLeg.instrument.kind == .cryptoToken)

    let absent = try await perProfileInstrumentTableAbsent(perProfile)
    #expect(
      absent,
      "resolution must come from the shared registry; the per-profile table is dropped")
  }

  @Test("distinctLegInstrumentIds returns a de-duplicated set across all persisted legs")
  func distinctLegInstrumentIdsReturnsDistinctSet() async throws {
    let perProfile = try ProfileDatabase.openInMemory()
    let sharedQueue = try ProfileIndexDatabase.openInMemory()
    let registry = GRDBInstrumentRegistryRepository(database: sharedQueue)

    let repo = GRDBTransactionRepository(
      database: perProfile,
      defaultInstrument: Instrument.fiat(code: "AUD"),
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentResolver: registry,
      instrumentRegistrar: registry)

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum",
      decimals: 18)
    let aud = Instrument.fiat(code: "AUD")
    let account = Account(
      name: "Test Account", type: .crypto, instrument: eth,
      valuationMode: .calculatedFromTrades, walletAddress: "0xtest",
      chainId: 1)

    // Seed the account row so FK-like constraints are satisfied, mirroring
    // `sharedRegistryPreservesResolution` which inserts an `AccountRow`
    // before creating any transactions.
    try await perProfile.write { database in
      try AccountRow(domain: account).insert(database)
    }

    // Two transactions: one with an ETH leg, one with an AUD leg and an ETH leg.
    // Distinct ids should be exactly {eth.id, aud.id}, with no duplicates.
    let txn1 = Transaction(
      date: Date(), payee: "Buy ETH",
      legs: [
        TransactionLeg(accountId: account.id, instrument: eth, quantity: 1, type: .income)
      ])
    let txn2 = Transaction(
      date: Date(), payee: "Fee",
      legs: [
        TransactionLeg(accountId: account.id, instrument: aud, quantity: -10, type: .expense),
        TransactionLeg(accountId: account.id, instrument: eth, quantity: -1, type: .expense),
      ])
    _ = try await repo.create(txn1)
    _ = try await repo.create(txn2)

    let ids = try await repo.distinctLegInstrumentIds()
    #expect(ids.contains(eth.id))
    #expect(ids.contains(aud.id))
    #expect(ids.count == 2)
  }
}
