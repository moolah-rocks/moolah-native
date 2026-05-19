import Foundation
import Testing

@testable import Moolah

@Suite("CSVImportSetupStore")
@MainActor
struct CSVImportSetupStoreTests {

  private func tempDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("setup-store-\(UUID().uuidString)")
  }

  private func seedPending(
    _ staging: ImportStagingStore,
    filename: String = "cba-march.csv",
    bytes: Data
  ) async throws -> PendingSetupFile {
    let id = UUID()
    let path = await staging.stagingPath(for: id)
    let file = PendingSetupFile(
      id: id,
      originalFilename: filename,
      stagingPath: path,
      securityScopedBookmark: nil,
      detectedParserIdentifier: "generic-bank",
      detectedHeaders: ["date", "description", "debit", "credit", "balance"],
      parsedAt: Date(),
      sourceBookmark: nil)
    try await staging.stagePending(file, data: bytes)
    return file
  }

  @Test("regeneratePreview populates row count + preview for generic CBA file")
  func previewPopulatesForGeneric() async throws {
    let (backend, _) = try TestBackend.create()
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let staging = try ImportStagingStore(directory: dir)
    let importStore = ImportStore(
      backend: backend, staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions))
    let bytes = try CSVFixtureLoader.data("cba-everyday-standard")
    let pending = try await seedPending(staging, bytes: bytes)

    let store = CSVImportSetupStore(
      pending: pending, backend: backend,
      importStore: importStore, staging: staging)
    await store.regeneratePreview()

    #expect(store.rowCount == 5)
    #expect(store.detectedParserIdentifier == "generic-bank")
    #expect(store.isGenericParser == true)
    #expect(store.detectedMapping != nil)
    // Preview takes the first 5 parsed transactions; the opening balance row
    // skips, so we get up to 4.
    #expect(store.preview.count >= 3)
  }

  @Test("saveAndImport requires a target account")
  func saveRequiresTargetAccount() async throws {
    let (backend, _) = try TestBackend.create()
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let staging = try ImportStagingStore(directory: dir)
    let importStore = ImportStore(
      backend: backend, staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions))
    let bytes = try CSVFixtureLoader.data("cba-everyday-standard")
    let pending = try await seedPending(staging, bytes: bytes)
    let store = CSVImportSetupStore(
      pending: pending, backend: backend,
      importStore: importStore, staging: staging)

    let result = await store.saveAndImport()
    if case .failed = result {
      #expect(store.saveError != nil)
    } else {
      Issue.record("expected .failed without target account; got \(result)")
    }
  }

  @Test("saveAndImport creates the profile and imports")
  func saveAndImportPersistsProfileAndImports() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let staging = try ImportStagingStore(directory: dir)
    let importStore = ImportStore(
      backend: backend, staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions))
    let bytes = try CSVFixtureLoader.data("cba-everyday-standard")
    let pending = try await seedPending(staging, bytes: bytes)
    let store = CSVImportSetupStore(
      pending: pending, backend: backend,
      importStore: importStore, staging: staging)
    store.targetAccountId = accountId
    store.filenamePattern = "cba-*.csv"
    store.deleteAfterImport = true

    let result = await store.saveAndImport()
    if case .imported = result {
      let profiles = try await backend.csvImportProfiles.fetchAll()
      #expect(profiles.count == 1)
      #expect(profiles[0].accountId == accountId)
      #expect(profiles[0].filenamePattern == "cba-*.csv")
      #expect(profiles[0].deleteAfterImport == true)
      // Pending was cleared (importStore.finishSetup dismisses it).
      await importStore.reloadStagingLists()
      #expect(importStore.pendingSetup.isEmpty)
    } else {
      Issue.record("expected .imported; got \(result)")
    }
  }

  @Test("suggestedFilenamePattern turns stem-prefix into glob")
  func suggestedFilenamePatternBuildsGlob() {
    #expect(
      CSVImportSetupStore.suggestedFilenamePattern(from: "cba-april-2026.csv")
        == "cba-*.csv")
    #expect(
      CSVImportSetupStore.suggestedFilenamePattern(from: "Statement.csv")
        == "statement*.csv")
    #expect(
      CSVImportSetupStore.suggestedFilenamePattern(from: "anz-march-2026.txt")
        == "anz-*.txt")
  }

  @Test("preview applies the detected column mapping to real rows")
  func previewAppliesColumnMapping() async throws {
    let (backend, _) = try TestBackend.create()
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let staging = try ImportStagingStore(directory: dir)
    let importStore = ImportStore(
      backend: backend, staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions))
    let bytes = try CSVFixtureLoader.data("cba-everyday-standard")
    let pending = try await seedPending(staging, bytes: bytes)

    let store = CSVImportSetupStore(
      pending: pending, backend: backend,
      importStore: importStore, staging: staging)
    await store.regeneratePreview()

    let coffee = store.preview.first(where: {
      $0.rawDescription == "COFFEE HUT SYDNEY"
    })
    #expect(coffee != nil)
    #expect(coffee?.rawAmount == Decimal(string: "-5.50"))
    #expect(coffee?.rawBalance == Decimal(string: "994.50"))
  }

  @Test("user column-role overrides flow through to preview")
  func columnRoleOverridesApplied() async throws {
    let (backend, _) = try TestBackend.create()
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let staging = try ImportStagingStore(directory: dir)
    let importStore = ImportStore(
      backend: backend, staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions))
    let bytes = try CSVFixtureLoader.data("cba-everyday-standard")
    let pending = try await seedPending(staging, bytes: bytes)
    let store = CSVImportSetupStore(
      pending: pending, backend: backend,
      importStore: importStore, staging: staging)
    await store.regeneratePreview()
    // Detected mapping puts Description at column 1. Overriding it to
    // .ignore should route the raw description to an empty value.
    await store.applyColumnRole(.ignore, forColumn: 1)
    let firstTx = store.preview.first
    #expect(firstTx?.rawDescription.isEmpty == true)
  }

  @Test("saveAndImport persists column-role overrides on the profile")
  func saveAndImportPersistsColumnRoles() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let staging = try ImportStagingStore(directory: dir)
    let importStore = ImportStore(
      backend: backend, staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions))
    let bytes = try CSVFixtureLoader.data("cba-everyday-standard")
    let pending = try await seedPending(staging, bytes: bytes)
    let store = CSVImportSetupStore(
      pending: pending, backend: backend,
      importStore: importStore, staging: staging)
    store.targetAccountId = accountId
    await store.regeneratePreview()
    // Swap debit and credit columns so the detector's seed doesn't
    // match — forcing columnRoleRawValues onto the profile.
    await store.applyColumnRole(.credit, forColumn: 2)
    await store.applyColumnRole(.debit, forColumn: 3)

    let result = await store.saveAndImport()
    guard case .imported = result else {
      Issue.record("expected .imported, got \(result)")
      return
    }
    let profile = try #require(await backend.csvImportProfiles.fetchAll().first)
    #expect(!profile.columnRoleRawValues.isEmpty)
    // Columns 0..4 for the CBA file: Date, Description, Debit, Credit, Balance.
    // We swapped columns 2 and 3, so the persisted roles at those indices
    // should be `credit` and `debit` (not `debit` / `credit`).
    #expect(profile.columnRoleRawValues[2] == "credit")
    #expect(profile.columnRoleRawValues[3] == "debit")
  }

  @Test("deletePending removes the staged pending file")
  func deletePendingClears() async throws {
    let (backend, _) = try TestBackend.create()
    let dir = tempDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let staging = try ImportStagingStore(directory: dir)
    let importStore = ImportStore(
      backend: backend, staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions))
    let bytes = try CSVFixtureLoader.data("cba-everyday-standard")
    let pending = try await seedPending(staging, bytes: bytes)
    let store = CSVImportSetupStore(
      pending: pending, backend: backend,
      importStore: importStore, staging: staging)

    await store.deletePending()
    let remaining = try await staging.pendingFiles()
    #expect(remaining.isEmpty)
  }
}
