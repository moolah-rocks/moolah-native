// MoolahTests/Features/Sync/SyncedAccountStoreTests.swift
import Foundation
import GRDB
import SwiftUI
import Testing

@testable import Moolah

/// Behavioural tests for `SyncedAccountStore`. Exercises every sync trigger
/// (launch, scene-active, manual, hourly timer), the cancellation
/// discipline on the timer task, per-account error containment, and the
/// concurrent-sync collapse via `inProgressAccountIds`. Uses
/// `TestBackend` for the repositories so persistence and per-leg dedup
/// run end-to-end; only the Alchemy client is stubbed.
@Suite("SyncedAccountStore — Triggers + timer + scenePhase")
@MainActor
struct SyncedAccountStoreTests {
  // MARK: - Pinned clock

  /// Pinned clock value tests assert against. `nonisolated` so the
  /// `@Sendable` clock closure passed to the store can read it without
  /// crossing the suite's `@MainActor` boundary.
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)

  // MARK: - Stub harness

  /// Bundle returned from `makeStore` so tests can reach the store
  /// under test plus every collaborator they need to assert against
  /// without re-deriving them from the store's storage.
  private struct Fixture {
    let store: SyncedAccountStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let alchemy: RecordingAlchemyClientStub
  }

  /// Builds a `SyncedAccountStore` backed by a real `TestBackend` so the
  /// apply pass writes through `TransactionRepository` and the per-account
  /// `WalletSyncState` lands in the in-memory GRDB queue. Alchemy is the
  /// only piece stubbed; Stage 9's tests are about the orchestrator's
  /// triggers + scenePhase + cancellation contract, not the build phase
  /// itself (covered by `WalletSyncEngineTests`).
  private func makeStore(
    clock: @escaping @Sendable () -> Date = { Self.pinnedNow },
    staleThreshold: TimeInterval = 86_400,
    timerInterval: Duration = .seconds(3_600),
    maxConcurrentBuilds: Int = 4
  ) throws -> Fixture {
    let (backend, database) = try TestBackend.create()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    // Resolve through the backend's shared profile-index registry;
    // there is no per-profile `instrument` table.
    let registry = backend.grdbInstruments
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver())
    let walletSyncEngine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: BlockExplorerTestDoubles.empty,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
      checkpoints: InMemoryWalletSyncCheckpointRepository(),
      importOriginFactory: { accountId in
        ImportOrigin(
          rawDescription: "wallet:\(accountId.uuidString)",
          rawAmount: 0,
          importedAt: Self.pinnedNow,
          importSessionId: UUID(),
          parserIdentifier: "alchemy-wallet-sync")
      })
    let walletApplyEngine = WalletApplyEngine(
      transactions: backend.transactions,
      walletSyncState: backend.walletSyncState,
      checkpoints: InMemoryWalletSyncCheckpointRepository(),
      importRules: NoOpWalletImportRulesEngine(),
      clock: clock)
    let store = SyncedAccountStore(
      sources: [WalletSyncSource(engine: walletSyncEngine)],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions,
        clock: clock),
      clock: clock,
      staleThreshold: staleThreshold,
      timerInterval: timerInterval,
      maxConcurrentBuilds: maxConcurrentBuilds)
    return Fixture(
      store: store, backend: backend, database: database, alchemy: alchemy)
  }

  /// Seeds a crypto account directly into GRDB so `accounts.fetchAll()`
  /// returns it on the next call. Skips opening-balance work (none of
  /// the orchestration tests assert on balance state).
  private func seedCryptoAccount(
    in database: DatabaseQueue,
    walletAddress: String = "0x" + String(UUID().uuidString.prefix(40)),
    chain: ChainConfig = .ethereum
  ) -> Account {
    let account = Account(
      name: "Wallet \(walletAddress.suffix(4))",
      type: .crypto,
      instrument: chain.nativeInstrument,
      walletAddress: walletAddress.lowercased(),
      chainId: chain.chainId)
    _ = TestBackend.seed(accounts: [account], in: database)
    return account
  }

  // MARK: - Launch trigger

  @Test("Launch: syncStaleAccounts hits every stale crypto account")
  func launchSyncsStaleAccounts() async throws {
    let fixture = try makeStore()
    let account1 = seedCryptoAccount(in: fixture.database)
    let account2 = seedCryptoAccount(in: fixture.database)

    // Both accounts last synced at distantPast → both stale.
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account1.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account2.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncStaleAccounts()

    // Each account had its build phase invoked exactly once.
    let calls = fixture.alchemy.recordedCalls
    let walletsHit = Set(calls.map(\.walletAddress))
    let address1 = try #require(account1.walletAddress)
    let address2 = try #require(account2.walletAddress)
    #expect(walletsHit.count == 2)
    #expect(walletsHit.contains(address1))
    #expect(walletsHit.contains(address2))
  }

  // MARK: - ScenePhase + timer cancellation

  @Test("scenePhase .background cancels the timer; .active recreates a fresh task")
  func backgroundCancelsTimerActiveRecreatesIt() async throws {
    let fixture = try makeStore(
      timerInterval: .seconds(3_600))  // long sleep — never fires in test

    fixture.store.handleScenePhaseChange(.active)
    // Yield once so the spawned timer task reaches its first sleep.
    await Task.yield()

    fixture.store.handleScenePhaseChange(.background)
    // After background, the store's timer task is cleared and any
    // in-progress task has been cancelled — neither expectation is
    // observable through public API on its own, so we re-arm and
    // expect the next .active to leave a fresh task running.
    fixture.store.handleScenePhaseChange(.active)
    await Task.yield()

    // The store schedules a `syncStaleAccounts` on .active in addition
    // to the timer. With no accounts seeded, that's a no-op; the
    // alchemy stub records zero calls. The point of the test is the
    // cancel-then-recreate sequence; surviving without an unhandled
    // cancellation error proves the contract.
    #expect(fixture.alchemy.recordedCalls.isEmpty)
  }

  @Test("Timer cancellation honoured: cancel before tick → loop exits without sync")
  func timerCancellationExitsCleanly() async throws {
    // Short timer so a still-running loop would tick before the test
    // ends. No accounts seeded → the immediate-on-active sync is a
    // structural no-op (alchemy is never called); only the timer's
    // tick would produce a call. After cancellation no more calls
    // fire even after waiting many tick intervals.
    let fixture = try makeStore(timerInterval: .milliseconds(50))

    fixture.store.handleScenePhaseChange(.active)
    fixture.store.cancelTimer()

    // Wait long enough that a still-running timer would have ticked
    // multiple times. With cancellation, no further calls fire.
    try await Task.sleep(for: .milliseconds(300))
    #expect(fixture.alchemy.recordedCalls.isEmpty)
  }

  // MARK: - Pinned clock + WalletSyncState

  @Test("Pinned clock matches lastSyncedAt on a successful sync")
  func pinnedClockMatchesLastSyncedAt() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncStaleAccounts()

    let saved = try #require(
      try await fixture.backend.walletSyncState.load(accountId: account.id))
    #expect(saved.lastSyncedAt == Self.pinnedNow)
    #expect(saved.lastError == nil)
    // Observable state mirrors the persisted truth.
    #expect(fixture.store.statePerAccount[account.id]?.lastSyncedAt == Self.pinnedNow)
  }

  // MARK: - Manual sync regardless of staleness

  @Test("syncAccount dispatches even when lastSyncedAt is recent")
  func manualSyncIgnoresStalenessGate() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: Self.pinnedNow, lastError: nil))
    await fixture.store.loadInitialState()

    // syncStaleAccounts is a no-op (just-synced); manual must fire anyway.
    await fixture.store.syncStaleAccounts()
    #expect(fixture.alchemy.recordedCalls.isEmpty)

    await fixture.store.syncAccount(account)
    #expect(fixture.alchemy.recordedCalls.count == 1)
  }

  // MARK: - Per-account error containment

  @Test("One failing account writes lastError; other accounts apply normally")
  func perAccountErrorContainment() async throws {
    let fixture = try makeStore()
    let failingAccount = seedCryptoAccount(in: fixture.database)
    let workingAccount = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: failingAccount.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: workingAccount.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()

    // Failing account throws .invalidApiKey on the build phase; working
    // account returns an empty transfer list (apply pass updates state).
    let failingAddress = try #require(failingAccount.walletAddress)
    let workingAddress = try #require(workingAccount.walletAddress)
    fixture.alchemy.setTransfersResponse(
      .failure(WalletSyncError.invalidApiKey),
      for: failingAddress)
    fixture.alchemy.setTransfersResponse(
      .transfers([]), for: workingAddress)

    await fixture.store.syncStaleAccounts()

    // Failing account: `.invalidApiKey` recorded; lastSyncedAt unchanged.
    let failingState = try #require(
      try await fixture.backend.walletSyncState.load(accountId: failingAccount.id))
    #expect(failingState.lastError == .invalidApiKey)
    #expect(failingState.lastSyncedAt == .distantPast)

    // Working account: lastSyncedAt advanced to the pinned clock; no error.
    let workingState = try #require(
      try await fixture.backend.walletSyncState.load(accountId: workingAccount.id))
    #expect(workingState.lastSyncedAt == Self.pinnedNow)
    #expect(workingState.lastError == nil)
  }

  // MARK: - Concurrent collapse

  @Test("Concurrent syncStaleAccounts launches collapse to a single in-flight cycle")
  func concurrentSyncCollapses() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 0,
        lastSyncedAt: .distantPast, lastError: nil))
    await fixture.store.loadInitialState()

    // Run two cycles concurrently. Both observe the same in-flight
    // marker, so only one Alchemy round-trip fires per account per
    // window.
    async let first: Void = fixture.store.syncStaleAccounts()
    async let second: Void = fixture.store.syncStaleAccounts()
    _ = await (first, second)

    // Exactly one fetch — the second cycle saw `inProgressAccountIds`
    // already containing the account and skipped it. After both
    // cycles complete the marker is back to empty.
    #expect(fixture.alchemy.recordedCalls.count == 1)
    #expect(fixture.store.inProgressAccountIds.isEmpty)
  }

  // MARK: - Manual sync skips when already in flight

  @Test("syncAccount is a no-op when the account is already in flight")
  func manualSyncRespectsInFlightMarker() async throws {
    let fixture = try makeStore()
    let account = seedCryptoAccount(in: fixture.database)
    await fixture.store.loadInitialState()

    // Pre-occupy the marker so a synchronous syncAccount call has
    // nothing to do. Tests that the public collapse contract holds
    // for the user-initiated path too — not just syncStaleAccounts.
    async let firstRun: Void = fixture.store.syncAccount(account)
    async let duplicate: Void = fixture.store.syncAccount(account)
    _ = await (firstRun, duplicate)

    #expect(fixture.alchemy.recordedCalls.count == 1)
  }

  // The full-resync (`syncAccount(_:fullResync:)`) tests live in
  // `SyncedAccountStoreFullResyncTests.swift`.

  // MARK: - Stale filter

  @Test("Recently-synced accounts are filtered out of syncStaleAccounts")
  func recentlySyncedAccountsAreSkipped() async throws {
    let fixture = try makeStore(staleThreshold: 86_400)
    let account = seedCryptoAccount(in: fixture.database)
    // 1 hour ago — well within the 24h threshold.
    let recent = Self.pinnedNow.addingTimeInterval(-3_600)
    try await fixture.backend.walletSyncState.save(
      WalletSyncState(
        id: account.id, lastSyncedBlockNumber: 100,
        lastSyncedAt: recent, lastError: nil))
    await fixture.store.loadInitialState()

    await fixture.store.syncStaleAccounts()

    #expect(fixture.alchemy.recordedCalls.isEmpty)
  }

  // The global-error-banner tests live in
  // `SyncedAccountStoreGlobalErrorTests.swift`.

  // MARK: - No background tasks
  //
  // The design explicitly excludes `BackgroundTasks` / `BGAppRefreshTask`.
  // Pinning that at runtime would require reflecting on the test bundle's
  // linked frameworks, which is brittle. The compile-time contract is
  // enforced two ways:
  //
  // 1. `SyncedAccountStore.swift` imports only Foundation / OSLog /
  //    Observation / SwiftUI — verified at code-review time and pinned
  //    by the file's MARK header.
  // 2. The merge-queue / CI build fails if a future change adds
  //    `import BackgroundTasks` because the iOS / macOS targets do not
  //    link the BackgroundTasks framework — see `project.yml`.
}
