import Foundation
import Testing

@testable import Moolah

@Suite("AccountStore/Mutations")
@MainActor
struct AccountStoreMutationsTests {

  // MARK: - Show Hidden

  @Test("currentAccounts excludes hidden accounts by default")
  func hiddenAccountsExcluded() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Visible", balance: Decimal(100000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "Hidden", balance: Decimal(50000) / 100, isHidden: true, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await expectEventually("only the visible account is current") {
      store.currentAccounts.count == 1 && store.currentAccounts.first?.name == "Visible"
    }
  }

  @Test("currentAccounts includes hidden accounts when showHidden is true")
  func hiddenAccountsIncluded() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Visible", balance: Decimal(100000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "Hidden", balance: Decimal(50000) / 100, isHidden: true, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 2 },
      description: "both seeded accounts are observed"
    )
    store.showHidden = true

    await expectEventually("both accounts current once hidden shown") {
      store.currentAccounts.count == 2
    }
  }

  @Test("investmentAccounts respects showHidden flag")
  func hiddenInvestmentAccounts() async throws {
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Visible", type: .investment, balance: Decimal(100000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "Hidden", type: .investment, balance: Decimal(50000) / 100, isHidden: true,
      in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    await expectEventually("visible-only investment accounts count is 1") {
      store.investmentAccounts.count == 1
    }
    store.showHidden = true
    await expectEventually("investment accounts count is 2 with hidden shown") {
      store.investmentAccounts.count == 2
    }
  }

  @Test("convertedCurrentTotal refreshes when showHidden toggles to include hidden accounts")
  func convertedCurrentTotalRefreshesOnShowHiddenToggle() async throws {
    // Without a recompute on toggle the sidebar shows hidden account rows
    // (filter is computed from showHidden) but the "Current Total" stays
    // pinned to the visible-only sum until the next emission.
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Visible", balance: Decimal(100000) / 100, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "Hidden", balance: Decimal(50000) / 100, isHidden: true, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    try await store.waitForNextEmission(
      matching: { $0.convertedCurrentTotal?.quantity == Decimal(100000) / 100 },
      description: "initial total reflects visible account only"
    )

    store.showHidden = true

    try await store.waitForNextEmission(
      matching: { $0.convertedCurrentTotal?.quantity == Decimal(150000) / 100 },
      description: "total recomputes to include hidden account"
    )
  }

  @Test("investmentAccounts includes crypto accounts")
  func investmentAccountsIncludesCrypto() async throws {
    // Sidebar feeds its "Investments" section from `investmentAccounts`. A
    // strict `type == .investment` filter would silently drop newly-created
    // crypto wallets — the acceptance criterion is .bucket == .investments
    // so both kinds appear together.
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      name: "Brokerage", type: .investment, balance: 0, in: database)
    _ = AccountStoreTestSupport.seedAccount(
      name: "ETH Wallet", type: .crypto,
      valuationMode: .calculatedFromTrades, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)

    // Poll the asserted snapshot directly: the rate-tick recompute (which
    // `FixedConversionService.observeRates()` fires synchronously on
    // subscription) can race the accounts observation, so an early tick can
    // land before `apply(accounts:)` has run. Polling the final condition
    // closes that window instead of reading once after a single emission.
    await expectEventually("both brokerage and crypto appear in investmentAccounts") {
      store.investmentAccounts.map(\.name).sorted() == ["Brokerage", "ETH Wallet"]
    }
  }

  // MARK: - Instrument Persistence

  @Test
  func testCreatePersistsInstrument() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()
    let usdInstrument = Instrument.fiat(code: "USD")
    let account = Account(
      id: UUID(), name: "USD Checking", type: .bank, instrument: usdInstrument, position: 0,
      isHidden: false)

    let created = try await store.create(account)

    #expect(created.instrument.id == usdInstrument.id)

    await expectEventually("store sees created account with USD instrument") {
      store.accounts.first?.instrument.id == usdInstrument.id
    }

    let fetched = try await backend.accounts.fetchAll()
    #expect(fetched.first?.instrument.id == usdInstrument.id)
  }

  /// Regression: creating an empty investment account (no positions, no
  /// external investment value) must populate `convertedBalances` with a zero
  /// amount in the account's instrument. Without this, the sidebar row spins
  /// forever because `AccountSidebarRow` reads `convertedBalances[id]` and
  /// `SidebarRowView` renders a `ProgressView` whenever that entry is `nil`.
  @Test
  func testCreateEmptyInvestmentAccountPopulatesConvertedBalance() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()
    let account = Account(
      id: UUID(), name: "Brokerage", type: .investment,
      instrument: .defaultTestInstrument, position: 0, isHidden: false)

    let created = try await store.create(account)

    await expectEventually("convertedBalance for new account is zero in its instrument") {
      let balance = store.convertedBalances[created.id]
      return balance?.quantity == 0
        && balance?.instrument.id == Instrument.defaultTestInstrument.id
    }
  }

  @Test
  func testUpdatePersistsChangedInstrument() async throws {
    let (backend, database) = try TestBackend.create()
    let original = AccountStoreTestSupport.seedAccount(name: "Savings", in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.by(id: original.id) != nil },
      description: "seeded account is observed"
    )

    let eurInstrument = Instrument.fiat(code: "EUR")
    var modified = original
    modified.instrument = eurInstrument

    let updated = try await store.update(modified)

    #expect(updated.instrument.id == eurInstrument.id)

    let fetched = try await backend.accounts.fetchAll()
    #expect(fetched.first?.instrument.id == eurInstrument.id)
  }

  // MARK: - reorderAccounts

  @Test
  func testReorderAccountsPersistsNewPositions() async throws {
    let firstId = UUID()
    let secondId = UUID()
    let thirdId = UUID()
    let (backend, database) = try TestBackend.create()
    let first = AccountStoreTestSupport.seedAccount(
      id: firstId, name: "A", position: 0, in: database)
    let second = AccountStoreTestSupport.seedAccount(
      id: secondId, name: "B", position: 1, in: database)
    let third = AccountStoreTestSupport.seedAccount(
      id: thirdId, name: "C", position: 2, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForNextEmission(
      matching: { $0.accounts.count == 3 },
      description: "all three accounts observed"
    )

    // Reverse order: C, B, A
    await store.reorderAccounts([third, second, first])

    await expectEventually("store sees reordered accounts with no error") {
      store.error == nil && store.accounts.ordered.map(\.name) == ["C", "B", "A"]
    }

    let persisted = try await backend.accounts.fetchAll().sorted { $0.position < $1.position }
    #expect(persisted.map(\.name) == ["C", "B", "A"])
  }

  @Test
  func testReorderAccountsSurfacesErrorOnFailure() async throws {
    let idA = UUID()
    let idB = UUID()
    let repository = FailingAccountRepository(
      accounts: [
        Account(
          id: idA, name: "A", type: .bank, instrument: .defaultTestInstrument, position: 0,
          isHidden: false),
        Account(
          id: idB, name: "B", type: .bank, instrument: .defaultTestInstrument, position: 1,
          isHidden: false),
      ])
    let store = AccountStore(
      repository: repository, conversionService: FixedConversionService(),
      targetInstrument: .defaultTestInstrument)
    await expectEventually("initial accounts observed in order") {
      store.accounts.ordered.map(\.name) == ["A", "B"]
    }

    // Start failing repository updates.
    repository.shouldFail = true
    let accounts = store.accounts.ordered
    await store.reorderAccounts([accounts[1], accounts[0]])

    // Error must be surfaced, not silently swallowed.
    #expect(store.error != nil)
    // Local state continues to reflect the authoritative repository
    // ordering — the reactive store does not optimistically mutate, so
    // a failed reorder leaves the original ordering visible.
    #expect(store.accounts.ordered.map(\.name) == ["A", "B"])
  }
}
