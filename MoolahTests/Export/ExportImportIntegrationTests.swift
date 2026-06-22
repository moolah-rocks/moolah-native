import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("Export/Import File Integration")
@MainActor
struct ExportImportIntegrationTests {

  private let instrument = Instrument.defaultTestInstrument

  /// Seeds a CloudKitBackend with realistic data for testing.
  private func makeSeededBackend() async throws -> CloudKitBackend {
    let (backend, _) = try TestBackend.create(instrument: instrument)

    let checking = try await backend.accounts.create(
      Account(
        name: "Checking", type: .bank,
        instrument: instrument
      ),
      openingBalance: InstrumentAmount(quantity: dec("500.00"), instrument: instrument)
    )

    let food = try await backend.categories.create(Category(name: "Food"))
    _ = try await backend.categories.create(Category(name: "Transport"))

    let holiday = try await backend.earmarks.create(
      Earmark(name: "Holiday", instrument: instrument)
    )
    let budgetAmount = InstrumentAmount(quantity: dec("30.00"), instrument: instrument)
    try await backend.earmarks.setBudget(
      earmarkId: holiday.id, categoryId: food.id, amount: budgetAmount)

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Employer",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: dec("500.00"), type: .income
          )
        ]
      )
    )

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Cafe",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: dec("-15.00"), type: .expense,
            categoryId: food.id, earmarkId: holiday.id
          )
        ]
      )
    )

    return backend
  }

  private func makeTempFileURL() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("moolah-test-\(UUID().uuidString).json")
  }

  /// Builds a `CloudKitBackend` over an existing GRDB `DatabaseQueue`
  /// for the post-import verification step. Centralised so each test
  /// isn't repeating the constructor boilerplate.
  private func makeCloudBackend(
    database: DatabaseQueue,
    registry: GRDBInstrumentRegistryRepository,
    label: String = "Test Profile"
  ) -> CloudKitBackend {
    // Instrument identity lives on the shared profile-index registry;
    // the verification backend reads through the same instance the
    // import registered into.
    CloudKitBackend(
      database: database,
      instrument: instrument,
      profileLabel: label,
      conversionService: FakeConversionService.fixedRates([:]),
      instrumentRegistry: registry
    )
  }

  @Test("export to JSON file and verify contents")
  func exportToFileAndVerify() async throws {
    let backend = try await makeSeededBackend()
    let tempURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let profile = Profile(
      label: "Test Profile",
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    )

    let coordinator = ExportCoordinator()
    try await coordinator.exportToFile(
      url: tempURL,
      backend: backend,
      profile: profile
    )

    // Verify file exists and is valid JSON
    let data = try Data(contentsOf: tempURL)
    let decoded = try JSONDecoder.exportDecoder.decode(ExportedData.self, from: data)

    #expect(decoded.profileLabel == "Test Profile")
    #expect(decoded.currencyCode == instrument.id)
    #expect(decoded.financialYearStartMonth == 7)
    #expect(decoded.accounts.count == 1)
    #expect(decoded.categories.count == 2)
    #expect(decoded.earmarks.count == 1)
    // 3 transactions: opening balance + income + expense
    #expect(decoded.transactions.count == 3)
    let decodedEarmark = try #require(decoded.earmarks.first)
    #expect(decoded.earmarkBudgets[decodedEarmark.id]?.count == 1)

    // Verify coordinator returned to idle state
    if case .idle = coordinator.state {
      // expected
    } else {
      Issue.record("Expected idle state, got \(coordinator.state)")
    }
  }

  @Test("import from JSON file into fresh container")
  func importFromFileRoundTrip() async throws {
    let backend = try await makeSeededBackend()
    let tempURL = makeTempFileURL()
    defer { try? FileManager.default.removeItem(at: tempURL) }

    // Export to file
    let profile = Profile(
      label: "Test Profile",
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    )

    let coordinator = ExportCoordinator()
    try await coordinator.exportToFile(
      url: tempURL,
      backend: backend,
      profile: profile
    )

    // Import into fresh database. Instrument identity lives on the
    // shared profile-index registry; the verification backend reads
    // through the same instance.
    let freshDatabase = try ProfileDatabase.openInMemory()
    let registry = try SharedRegistryTestSupport.makeSharedRegistry()
    let result = try await coordinator.importFromFile(
      url: tempURL,
      database: freshDatabase,
      instrumentRegistrar: registry
    )

    #expect(result.accountCount == 1)
    #expect(result.categoryCount == 2)
    #expect(result.earmarkCount == 1)
    // 3 transactions: opening balance + income + expense
    #expect(result.transactionCount == 3)
    #expect(result.budgetItemCount == 1)

    // Verify data is readable through CloudKit repositories
    let cloudBackend = makeCloudBackend(database: freshDatabase, registry: registry)

    let accounts = try await cloudBackend.accounts.fetchAll()
    #expect(accounts.count == 1)
    #expect(accounts.first?.name == "Checking")

    let categories = try await cloudBackend.categories.fetchAll()
    #expect(categories.count == 2)

    let earmarks = try await cloudBackend.earmarks.fetchAll()
    #expect(earmarks.count == 1)
    #expect(earmarks.first?.name == "Holiday")

    let earmark = try #require(earmarks.first)
    let budgetItems = try await cloudBackend.earmarks.fetchBudget(earmarkId: earmark.id)
    #expect(budgetItems.count == 1)
    #expect(budgetItems.first?.amount.quantity == dec("30.00"))

    let txnPage = try await cloudBackend.transactions.fetch(
      filter: TransactionFilter(), page: 0, pageSize: 100
    )
    // 3 transactions: opening balance + income + expense
    #expect(txnPage.transactions.count == 3)

    // Verify coordinator returned to idle state
    if case .idle = coordinator.state {
      // expected
    } else {
      Issue.record("Expected idle state, got \(coordinator.state)")
    }
  }
}
