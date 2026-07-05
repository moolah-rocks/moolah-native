import Foundation
import Testing

@testable import Moolah

@Suite("ProfileSession")
@MainActor
struct ProfileSessionTests {
  private func makeProfile(label: String = "Test") -> Profile {
    Profile(label: label)
  }

  @Test("session creates non-nil stores")
  func createsStores() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let session = try ProfileSession(
      profile: makeProfile(), containerManager: containerManager)

    #expect(session.authStore.state == .loading)
    #expect(session.accountStore.accounts.ordered.isEmpty)
    #expect(session.transactionStore.transactions.isEmpty)
    #expect(session.categoryStore.categories.roots.isEmpty)
    #expect(session.earmarkStore.earmarks.ordered.isEmpty)
    #expect(session.investmentStore.values.isEmpty)
  }

  @Test("session ID matches profile ID")
  func sessionIdMatchesProfile() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = makeProfile()
    let session = try ProfileSession(profile: profile, containerManager: containerManager)

    #expect(session.id == profile.id)
  }

  @Test("two sessions for different profiles have independent backends")
  func independentSessions() throws {
    let containerManager1 = try ProfileContainerManager.forTesting()
    let containerManager2 = try ProfileContainerManager.forTesting()
    let session1 = try ProfileSession(
      profile: makeProfile(label: "One"), containerManager: containerManager1)
    let session2 = try ProfileSession(
      profile: makeProfile(label: "Two"), containerManager: containerManager2)

    #expect(session1.id != session2.id)
  }

  // The previous `onInvestmentValueChanged` callback wiring has been
  // removed — `AccountStore` now subscribes directly to
  // `investmentRepository.observeAllValues()`. End-to-end coverage that
  // an investment-value write reaches the account store lives in
  // `AccountStoreSyncRefreshTests.investmentValueWriteReachesAccountStore`.

  /// Regression for #102: a CloudKit profile must use `FullConversionService`,
  /// not `FiatConversionService`, so stock and crypto positions can be
  /// converted. `FiatConversionService` throws `unsupportedInstrumentKind`
  /// for any non-fiat input which (via Rule 11) blanks aggregates.
  @Test("CloudKit profile uses FullConversionService")
  func cloudKitProfileUsesFullConversionService() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "iCloud", currencyCode: "AUD", financialYearStartMonth: 7)
    let session = try ProfileSession(profile: profile, containerManager: containerManager)

    #expect(session.backend.conversionService is FullConversionService)
  }

  // MARK: - setUp() — async SwiftData → GRDB migration entry point (#575)

  /// The SwiftData → GRDB migration runs in `setUp()`, not
  /// `ProfileSession.init`, so the eight per-type `database.write`
  /// calls dispatch to GRDB's writer queue rather than blocking
  /// `@MainActor`. Calling `await session.setUp()` is
  /// idempotent — multiple awaits coalesce on the same in-flight task,
  /// which keeps view-side and caller-side awaits cheap and lets
  /// `SessionManager.session(for:)` fire-and-forget the first call
  /// without making the second slower.
  @Test("setUp() is idempotent when called repeatedly")
  func setUpIsIdempotent() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let session = try ProfileSession(
      profile: makeProfile(), containerManager: containerManager)
    try await session.setUp()
    try await session.setUp()
    try await session.setUp()
    // Reaching here without throwing is the success condition; the
    // real check is the file-private guard in `setUp()` returning the
    // existing task on subsequent calls rather than re-running.
  }

  @Test("CloudKit profile exposes cryptoTokenStore on session")
  func cloudKitProfileExposesCryptoTokenStore() throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "iCloud", currencyCode: "AUD", financialYearStartMonth: 7)
    let session = try ProfileSession(profile: profile, containerManager: containerManager)

    // Store exists and starts empty (registrations load on demand).
    #expect(session.cryptoTokenStore?.registrations.isEmpty == true)
  }

  /// The preview/legacy fallback path (`ProfileSession` built without a
  /// `SyncCoordinator`) must resolve crypto registrations from its
  /// per-profile registry through the conversion path — equivalent to the
  /// previous `cryptoRegistrations: { registry.allCryptoRegistrations() }`
  /// wiring. The fallback `CryptoPriceService`'s metadata lookup is late-bound
  /// to that registry in `makeCloudKitBackend`. Proven network-free: a token
  /// registered with `.spam` status must short-circuit `convertResult` to
  /// `.knownZero` (which only happens if the status was resolved from the
  /// registry). With an unbound/nil lookup the status would default to
  /// `.priced` and the call would instead attempt a price fetch.
  @Test("fallback session resolves crypto registry status through conversion")
  func fallbackSessionResolvesCryptoRegistryStatus() async throws {
    let containerManager = try ProfileContainerManager.forTesting()
    let profile = Profile(label: "iCloud", currencyCode: "AUD", financialYearStartMonth: 7)
    let session = try ProfileSession(profile: profile, containerManager: containerManager)

    let eth = Instrument.crypto(
      chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: eth.id, coingeckoId: "ethereum",
      binanceSymbol: "ETHUSDT")
    let registry = try #require(session.instrumentRegistry)
    try await registry.registerCrypto(eth, mapping: mapping, forcingStatus: .spam)

    let amount = InstrumentAmount(quantity: dec("1"), instrument: eth)
    let result = try await session.backend.conversionService.convertResult(
      amount, to: profile.instrument, on: Date())

    #expect(result == .knownZero(targetInstrument: profile.instrument))
  }
}
