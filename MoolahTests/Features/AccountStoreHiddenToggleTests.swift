import Foundation
import Testing

@testable import Moolah

/// Covers `AccountStore.canToggleHidden(_:)` — the rule behind the
/// "Hidden" toggle's enabled state in `EditAccountView`. Hiding a live
/// account is disallowed (zero-balance rule), but a hidden account must
/// always be unhideable even if it has since regained a balance.
@Suite("AccountStore/HiddenToggle")
@MainActor
struct AccountStoreHiddenToggleTests {

  @Test("a hidden account with a non-zero balance can still be unhidden")
  func hiddenLiveAccountCanToggle() async throws {
    let acctId = UUID()
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "UniBank", balance: Decimal(100000) / 100, isHidden: true, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    await expectEventually("hidden live account is toggleable") {
      store.accounts.by(id: acctId)?.isHidden == true && store.canToggleHidden(acctId)
    }
  }

  @Test("a visible account with a non-zero balance cannot be hidden")
  func visibleLiveAccountCannotToggle() async throws {
    let acctId = UUID()
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Active", balance: Decimal(100000) / 100, isHidden: false, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    await expectEventually("visible live account is not toggleable") {
      store.accounts.by(id: acctId)?.positions.isEmpty == false && !store.canToggleHidden(acctId)
    }
  }

  @Test("a visible account with a zero balance can be hidden")
  func visibleEmptyAccountCanToggle() async throws {
    let acctId = UUID()
    let (backend, database) = try TestBackend.create()
    _ = AccountStoreTestSupport.seedAccount(
      id: acctId, name: "Empty", isHidden: false, in: database)
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    await expectEventually("visible empty account is toggleable") {
      store.canToggleHidden(acctId)
    }
  }

  @Test("an unknown account id is not toggleable")
  func unknownAccountCannotToggle() async throws {
    let (backend, _) = try TestBackend.create()
    let store = AccountStore(
      repository: backend.accounts, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    #expect(!store.canToggleHidden(UUID()))
  }
}
