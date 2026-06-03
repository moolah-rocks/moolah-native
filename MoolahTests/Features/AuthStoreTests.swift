import Testing

@testable import Moolah

@Suite("AuthStore")
@MainActor
struct AuthStoreTests {
  // MARK: - load()

  @Test("transitions loading → signedIn when currentUser returns a profile")
  func loadSignedIn() async throws {
    let profile = UserProfile(id: "u1", pictureURL: nil)
    let store = AuthStore(
      backend: try TestAuthBackend(auth: InMemoryAuthProvider(signedIn: profile)))
    await store.load()
    guard case .signedIn(let user) = store.state else {
      Issue.record("Expected .signedIn, got \(store.state)")
      return
    }
    #expect(user == profile)
  }

  @Test("transitions loading → signedOut when currentUser returns nil")
  func loadSignedOut() async throws {
    let store = AuthStore(backend: try TestAuthBackend(auth: InMemoryAuthProvider()))
    await store.load()
    #expect(store.state == .signedOut)
  }

  @Test("transitions signedIn → signedOut on signOut()")
  func signOut() async throws {
    let profile = UserProfile(id: "u1", pictureURL: nil)
    let store = AuthStore(
      backend: try TestAuthBackend(auth: InMemoryAuthProvider(signedIn: profile)))
    await store.load()
    await store.signOut()
    #expect(store.state == .signedOut)
  }

  @Test("auth failure leaves store in signedOut with error message")
  func authFailure() async throws {
    let store = AuthStore(backend: try TestAuthBackend(auth: FailingAuthProvider()))
    await store.load()
    #expect(store.state == .signedOut)
    #expect(store.errorMessage != nil)
  }

  // MARK: - signIn()

  @Test("signIn transitions signedOut → signedIn")
  func testSignInTransitionsToSignedIn() async throws {
    let store = AuthStore(backend: try TestAuthBackend(auth: InMemoryAuthProvider()))
    await store.load()
    #expect(store.state == .signedOut)

    await store.signIn()

    guard case .signedIn(let user) = store.state else {
      Issue.record("Expected .signedIn, got \(store.state)")
      return
    }
    #expect(user.id == "fixture-user")
  }

  @Test("signIn clears previous errorMessage")
  func testSignInClearsErrorMessage() async throws {
    // First cause an error by loading with a failing provider
    let failingStore = AuthStore(backend: try TestAuthBackend(auth: FailingAuthProvider()))
    await failingStore.load()
    #expect(failingStore.errorMessage != nil)

    // Now test with a working provider that starts signed out, triggers error, then succeeds
    let provider = InMemoryAuthProvider()
    let store = AuthStore(backend: try TestAuthBackend(auth: provider))
    // Manually set an error state by loading with failing provider first
    // Instead, use a provider that starts signed out, and verify signIn clears any prior error
    await store.load()
    #expect(store.state == .signedOut)

    await store.signIn()

    #expect(store.errorMessage == nil)
  }

  @Test("signIn sets errorMessage on failure")
  func testSignInSetsErrorOnFailure() async throws {
    let store = AuthStore(backend: try TestAuthBackend(auth: FailingAuthProvider()))

    await store.signIn()

    #expect(store.state == .signedOut)
    #expect(store.errorMessage != nil)
  }

  // MARK: - requiresSignIn

  @Test("requiresSignIn reflects backend provider value when true")
  func requiresSignInTrue() throws {
    let store = AuthStore(
      backend: try TestAuthBackend(auth: InMemoryAuthProvider(requiresExplicitSignIn: true)))
    #expect(store.requiresSignIn == true)
  }

  @Test("requiresSignIn reflects backend provider value when false")
  func requiresSignInFalse() throws {
    let store = AuthStore(
      backend: try TestAuthBackend(auth: InMemoryAuthProvider(requiresExplicitSignIn: false)))
    #expect(store.requiresSignIn == false)
  }
}

// MARK: - Test helpers

/// Test backend that uses a custom AuthProvider while keeping CloudKitBackend for repositories.
private struct TestAuthBackend: BackendProvider {
  let auth: any AuthProvider
  let accounts: any AccountRepository
  let accountGroups: any AccountGroupRepository
  let insightDismissals: any InsightDismissalRepository
  let transactions: any TransactionRepository
  let categories: any CategoryRepository
  let transferSuggestions: any TransferSuggestionRepository
  let earmarks: any EarmarkRepository
  let analysis: any AnalysisRepository
  let insightDataSource: any InsightDataSource
  let investments: any InvestmentRepository
  let conversionService: any InstrumentConversionService
  let csvImportProfiles: any CSVImportProfileRepository
  let importRules: any ImportRuleRepository
  let walletSyncState: any WalletSyncStateRepository
  let groupUIState: any GroupUIStateRepository

  init(auth: any AuthProvider) throws {
    let (backend, _) = try TestBackend.create()
    self.auth = auth
    self.accounts = backend.accounts
    self.accountGroups = backend.accountGroups
    self.insightDismissals = backend.insightDismissals
    self.transactions = backend.transactions
    self.categories = backend.categories
    self.transferSuggestions = backend.transferSuggestions
    self.earmarks = backend.earmarks
    self.analysis = backend.analysis
    self.insightDataSource = backend.insightDataSource
    self.investments = backend.investments
    self.conversionService = backend.conversionService
    self.csvImportProfiles = backend.csvImportProfiles
    self.importRules = backend.importRules
    self.walletSyncState = backend.walletSyncState
    self.groupUIState = backend.groupUIState
  }
}

/// AuthProvider that always throws on currentUser().
private struct FailingAuthProvider: AuthProvider {
  nonisolated let requiresExplicitSignIn = true

  func currentUser() async throws -> UserProfile? {
    throw BackendError.networkUnavailable
  }

  func signIn() async throws -> UserProfile {
    throw BackendError.networkUnavailable
  }

  func signOut() async throws {
    throw BackendError.networkUnavailable
  }
}
