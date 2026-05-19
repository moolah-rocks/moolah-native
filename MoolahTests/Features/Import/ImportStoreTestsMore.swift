import Foundation
import Testing

@testable import Moolah

@Suite("ImportStore")
@MainActor
struct ImportStoreTestsMore {

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

  @Test("unparseable bytes land in failedFiles")
  func unparseableBytesLandFailed() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    // Headers that won't match any parser, and a row the generic parser can't
    // make sense of either.
    let bytes = Data("Foo,Bar,Baz\n1,2,3\n".utf8)
    let result = await store.ingest(
      data: bytes,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/bad.csv"), securityScoped: false))
    if case .failed = result {
      #expect(store.failedFiles.count == 1)
      #expect(store.failedFiles[0].originalFilename == "bad.csv")
      #expect(store.failedFiles[0].error.contains("Headers"))
    } else {
      Issue.record("expected .failed; got \(result)")
    }
  }

  @Test("malformed row (invalid date) carries row index AND row content into failedFiles")
  func malformedRowSurfacesIndex() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    // Valid shape on row 1, garbage date on row 2 (second data row).
    let bytes = Data(
      """
      Date,Description,Debit,Credit,Balance
      02/04/2024,COFFEE,5.50,,994.50
      not-a-date,COFFEE,5.50,,989.00
      """.utf8)
    let result = await store.ingest(
      data: bytes,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/bad.csv"), securityScoped: false))
    if case .failed = result {
      #expect(store.failedFiles.count == 1)
      #expect(store.failedFiles[0].offendingRowIndex == 2)
      #expect(store.failedFiles[0].offendingRow == ["not-a-date", "COFFEE", "5.50", "", "989.00"])
    } else {
      Issue.record("expected .failed")
    }
  }

  @Test("dismissPending clears the entry from both the store and staging")
  func dismissPendingClearsEntry() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    guard case .needsSetup(let id) = result else {
      Issue.record("expected .needsSetup")
      return
    }
    #expect(store.pendingSetup.count == 1)
    await store.dismissPending(id: id)
    #expect(store.pendingSetup.isEmpty)
  }

  @Test("dismissFailed clears the entry from both the store and staging")
  func dismissFailedClearsEntry() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let bytes = Data("Foo,Bar,Baz\n1,2,3\n".utf8)
    _ = await store.ingest(
      data: bytes,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/bad.csv"), securityScoped: false))
    #expect(store.failedFiles.count == 1)
    let id = store.failedFiles[0].id
    await store.dismissFailed(id: id)
    #expect(store.failedFiles.isEmpty)
  }

  @Test("finishSetup re-reads staged bytes, creates profile, and imports")
  func finishSetupCompletesImport() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    let first = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    guard case .needsSetup(let pendingId) = first else {
      Issue.record("expected .needsSetup on first ingest")
      return
    }

    // User confirms the setup form with a freshly-constructed profile.
    let newProfile = CSVImportProfile(
      accountId: accountId,
      parserIdentifier: "generic-bank",
      headerSignature: ["date", "description", "debit", "credit", "balance"])
    let second = await store.finishSetup(pendingId: pendingId, profile: newProfile)
    if case .imported(_, let imported, _) = second {
      #expect(imported.count == 4)
      #expect(store.pendingSetup.isEmpty)
      // Profile was persisted and routed.
      let profiles = try await backend.csvImportProfiles.fetchAll()
      #expect(profiles.count == 1)
    } else {
      Issue.record("expected .imported after finishSetup; got \(second)")
    }
  }

  // MARK: - ImportOrigin + profile update
}
