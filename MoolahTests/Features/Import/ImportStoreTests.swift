import Foundation
import Testing

@testable import Moolah

@Suite("ImportStore")
@MainActor
struct ImportStoreTests {

  // MARK: - Fixtures + helpers

  private func tempStagingDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("import-store-\(UUID().uuidString)", isDirectory: true)
  }

  private func makeStore(
    backend: any BackendProvider,
    directory: URL? = nil
  ) throws -> (ImportStore, URL) {
    let dir = directory ?? tempStagingDirectory()
    let staging = try ImportStagingStore(directory: dir)
    let store = ImportStore(
      backend: backend, staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions))
    return (store, dir)
  }

  private func seedAccount(
    _ backend: CloudKitBackend,
    id: UUID,
    name: String,
    instrument: Instrument = .AUD
  ) async throws {
    _ = try await backend.accounts.create(
      Account(
        id: id, name: name, type: .bank, instrument: instrument,
        positions: [], position: 0, isHidden: false),
      openingBalance: nil)
  }

  private func seedProfile(
    _ backend: CloudKitBackend,
    accountId: UUID,
    parser: String = "generic-bank",
    signature: [String] = ["date", "description", "debit", "credit", "balance"],
    deleteAfterImport: Bool = false,
    filenamePattern: String? = nil
  ) async throws -> CSVImportProfile {
    let profile = CSVImportProfile(
      accountId: accountId,
      parserIdentifier: parser,
      headerSignature: signature,
      filenamePattern: filenamePattern,
      deleteAfterImport: deleteAfterImport)
    return try await backend.csvImportProfiles.create(profile)
  }

  private func cbaFixtureBytes() throws -> Data {
    try CSVFixtureLoader.data("cba-everyday-standard")
  }

  // MARK: - Routing

  @Test("first-time ingest with no profile lands in Needs Setup")
  func firstTimeIngestNeedsSetup() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    if case .needsSetup(let id) = result {
      #expect(store.pendingSetup.count == 1)
      #expect(store.pendingSetup[0].id == id)
    } else {
      Issue.record("expected .needsSetup; got \(result)")
    }
  }

  @Test("routed silently when profile matches — all rows persisted")
  func routedSilentlyAllRowsPersisted() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()

    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))

    if case let .imported(_, imported, skipped) = result {
      // CBA fixture has 5 data rows; row 1 is opening balance (.skip from parser),
      // so 4 real transactions land.
      #expect(imported.count == 4)
      #expect(skipped == 0)
      let page = try await backend.transactions.fetch(
        filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
      #expect(page.transactions.count == 4)
    } else {
      Issue.record("expected .imported; got \(result)")
    }
  }

  @Test("second ingest of the same bytes dedupes every row")
  func secondIngestDedupesAll() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    if case let .imported(_, imported, skipped) = result {
      #expect(imported.isEmpty)
      #expect(skipped == 4)  // 4 non-skip candidates all match existing
    } else {
      Issue.record("expected .imported")
    }
  }

  @Test("dropping onto a specific account bypasses the matcher")
  func dragToAccountBypassesMatcher() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Dropped Target")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()

    let result = await store.ingest(
      data: data,
      source: .droppedFile(
        url: URL(fileURLWithPath: "/tmp/cba.csv"),
        forcedAccountId: accountId))
    if case .imported(_, let imported, _) = result {
      #expect(imported.count == 4)
      // A profile was created on the fly.
      let profiles = try await backend.csvImportProfiles.fetchAll()
      #expect(profiles.count == 1)
      #expect(profiles[0].accountId == accountId)
    } else {
      Issue.record("expected .imported; got \(result)")
    }
  }

  // MARK: - Transfer detection

  @Test("ingesting both legs of an internal transfer suggests the pair on both rows")
  func crossAccountTransferSuggestedAfterImport() async throws {
    let (backend, _) = try TestBackend.create()
    let everydayId = UUID()
    let savingsId = UUID()
    try await seedAccount(backend, id: everydayId, name: "Everyday")
    try await seedAccount(backend, id: savingsId, name: "Savings")
    _ = try await seedProfile(
      backend, accountId: everydayId, filenamePattern: "*everyday-transfer*")
    _ = try await seedProfile(
      backend, accountId: savingsId, filenamePattern: "*savings-transfer*")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    let result1 = await store.ingest(
      data: try CSVFixtureLoader.data("cba-everyday-transfer"),
      source: .pickedFile(
        url: URL(fileURLWithPath: "/tmp/cba-everyday-transfer.csv"),
        securityScoped: false))
    guard case .imported = result1 else {
      Issue.record("first ingest expected .imported; got \(result1)")
      return
    }
    let result2 = await store.ingest(
      data: try CSVFixtureLoader.data("cba-savings-transfer"),
      source: .pickedFile(
        url: URL(fileURLWithPath: "/tmp/cba-savings-transfer.csv"),
        securityScoped: false))
    guard case .imported = result2 else {
      Issue.record("second ingest expected .imported; got \(result2)")
      return
    }

    let everyday = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: everydayId), page: 0, pageSize: 50
    ).transactions
    let savings = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: savingsId), page: 0, pageSize: 50
    ).transactions
    let everydayTx = try #require(everyday.first)
    let savingsTx = try #require(savings.first)

    // Detection writes one synced `TransferSuggestion` record over the
    // unordered pair; both rows resolve the other via the record.
    let touchingEveryday = try await backend.transferSuggestions
      .suggestions(touching: everydayTx.id)
    let touchingSavings = try await backend.transferSuggestions
      .suggestions(touching: savingsTx.id)
    #expect(
      touchingEveryday.first?.counterpart(of: everydayTx.id) == savingsTx.id)
    #expect(
      touchingSavings.first?.counterpart(of: savingsTx.id) == everydayTx.id)
    #expect(touchingEveryday.first == touchingSavings.first)
  }

  // MARK: - Rules engine integration
}
