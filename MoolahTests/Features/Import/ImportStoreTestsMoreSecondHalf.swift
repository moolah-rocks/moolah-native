import Foundation
import Testing

@testable import Moolah

@Suite("ImportStore")
@MainActor
struct ImportStoreTestsMoreSecondHalf {

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

  @Test("every persisted transaction carries matching importOrigin")
  func importOriginStampedOnEveryPersisted() async throws {
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
    guard case let .imported(sessionId, imported, _) = result else {
      Issue.record("expected .imported")
      return
    }
    #expect(imported.allSatisfy { $0.importOrigin?.singleOrigin?.importSessionId == sessionId })
    #expect(
      imported.allSatisfy { $0.importOrigin?.singleOrigin?.parserIdentifier == "generic-bank" })
    #expect(imported.allSatisfy { $0.importOrigin?.singleOrigin?.sourceFilename == "cba.csv" })
  }

  @Test("profile lastUsedAt is bumped after a successful routed import")
  func profileLastUsedAtBumped() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let before = Date()
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    let profiles = try await backend.csvImportProfiles.fetchAll()
    let lastUsedAt = profiles[0].lastUsedAt
    #expect(lastUsedAt != nil)
    if let lastUsedAt {
      #expect(lastUsedAt >= before)
    }
  }

  @Test("deleteAfterImport removes the source file after persistence")
  func deleteAfterImportRemovesSource() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(
      backend, accountId: accountId, deleteAfterImport: true)
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let tmp = FileManager.default.temporaryDirectory
      .appendingPathComponent("deleteable-\(UUID().uuidString).csv")
    try Data(try cbaFixtureBytes()).write(to: tmp)
    _ = await store.ingest(
      data: try Data(contentsOf: tmp),
      source: .pickedFile(url: tmp, securityScoped: false))
    #expect(FileManager.default.fileExists(atPath: tmp.path) == false)
  }

  /// Shared fixture for end-to-end Movements-parser assertions. Returns the
  /// imported `Transaction`s so each `@Test` can assert its own behaviour
  /// slice without duplicating the seed-account-and-profile setup.
  private func ingestMovementsFixture() async throws -> [Transaction] {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Brokerage")
    _ = try await seedProfile(
      backend,
      accountId: accountId,
      parser: "selfwealth-movements",
      signature: [
        "trade date", "settlement date", "action", "reference", "code", "name",
        "units", "average price", "consideration", "brokerage", "total",
      ])
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try CSVFixtureLoader.data("selfwealth-movements")
    let result = await store.ingest(
      data: data,
      source: .pickedFile(
        url: URL(fileURLWithPath: "/tmp/selfwealth-movements.csv"), securityScoped: false))
    guard case let .imported(_, imported, _) = result else {
      Issue.record("expected .imported; got \(result)")
      return []
    }
    return imported
  }

  @Test("SelfWealth Movements Buy creates a three-leg cash + position + brokerage transaction")
  func selfWealthMovementsBuyEndToEnd() async throws {
    let imported = try await ingestMovementsFixture()
    #expect(
      imported.allSatisfy {
        $0.importOrigin?.singleOrigin?.parserIdentifier == "selfwealth-movements"
      })
    let buy = try #require(
      imported.first(where: {
        $0.importOrigin?.singleOrigin?.rawDescription.contains("Buy") == true
          && $0.importOrigin?.singleOrigin?.rawDescription.contains("WXYZ") == true
      }))
    #expect(buy.legs.count == 3)
    let cashLeg = buy.legs.first(where: {
      $0.instrument == .AUD && $0.quantity == Decimal(string: "-5000.00")
    })
    #expect(cashLeg?.type == .trade)
    let positionLeg = buy.legs.first(where: { $0.instrument.id == "ASX:WXYZ.AX" })
    #expect(positionLeg?.quantity == 100)
    #expect(positionLeg?.type == .trade)
    let brokerageLeg = buy.legs.first(where: {
      $0.instrument == .AUD && $0.quantity == Decimal(string: "-9.50")
    })
    #expect(brokerageLeg?.type == .expense)
  }

  @Test("SelfWealth Movements Sell + In rows produce expected leg shapes end-to-end")
  func selfWealthMovementsSellAndInEndToEnd() async throws {
    let imported = try await ingestMovementsFixture()
    let sell = imported.first(where: {
      $0.importOrigin?.singleOrigin?.rawDescription.contains("Sell") == true
        && $0.importOrigin?.singleOrigin?.rawDescription.contains("ABCD") == true
    })
    let sellPosition = sell?.legs.first(where: { $0.instrument.id == "ASX:ABCD.AX" })
    #expect(sellPosition?.quantity == -50)
    // In row: one-leg position income, no cash counterpart. User reclassifies
    // in-app if it's actually a transfer rather than DRP.
    let drp = imported.first(where: {
      $0.legs.count == 1 && $0.legs.first?.instrument.id == "ASX:WXYZ.AX"
    })
    #expect(drp?.legs.first?.type == .income)
  }

  @Test("recentSessions carries one entry per successful ingest")
  func recentSessionsPopulated() async throws {
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
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    #expect(store.recentSessions.count == 2)
    // Newest-first ordering
    #expect(store.recentSessions[0].importedCount == 0)  // second run: all dup
    #expect(store.recentSessions[1].importedCount == 4)
  }
}
