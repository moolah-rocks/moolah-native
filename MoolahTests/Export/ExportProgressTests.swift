import Foundation
import Testing

@testable import Moolah

/// Verifies `ExportCoordinator.exportToFile` emits progress stages
/// through its `progress:` callback so the UI can render a live indicator
/// (see issue #359). Kept in a dedicated suite so the main integration-test
/// file stays within the SwiftLint length thresholds.
@Suite("Export progress reporting")
@MainActor
struct ExportProgressTests {

  private let instrument = Instrument.defaultTestInstrument

  private func makeSeededBackend() async throws -> CloudKitBackend {
    let (backend, _) = try TestBackend.create(instrument: instrument)
    let opening = try #require(Decimal(string: "100.00"))
    let budgetAmount = try #require(Decimal(string: "10.00"))
    let legAmount = try #require(Decimal(string: "-10.00"))

    let checking = try await backend.accounts.create(
      Account(name: "Checking", type: .bank, instrument: instrument),
      openingBalance: InstrumentAmount(quantity: opening, instrument: instrument)
    )
    let food = try await backend.categories.create(Category(name: "Food"))
    let holiday = try await backend.earmarks.create(
      Earmark(name: "Holiday", instrument: instrument))
    try await backend.earmarks.setBudget(
      earmarkId: holiday.id,
      categoryId: food.id,
      amount: InstrumentAmount(quantity: budgetAmount, instrument: instrument))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(),
        payee: "Groceries",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: legAmount, type: .expense,
            categoryId: food.id, earmarkId: holiday.id)
        ]
      )
    )
    return backend
  }

  @Test("exportToFile reports every stage through the progress callback")
  func testProgressEmitsAllStages() async throws {
    let backend = try await makeSeededBackend()
    let tempURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("moolah-progress-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: tempURL) }

    let profile = Profile(
      label: "Progress Test",
      currencyCode: instrument.id,
      financialYearStartMonth: 7
    )

    final class StepCollector: @unchecked Sendable {
      var steps: [String] = []
    }
    let collector = StepCollector()
    let coordinator = ExportCoordinator()
    try await coordinator.exportToFile(
      url: tempURL,
      backend: backend,
      profile: profile,
      progress: { step in collector.steps.append(step) }
    )

    // Each stage the user can observe must show up at least once. The MVP
    // progress sheet renders a live stage label, so a missing stage means
    // the UI silently jumps past it — a visible UX regression.
    let expected: Set<String> = [
      "starting", "accounts", "categories", "earmarks",
      "transactions", "encoding", "writing",
    ]
    #expect(
      expected.isSubset(of: Set(collector.steps)),
      "missing stages: \(expected.subtracting(Set(collector.steps)))")
    #expect(!collector.steps.contains("investment values"))

    // Order invariant: `starting` first, then downloads, then encoding, then writing.
    #expect(collector.steps.first == "starting")
    let transactionsIdx = collector.steps.firstIndex(of: "transactions")
    let encodingIdx = collector.steps.firstIndex(of: "encoding")
    let writingIdx = collector.steps.firstIndex(of: "writing")
    if let transactionsIdx, let encodingIdx, let writingIdx {
      #expect(transactionsIdx < encodingIdx)
      #expect(encodingIdx < writingIdx)
    } else {
      Issue.record("Missing ordering anchors in \(collector.steps)")
    }
  }
}
