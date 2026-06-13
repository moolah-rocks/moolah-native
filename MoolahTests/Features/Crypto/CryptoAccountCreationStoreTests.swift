// MoolahTests/Features/Crypto/CryptoAccountCreationStoreTests.swift
import Foundation
import GRDB
import Testing

@testable import Moolah

/// End-to-end tests for `CryptoAccountCreationLogic.submit(...)`.
///
/// Drives the full create-and-sync sequence through real `AccountStore`
/// and `SyncedAccountStore` instances backed by `TestBackend`. The Alchemy
/// client is the only piece stubbed — these tests own the contract that
/// a successful save kicks off the per-account sync, and a failed
/// validation skips it.
@Suite("CryptoAccountCreationLogic — submit")
@MainActor
struct CryptoAccountCreationStoreTests {
  // Pinned clock matches the `SyncedAccountStore` test pattern; keeps
  // `lastSyncedAt` deterministic when we assert against post-sync state.
  nonisolated static let pinnedNow = Date(timeIntervalSince1970: 1_700_000_000)
  // Canonical lowercase address used for happy-path tests; matches the
  // 42-char `0x…` regex enforced by `Account.validatedWalletAddress`.
  static let validAddress = "0x" + String(repeating: "a", count: 40)

  private struct Fixture {
    let accountStore: AccountStore
    let cryptoSyncStore: SyncedAccountStore
    let backend: CloudKitBackend
    let database: DatabaseQueue
    let alchemy: RecordingAlchemyClientStub
  }

  private func makeFixture() throws -> Fixture {
    let (backend, database) = try TestBackend.create()
    let alchemy = RecordingAlchemyClientStub()
    alchemy.setTransfersResponse(.transfers([]))
    let registry = GRDBInstrumentRegistryRepository(database: database)
    let discovery = CryptoTokenDiscoveryService(
      registry: registry,
      resolver: CountingRegistrationResolver())
    let walletSyncEngine = WalletSyncEngine(
      alchemy: alchemy,
      blockExplorer: BlockExplorerTestDoubles.empty,
      discovery: discovery,
      walletSyncState: backend.walletSyncState,
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
      importRules: NoOpWalletImportRulesEngine(),
      clock: { Self.pinnedNow })
    let cryptoSyncStore = SyncedAccountStore(
      sources: [WalletSyncSource(engine: walletSyncEngine)],
      walletApplyEngine: walletApplyEngine,
      walletSyncState: backend.walletSyncState,
      accounts: backend.accounts,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions,
        clock: { Self.pinnedNow }),
      clock: { Self.pinnedNow })
    let accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    return Fixture(
      accountStore: accountStore,
      cryptoSyncStore: cryptoSyncStore,
      backend: backend,
      database: database,
      alchemy: alchemy)
  }

  /// Profile currency handed to the create flow. A new crypto account is
  /// denominated in the profile currency (not the chain's native token);
  /// per-token positions emerge from leg aggregation converted into this
  /// instrument as wallet syncs land.
  nonisolated static let profileInstrument: Instrument = .defaultTestInstrument

  @Test("Successful submit creates the account denominated in the profile currency")
  func successfulSubmitCreatesCryptoAccount() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore,
      accountInstrument: Self.profileInstrument)

    let outcome = await logic.submit(
      name: "Hardware Wallet",
      chain: .ethereum,
      walletAddressInput: Self.validAddress)

    guard case .created(let created) = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      return
    }
    #expect(created.type == .crypto)
    #expect(created.walletAddress == Self.validAddress)
    #expect(created.chainId == ChainConfig.ethereum.chainId)
    #expect(created.instrument == Self.profileInstrument)
    #expect(created.name == "Hardware Wallet")
    // Crypto wallets compute balance from leg aggregation, so they ship
    // as `.calculatedFromTrades` from creation. The `Account` default is
    // `.recordedValue`; without an explicit mode every reader that gates
    // on `valuationMode` would see the wrong intent.
    #expect(created.valuationMode == .calculatedFromTrades)

    // `AccountStore` mirrors the repository through reactive observation
    // — there is no optimistic insert, so the new account lands in
    // `accounts` only once the GRDB write commits and `observeAll()`
    // emits. Wait for that emission before asserting the store's view
    // of the world.
    await expectEventually("newly-created crypto account observed in store") {
      fixture.accountStore.accounts.count == 1
        && fixture.accountStore.accounts.first?.id == created.id
    }
  }

  @Test(
    "Chain selection does not change the account instrument — Base still uses the profile currency"
  )
  func chainDoesNotOverrideProfileInstrument() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore,
      accountInstrument: Self.profileInstrument)

    let outcome = await logic.submit(
      name: "Base Hot Wallet",
      chain: .base,
      walletAddressInput: Self.validAddress)

    guard case .created(let created) = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      return
    }
    // The chain still drives `chainId` (and therefore which network the
    // wallet sync queries), but the account is denominated in the
    // profile currency regardless of the chain's native token.
    #expect(created.chainId == ChainConfig.base.chainId)
    #expect(created.instrument == Self.profileInstrument)
    #expect(created.instrument != ChainConfig.base.nativeInstrument)
  }

  @Test("Successful submit kicks off the initial Alchemy sync for the new account")
  func successfulSubmitTriggersInitialSync() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore,
      accountInstrument: Self.profileInstrument)

    let outcome = await logic.submit(
      name: "Sync Wallet",
      chain: .ethereum,
      walletAddressInput: Self.validAddress)
    guard case .created = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      return
    }

    // The kick-off is fire-and-forget so the create-account sheet can
    // dismiss immediately; await the spawned task before asserting on
    // the alchemy stub.
    await fixture.cryptoSyncStore.waitForPendingInitialSyncs()

    // The store invokes the build phase exactly once for the newly-
    // created account, with the canonical wallet address it persisted.
    #expect(fixture.alchemy.recordedCalls.count == 1)
    #expect(fixture.alchemy.recordedCalls.first?.walletAddress == Self.validAddress)
  }

  @Test("Submit returns immediately rather than blocking on the wallet sync")
  func submitDoesNotBlockOnSync() async throws {
    let fixture = try makeFixture()
    // Park the sync indefinitely so we can prove `submit` returns
    // without waiting for it. Without the fix, `submit` awaited
    // `syncAccount`, leaving the create-account sheet open until the
    // entire network round-trip finished — visible to the user as
    // "the new account appears in the sidebar but the form sticks
    // around".
    fixture.alchemy.setBeforeAssetTransfers { @Sendable in
      try? await Task.sleep(for: .seconds(30))
    }
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore,
      accountInstrument: Self.profileInstrument)

    let start = ContinuousClock.now
    let outcome = await logic.submit(
      name: "Fast Dismiss Wallet",
      chain: .ethereum,
      walletAddressInput: Self.validAddress)
    let elapsed = ContinuousClock.now - start

    guard case .created = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      fixture.cryptoSyncStore.cancelTimer()
      return
    }
    // The fire-and-forget sync is still parked at the alchemy hook;
    // submit must already be back so the sheet can dismiss. Allow a
    // generous budget — only scheduling overhead should land between
    // create and return.
    #expect(elapsed < .seconds(1))

    // Cancel the parked sync so the spawned 30-second sleep doesn't
    // outlive the test.
    fixture.cryptoSyncStore.cancelTimer()
  }

  @Test("Invalid address aborts before any repository or sync work")
  func invalidAddressShortCircuits() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore,
      accountInstrument: Self.profileInstrument)

    let outcome = await logic.submit(
      name: "Bad Address Wallet",
      chain: .ethereum,
      walletAddressInput: "vitalik.eth")

    guard case .invalidAddress = outcome else {
      Issue.record("Expected .invalidAddress, got \(outcome)")
      return
    }
    // No account was persisted and the build phase was never invoked.
    #expect(fixture.accountStore.accounts.isEmpty)
    #expect(fixture.alchemy.recordedCalls.isEmpty)
  }

  @Test("Empty/whitespace-only name is rejected without persisting")
  func emptyNameShortCircuits() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore,
      accountInstrument: Self.profileInstrument)

    let outcome = await logic.submit(
      name: "   ",
      chain: .ethereum,
      walletAddressInput: Self.validAddress)

    guard case .invalidAddress = outcome else {
      Issue.record("Expected .invalidAddress for empty name, got \(outcome)")
      return
    }
    #expect(fixture.accountStore.accounts.isEmpty)
    #expect(fixture.alchemy.recordedCalls.isEmpty)
  }

  @Test("Whitespace and mixed case in the address are normalised before persisting")
  func addressIsTrimmedAndLowercased() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: fixture.cryptoSyncStore,
      accountInstrument: Self.profileInstrument)

    // Mix of leading whitespace, mixed case, and trailing newline.
    let raw = "  0xABCDEF0123456789ABCDEF0123456789ABCDEF01\n"
    let outcome = await logic.submit(
      name: "Padded Address Wallet",
      chain: .ethereum,
      walletAddressInput: raw)

    guard case .created(let created) = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      return
    }
    #expect(
      created.walletAddress == raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
  }

  @Test("Nil cryptoSyncStore: account is created, sync is skipped")
  func nilSyncStoreSkipsKickOff() async throws {
    let fixture = try makeFixture()
    let logic = CryptoAccountCreationLogic(
      accountStore: fixture.accountStore,
      cryptoSyncStore: nil,
      accountInstrument: Self.profileInstrument)

    let outcome = await logic.submit(
      name: "Degraded Launch Wallet",
      chain: .ethereum,
      walletAddressInput: Self.validAddress)
    guard case .created = outcome else {
      Issue.record("Expected .created outcome, got \(outcome)")
      return
    }
    // Account persisted but no sync work fired (the test's sync store
    // exists but was never handed to the logic, so the alchemy stub
    // saw no activity). AccountStore is reactive — wait for the
    // observation to deliver the new account before reading.
    await expectEventually("new account observable") {
      fixture.accountStore.accounts.count == 1
    }
    #expect(fixture.alchemy.recordedCalls.isEmpty)
  }
}
