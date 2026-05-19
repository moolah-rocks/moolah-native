import Foundation
import Testing

@testable import Moolah

@Suite("ImportStore")
@MainActor
struct ImportStoreTestsExtra {

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

  @Test("rules engine applies payee and category during ingest")
  func rulesApplyPayeeAndCategory() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let category = Moolah.Category(id: UUID(), name: "Dining", parentId: nil)
    _ = try await backend.categories.create(category)
    let rule = ImportRule(
      name: "Coffee → Dining",
      position: 0,
      conditions: [.descriptionContains(["COFFEE"])],
      actions: [.setPayee("Café"), .setCategory(category.id)])
    _ = try await backend.importRules.create(rule)

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: accountId), page: 0, pageSize: 50)
    let coffee = try #require(
      page.transactions.first(where: {
        $0.importOrigin?.singleOrigin?.rawDescription == "COFFEE HUT SYDNEY"
      }))
    #expect(coffee.payee == "Café")
    #expect(coffee.legs[0].categoryId == category.id)
  }

  @Test("markAsTransfer rewrites rule-matched rows into two-leg transfers")
  func rulesMarkAsTransfer() async throws {
    let (backend, _) = try TestBackend.create()
    let sourceAccount = UUID()
    let transferTarget = UUID()
    try await seedAccount(backend, id: sourceAccount, name: "Source")
    try await seedAccount(backend, id: transferTarget, name: "Target")
    _ = try await seedProfile(backend, accountId: sourceAccount)
    let rule = ImportRule(
      name: "CBA transfer",
      position: 0,
      conditions: [.descriptionContains(["COFFEE"])],
      actions: [.markAsTransfer(toAccountId: transferTarget)])
    _ = try await backend.importRules.create(rule)

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))

    // The coffee row became a two-leg transfer, source→target.
    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: sourceAccount), page: 0, pageSize: 50)
    let coffee = try #require(
      page.transactions.first(where: {
        $0.importOrigin?.singleOrigin?.rawDescription == "COFFEE HUT SYDNEY"
      }))
    #expect(coffee.legs.count == 2)
    #expect(coffee.legs.allSatisfy { $0.type == .transfer })
    let sum = coffee.legs.reduce(Decimal(0)) { $0 + $1.quantity }
    #expect(sum == 0)
  }

  // MARK: - Instrument correctness (Rule 11 / Rule 11a)

  @Test("placeholder cash legs are rewritten to the non-AUD target account's instrument")
  func placeholderLegRewriteNonAUD() async throws {
    let (backend, _) = try TestBackend.create()
    let eurAccount = UUID()
    let eur = Instrument.fiat(code: "EUR")
    try await seedAccount(backend, id: eurAccount, name: "EUR Bank", instrument: eur)
    _ = try await seedProfile(backend, accountId: eurAccount)

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: eurAccount), page: 0, pageSize: 50)
    #expect(!page.transactions.isEmpty)
    // Every persisted leg must carry the target account's instrument —
    // the parser's placeholder .AUD must never survive into persistence.
    for transaction in page.transactions {
      for leg in transaction.legs {
        #expect(leg.instrument == eur)
      }
    }
  }

  @Test("markAsTransfer across instruments stamps each leg with its own account's instrument")
  func markAsTransferCrossInstrument() async throws {
    let (backend, _) = try TestBackend.create()
    let audSource = UUID()
    let usdTarget = UUID()
    try await seedAccount(backend, id: audSource, name: "AUD Source", instrument: .AUD)
    try await seedAccount(backend, id: usdTarget, name: "USD Target", instrument: .USD)
    _ = try await seedProfile(backend, accountId: audSource)
    let rule = ImportRule(
      name: "Cross-currency transfer",
      position: 0,
      conditions: [.descriptionContains(["COFFEE"])],
      actions: [.markAsTransfer(toAccountId: usdTarget)])
    _ = try await backend.importRules.create(rule)

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    _ = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))

    let page = try await backend.transactions.fetch(
      filter: TransactionFilter(accountId: audSource), page: 0, pageSize: 50)
    let coffee = try #require(
      page.transactions.first(where: {
        $0.importOrigin?.singleOrigin?.rawDescription == "COFFEE HUT SYDNEY"
      }))
    #expect(coffee.legs.count == 2)
    let sourceLeg = try #require(coffee.legs.first(where: { $0.accountId == audSource }))
    let destinationLeg = try #require(coffee.legs.first(where: { $0.accountId == usdTarget }))
    #expect(sourceLeg.instrument == .AUD)
    // Rule 11a: destination leg carries the destination account's
    // instrument, NOT the source's. Without this fix, both legs would
    // be .AUD and the USD-target account would silently gain an AUD leg.
    #expect(destinationLeg.instrument == .USD)
  }

  @Test("skip rule drops rows from persistence")
  func rulesSkipDropsRows() async throws {
    let (backend, _) = try TestBackend.create()
    let accountId = UUID()
    try await seedAccount(backend, id: accountId, name: "Cash")
    _ = try await seedProfile(backend, accountId: accountId)
    let rule = ImportRule(
      name: "Skip coffee",
      position: 0,
      conditions: [.descriptionContains(["COFFEE"])],
      actions: [.skip])
    _ = try await backend.importRules.create(rule)

    let (store, dir) = try makeStore(backend: backend)
    defer { try? FileManager.default.removeItem(at: dir) }
    let data = try cbaFixtureBytes()
    let result = await store.ingest(
      data: data,
      source: .pickedFile(url: URL(fileURLWithPath: "/tmp/cba.csv"), securityScoped: false))
    if case .imported(_, let imported, _) = result {
      // 4 non-skip candidates; 1 coffee row dropped by rule → 3 persisted.
      #expect(imported.count == 3)
      #expect(
        imported.allSatisfy { $0.importOrigin?.singleOrigin?.rawDescription != "COFFEE HUT SYDNEY" }
      )
    } else {
      Issue.record("expected .imported")
    }
  }

  // MARK: - Error paths
}
