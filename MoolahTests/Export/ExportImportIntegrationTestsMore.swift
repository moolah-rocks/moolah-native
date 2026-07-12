import Foundation
import Testing

@testable import Moolah

@Suite("Export/Import File Integration")
@MainActor
struct ExportImportIntegrationTestsMore {

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

  @Test("importFromFile rejects unsupported version")
  func rejectsUnsupportedVersion() async throws {
    let exported = ExportedData(
      version: ExportFormatVersion.current,
      exportedAt: Date(),
      profileLabel: "Test",
      currencyCode: "AUD",
      financialYearStartMonth: 1,
      accounts: [],
      categories: [],
      earmarks: [],
      earmarkBudgets: [:],
      transactions: []
    )
    let tempURL = FileManager.default.temporaryDirectory.appending(
      path: "\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }
    let encoded = try ExportDocumentCodec().encode(exported)
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json["version"] = 99
    try JSONSerialization.data(withJSONObject: json).write(to: tempURL)

    let database = try ProfileDatabase.openInMemory()
    let coordinator = ExportCoordinator()

    await #expect(throws: ExportError.self) {
      _ = try await coordinator.importFromFile(url: tempURL, database: database)
    }
  }
}
