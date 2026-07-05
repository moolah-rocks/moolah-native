// MoolahTests/Shared/CryptoImport/WalletApplyEngineTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// Behavioural tests for `WalletApplyEngine`. Uses `TestBackend` (real
/// `CloudKitBackend` + in-memory GRDB) so per-leg dedup, persistence,
/// and `WalletSyncState` updates are exercised end-to-end without
/// mocking the repositories.
@Suite("WalletApplyEngine — Sequential apply pass")
@MainActor
struct WalletApplyEngineTests {
  // Pinned clock value tests assert against. `nonisolated` so the
  // `@Sendable` clock closure passed to `WalletApplyEngine` can read
  // it without crossing the suite's `@MainActor` boundary.
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Happy path

  @Test("Two accounts, one candidate each → merger collapses → one transaction persisted")
  func happyPath() async throws {
    let setup = try makeSetup()
    let accountA = try setup.seedCryptoAccount()
    let accountB = try setup.seedCryptoAccount()
    let hash = "0xa-merge-this"

    let outbound = makeBuilt(
      accountId: accountA.id, hash: hash, quantity: -1)
    let inbound = makeBuilt(
      accountId: accountB.id, hash: hash, quantity: 1)

    let persisted = try await setup.engine.apply(perAccount: [
      .init(account: accountA, headBlockNumber: 100, candidates: [outbound]),
      .init(account: accountB, headBlockNumber: 200, candidates: [inbound]),
    ])

    #expect(persisted.count == 1)
    let stored = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(stored.count == 1)
    let result = try #require(stored.first)
    #expect(result.legs.count == 2)
    let signs = result.legs.map { $0.quantity > 0 ? "+" : "-" }
    #expect(Set(signs) == Set(["+", "-"]))
  }

  // MARK: - Dedup

  @Test("Pre-seeded leg with the same (accountId, externalId) prevents a duplicate write")
  func perLegDedupSkipsExisting() async throws {
    let setup = try makeSetup()
    let accountA = try setup.seedCryptoAccount()
    let hash = "0xseen-before"

    // Pre-seed a transaction with the same `(accountId, externalId)`
    // pair so the dedup step has something to find. Wallet importer's
    // per-account leg type is `.expense` for outbound (negative qty).
    let priorLeg = TransactionLeg(
      accountId: accountA.id,
      instrument: ChainConfig.ethereum.nativeInstrument,
      quantity: -1,
      externalId: hash,
      type: .expense)
    _ = try await setup.backend.transactions.create(
      Transaction(
        date: Self.pinnedNow.addingTimeInterval(-3_600),
        legs: [priorLeg]))

    let candidate = makeBuilt(
      accountId: accountA.id, hash: hash, quantity: -1)

    let persisted = try await setup.engine.apply(perAccount: [
      .init(account: accountA, headBlockNumber: 50, candidates: [candidate])
    ])

    #expect(persisted.isEmpty)
    let stored = try await setup.backend.transactions.fetchAll(filter: .init())
    #expect(stored.count == 1)  // Only the pre-seeded one.
  }

  // MARK: - WalletSyncState

  @Test("WalletSyncState is updated per account with pinned clock + headBlockNumber")
  func updatesWalletSyncStatePerAccount() async throws {
    let setup = try makeSetup()
    let accountA = try setup.seedCryptoAccount()
    let accountB = try setup.seedCryptoAccount()

    _ = try await setup.engine.apply(perAccount: [
      .init(account: accountA, headBlockNumber: 100, candidates: []),
      .init(account: accountB, headBlockNumber: 250, candidates: []),
    ])

    let stateA = try #require(
      try await setup.backend.walletSyncState.load(accountId: accountA.id))
    #expect(stateA.lastSyncedBlockNumber == 100)
    #expect(stateA.lastSyncedAt == Self.pinnedNow)
    #expect(stateA.lastError == nil)

    let stateB = try #require(
      try await setup.backend.walletSyncState.load(accountId: accountB.id))
    #expect(stateB.lastSyncedBlockNumber == 250)
    #expect(stateB.lastSyncedAt == Self.pinnedNow)
  }

  // MARK: - Synced checkpoint (max-merge)

  @Test("Existing synced checkpoint higher than head is kept (never lowered)")
  func syncedCheckpointKeepsHigherExisting() async throws {
    let setup = try makeSetup()
    let account = try setup.seedCryptoAccount()
    // A peer already advanced the shared checkpoint to 2000.
    try await setup.backend.walletSyncCheckpoints.save(
      WalletSyncCheckpoint(id: account.id, lastSyncedBlockNumber: 2000))

    // This cycle's head trails the peer's checkpoint.
    _ = try await setup.engine.apply(perAccount: [
      .init(account: account, headBlockNumber: 1500, candidates: [])
    ])

    let checkpoint = try #require(
      try await setup.backend.walletSyncCheckpoints.load(accountId: account.id))
    // max(existing 2000, head 1500) — never lowered.
    #expect(checkpoint.lastSyncedBlockNumber == 2000)
    // Local per-device state still records this device's own head.
    let localState = try #require(
      try await setup.backend.walletSyncState.load(accountId: account.id))
    #expect(localState.lastSyncedBlockNumber == 1500)
  }

  @Test("Head higher than existing synced checkpoint raises the shared value")
  func syncedCheckpointRaisesToHead() async throws {
    let setup = try makeSetup()
    let account = try setup.seedCryptoAccount()
    try await setup.backend.walletSyncCheckpoints.save(
      WalletSyncCheckpoint(id: account.id, lastSyncedBlockNumber: 2000))

    _ = try await setup.engine.apply(perAccount: [
      .init(account: account, headBlockNumber: 2500, candidates: [])
    ])

    let checkpoint = try #require(
      try await setup.backend.walletSyncCheckpoints.load(accountId: account.id))
    // max(existing 2000, head 2500) — raised.
    #expect(checkpoint.lastSyncedBlockNumber == 2500)
  }

  // MARK: - Import rules

  @Test("WalletImportRulesEngine is invoked exactly once with the persisted transactions")
  func importRulesInvoked() async throws {
    let recordingRules = RecordingWalletImportRulesEngine()
    let setup = try makeSetup(importRules: recordingRules)
    let accountA = try setup.seedCryptoAccount()
    let candidate = makeBuilt(
      accountId: accountA.id, hash: "0xrule", quantity: 1)

    let persisted = try await setup.engine.apply(perAccount: [
      .init(account: accountA, headBlockNumber: 1, candidates: [candidate])
    ])

    #expect(persisted.count == 1)
    let calls = await recordingRules.calls
    #expect(calls.count == 1)
    #expect(calls[0].count == 1)
  }

  // MARK: - Empty-candidate accounts

  @Test("Account with no candidates still updates WalletSyncState; other accounts persist")
  func emptyCandidateAccountIsolated() async throws {
    let setup = try makeSetup()
    let failedAccount = try setup.seedCryptoAccount()
    let workingAccount = try setup.seedCryptoAccount()
    let candidate = makeBuilt(
      accountId: workingAccount.id, hash: "0xworks", quantity: 1)

    let persisted = try await setup.engine.apply(perAccount: [
      .init(account: failedAccount, headBlockNumber: 0, candidates: []),
      .init(account: workingAccount, headBlockNumber: 75, candidates: [candidate]),
    ])

    #expect(persisted.count == 1)
    // `failedAccount` participated even though it produced nothing.
    let failedState = try #require(
      try await setup.backend.walletSyncState.load(accountId: failedAccount.id))
    #expect(failedState.lastSyncedBlockNumber == 0)
    let workingState = try #require(
      try await setup.backend.walletSyncState.load(accountId: workingAccount.id))
    #expect(workingState.lastSyncedBlockNumber == 75)
  }

  // MARK: - Helpers

  private struct Setup {
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let engine: WalletApplyEngine

    func seedCryptoAccount(
      walletAddress: String = "0x" + String(UUID().uuidString.prefix(40))
    ) throws -> Account {
      let account = Account(
        name: "Wallet \(walletAddress.suffix(4))",
        type: .crypto,
        instrument: ChainConfig.ethereum.nativeInstrument,
        walletAddress: walletAddress.lowercased(),
        chainId: ChainConfig.ethereum.chainId)
      _ = TestBackend.seed(accounts: [account], in: database)
      return account
    }
  }

  private func makeSetup(
    importRules: any WalletImportRulesEngine = NoOpWalletImportRulesEngine()
  ) throws -> Setup {
    let (backend, database) = try TestBackend.create()
    let engine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      checkpoints: backend.walletSyncCheckpoints,
      importRules: importRules,
      clock: { Self.pinnedNow })
    return Setup(backend: backend, database: database, engine: engine)
  }

  private func makeBuilt(
    accountId: UUID,
    hash: String,
    quantity: Decimal
  ) -> BuiltTransaction {
    // Mirror `TransferEventBuilder`'s per-account types: positive
    // quantity (inbound) → `.income`, negative (outbound) → `.expense`.
    let legType: TransactionType = quantity >= 0 ? .income : .expense
    let leg = TransactionLeg(
      accountId: accountId,
      instrument: ChainConfig.ethereum.nativeInstrument,
      quantity: quantity,
      externalId: hash,
      type: legType)
    let transaction = Transaction(
      date: Self.pinnedNow,
      legs: [leg],
      importOrigin: .single(
        ImportOrigin(
          rawDescription: "wallet:\(accountId.uuidString)",
          rawAmount: 0,
          importedAt: Self.pinnedNow,
          importSessionId: UUID(),
          parserIdentifier: "alchemy-wallet-sync")))
    return BuiltTransaction(originAccountId: accountId, transaction: transaction)
  }
}

/// Recording stub for `WalletImportRulesEngine`. Captures every `apply`
/// call so tests can assert on call count and the transactions passed.
///
/// `actor` so the recorded calls can be observed from `@MainActor` tests
/// without tripping Sendable diagnostics.
actor RecordingWalletImportRulesEngine: WalletImportRulesEngine {
  private(set) var calls: [[Transaction]] = []

  func apply(transactions: [Transaction]) async throws -> [Transaction] {
    calls.append(transactions)
    return transactions
  }
}
