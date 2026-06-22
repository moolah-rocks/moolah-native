import Foundation
import GRDB

@testable import Moolah

/// Shared fixtures for the `SidebarDropDispatch` test suites. The
/// dispatch helper takes three stores at every entry point, so the
/// test boilerplate (spin up TestBackend, attach stores, wait for the
/// first observation tick) recurs across every suite and gets
/// extracted here to keep individual test files short.
///
/// `DispatchTestStores` bundles the trio so callers don't have to
/// destructure a tuple at every test (a 3-element tuple trips
/// SwiftLint's `large_tuple` rule).
@MainActor
enum SidebarDropDispatchTestSupport {

  /// The trio of stores `SidebarDropDispatch` operates against. Bundled
  /// into a struct so the `makeStores` helper can return it without
  /// tripping SwiftLint's `large_tuple` rule.
  struct DispatchTestStores {
    let accountStore: AccountStore
    let accountGroupStore: AccountGroupStore
    let groupUIStateStore: GroupUIStateStore
  }

  /// Spins up an `AccountStore` + `AccountGroupStore` + `GroupUIStateStore`
  /// triple over a single `TestBackend`. Mirrors the helper in
  /// `AccountGroupStoreMutationsTests` — `seedAccounts` go in via the
  /// pre-subscription `TestBackend.seed(accounts:in:)`; groups are
  /// created after subscription by the test bodies that need them, so
  /// the observation ticks line up cleanly.
  static func makeStores(
    seedAccounts: [Account] = [],
    in database: any GRDB.DatabaseWriter,
    backend: CloudKitBackend
  ) async throws -> DispatchTestStores {
    TestBackend.seed(accounts: seedAccounts, in: database)
    let accountStore = AccountStore(
      repository: backend.accounts,
      conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    let accountGroupStore = AccountGroupStore(repository: backend.accountGroups)
    let groupUIStateStore = GroupUIStateStore(repository: backend.groupUIState)
    try await accountGroupStore.waitForFirstEmission()
    try await accountStore.waitForNextEmission(
      matching: { $0.accounts.ordered.count == seedAccounts.count },
      description: "accounts seeded observed")
    try await groupUIStateStore.waitForFirstEmission()
    return DispatchTestStores(
      accountStore: accountStore,
      accountGroupStore: accountGroupStore,
      groupUIStateStore: groupUIStateStore)
  }

  /// Convenience for a `.current` bucket account (no crypto-specific
  /// requirements). Uses caller-supplied positions so the seeded order
  /// is explicit at the call site.
  static func bankAccount(name: String, position: Int) -> Account {
    Account(
      id: UUID(),
      name: name,
      type: .bank,
      instrument: .defaultTestInstrument,
      position: position)
  }
}
