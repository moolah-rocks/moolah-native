import Foundation
import Testing

@testable import ImportExtensionKit
@testable import Moolah

@Suite("ImportStore.startWebReview")
@MainActor
struct ImportStoreWebReviewTests {

  // MARK: - Fixtures

  private func tempStagingDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("import-store-web-\(UUID().uuidString)", isDirectory: true)
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

  /// Build a web profile that matches `ImportStore.startWebReview`'s
  /// synthesised parserIdentifier / headerSignature for a given host so the
  /// matcher routes silently.
  private func seedWebProfile(
    _ backend: CloudKitBackend,
    accountId: UUID,
    host: String
  ) async throws -> CSVImportProfile {
    let profile = CSVImportProfile(
      accountId: accountId,
      parserIdentifier: "web/\(host)",
      headerSignature: ["web", host])
    return try await backend.csvImportProfiles.create(profile)
  }

  private func makePayload(
    host: String = "chase.com",
    accountHint: String? = "1234",
    rows: [ImportPayloadRow]
  ) -> ImportPayload {
    ImportPayload(
      schemaVersion: 1,
      sourceHost: host,
      sourceURL: "https://\(host)/dashboard",
      capturedAt: Date(timeIntervalSince1970: 1_717_000_000),
      accountHint: accountHint,
      currencyHint: "AUD",
      rows: rows)
  }

  private func sampleRows(count: Int = 2) -> [ImportPayloadRow] {
    (0..<count).map { index in
      ImportPayloadRow(
        date: "2026-05-\(String(format: "%02d", 10 + index))",
        amount: "-\(10 + index).50",
        description: "Coffee shop \(index)",
        balance: nil,
        reference: "TXN-\(index)")
    }
  }

  // MARK: - Tests

  @Test("first-time web import with no profile lands in Needs Setup")
  func firstTimeWebImportNeedsSetup() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = makePayload(rows: sampleRows())
    let result = await store.startWebReview(payload: payload)

    if case .needsSetup(let id) = result {
      #expect(store.pendingSetup.count == 1)
      #expect(store.pendingSetup[0].id == id)
      #expect(store.pendingSetup[0].detectedParserIdentifier == "web/chase.com")
    } else {
      Issue.record("expected .needsSetup; got \(result)")
    }
  }

  @Test("routed silently when a web profile matches — all rows persisted")
  func routedSilentlyAllRowsPersisted() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedWebProfile(backend, accountId: accountId, host: "chase.com")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = makePayload(rows: sampleRows(count: 3))
    let result = await store.startWebReview(payload: payload)

    if case let .imported(_, imported, skipped) = result {
      #expect(imported.count == 3)
      #expect(skipped == 0)
      let page = try await backend.transactions.fetch(
        filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
      #expect(page.transactions.count == 3)
    } else {
      Issue.record("expected .imported; got \(result)")
    }
  }

  @Test("second import of the same payload dedupes every row")
  func secondImportDedupesAll() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedWebProfile(backend, accountId: accountId, host: "chase.com")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = makePayload(rows: sampleRows(count: 3))
    _ = await store.startWebReview(payload: payload)
    let result = await store.startWebReview(payload: payload)

    if case let .imported(_, imported, skipped) = result {
      #expect(imported.isEmpty)
      #expect(skipped == 3)
    } else {
      Issue.record("expected .imported; got \(result)")
    }
  }

  @Test("zero-row payload imports nothing without throwing")
  func zeroRowPayloadIsNoOp() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = makePayload(rows: [])
    let result = await store.startWebReview(payload: payload)

    if case let .imported(_, imported, skipped) = result {
      #expect(imported.isEmpty)
      #expect(skipped == 0)
    } else {
      Issue.record("expected .imported (empty); got \(result)")
    }
    #expect(store.pendingSetup.isEmpty)
    #expect(store.failedFiles.isEmpty)
  }

  @Test("persisted transactions carry the web source's host as the parser identifier")
  func sourceTaggingFlowsToImportOrigin() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedWebProfile(backend, accountId: accountId, host: "chase.com")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = makePayload(rows: sampleRows(count: 1))
    _ = await store.startWebReview(payload: payload)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    let transaction = try #require(page.transactions.first)
    let origin = try #require(transaction.importOrigin?.singleOrigin)
    #expect(origin.parserIdentifier == "web/chase.com")
  }

  @Test("amount sign flows through — negative becomes expense, positive becomes income")
  func amountSignPreserved() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedWebProfile(backend, accountId: accountId, host: "chase.com")
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = makePayload(rows: [
      ImportPayloadRow(
        date: "2026-05-10", amount: "-25.00", description: "Outflow"),
      ImportPayloadRow(
        date: "2026-05-11", amount: "100.00", description: "Inflow"),
    ])
    _ = await store.startWebReview(payload: payload)

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    let outflow = try #require(
      page.transactions.first(where: {
        $0.importOrigin?.singleOrigin?.rawDescription == "Outflow"
      }))
    let inflow = try #require(
      page.transactions.first(where: {
        $0.importOrigin?.singleOrigin?.rawDescription == "Inflow"
      }))
    #expect(outflow.legs.first?.type == .expense)
    #expect(outflow.legs.first?.quantity == Decimal(string: "-25.00"))
    #expect(inflow.legs.first?.type == .income)
    #expect(inflow.legs.first?.quantity == Decimal(string: "100.00"))
  }

  @Test("malformed amount stages the payload as a failed file")
  func malformedAmountStagesFailed() async throws {
    let (backend, _) = try TestBackend.create()
    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }

    let payload = makePayload(rows: [
      ImportPayloadRow(date: "2026-05-10", amount: "not-a-number", description: "Junk")
    ])
    let result = await store.startWebReview(payload: payload)

    if case .failed = result {
      #expect(store.failedFiles.count == 1)
    } else {
      Issue.record("expected .failed; got \(result)")
    }
  }
}
