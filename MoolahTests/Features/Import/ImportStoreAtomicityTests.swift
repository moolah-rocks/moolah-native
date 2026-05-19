import Foundation
import GRDB
import Testing

@testable import Moolah

/// All-or-nothing contract for `ImportStore.ingest(_:source:)`. The CSV
/// pipeline persists every surviving candidate in a single bulk write
/// (`TransactionRepository.createMany`); a failure mid-write must roll
/// back so the user can simply re-run the same file. A half-written
/// session is hard to reconcile against on retry — the dedup window
/// would have to be narrowed manually to skip the rows that did land.
@Suite("ImportStore — atomic ingest")
@MainActor
struct ImportStoreAtomicityTests {

  private func tempStagingDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("import-store-\(UUID().uuidString)", isDirectory: true)
  }

  private func makeStore(
    backend: any BackendProvider
  ) throws -> (ImportStore, URL) {
    let dir = tempStagingDirectory()
    let staging = try ImportStagingStore(directory: dir)
    let store = ImportStore(
      backend: backend, staging: staging,
      transferDetection: TransferDetectionCoordinator(
        transactions: backend.transactions,
        suggestions: backend.transferSuggestions))
    return (store, dir)
  }

  @Test("ingest fails atomically when the bulk insert throws — no rows land")
  func ingestFailsAtomically() async throws {
    let (backend, database) = try TestBackend.create()
    let accountId = UUID()
    _ = try await backend.accounts.create(
      Account(
        id: accountId, name: "Cash", type: .bank, instrument: .AUD,
        positions: [], position: 0, isHidden: false),
      openingBalance: nil)
    _ = try await backend.csvImportProfiles.create(
      CSVImportProfile(
        accountId: accountId,
        parserIdentifier: "generic-bank",
        headerSignature: ["date", "description", "debit", "credit", "balance"]))

    // ABORT trigger on `transaction_leg` insert — the bulk-insert path
    // builds N transactions and inserts their legs in one write block;
    // the trigger fires on the first leg insert and the whole write
    // transaction must roll back. Installed AFTER profile / account
    // seeding so those upstream inserts are not disturbed.
    try await database.write { database in
      try database.execute(
        sql: """
          CREATE TRIGGER fail_import_legs
          BEFORE INSERT ON transaction_leg
          BEGIN
              SELECT RAISE(ABORT, 'forced failure for rollback test');
          END;
          """)
    }

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    let data = try CSVFixtureLoader.data("cba-everyday-standard")
    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))

    // The fixture would land 4 transactions on the happy path. Under
    // the failing trigger we expect `.failed` and an empty backend.
    guard case .failed = result else {
      Issue.record("expected .failed but got \(result)")
      return
    }
    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    #expect(page.transactions.isEmpty)
    let allLegs = try await database.read { database in
      try TransactionLegRow.fetchAll(database)
    }
    #expect(allLegs.isEmpty)
  }
}
