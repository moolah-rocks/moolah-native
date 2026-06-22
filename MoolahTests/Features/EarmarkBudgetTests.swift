import Foundation
import Testing

@testable import Moolah

@Suite("EarmarkStore Budget")
@MainActor
struct EarmarkBudgetTests {
  private func makeStore(
    earmarks: [Earmark] = [],
    budgetItems: [UUID: [EarmarkBudgetItem]] = [:]
  ) async throws -> (EarmarkStore, CloudKitBackend) {
    let (backend, database) = try TestBackend.create()
    TestBackend.seed(earmarks: earmarks, in: database)
    for (earmarkId, items) in budgetItems {
      TestBackend.seedBudget(
        earmarkId: earmarkId, items: items, in: database)
    }
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    try await store.waitForFirstEmission()
    return (store, backend)
  }

  // MARK: - loadBudget

  @Test
  func testLoadBudgetPopulatesBudgetItems() async throws {
    let earmarkId = UUID()
    let catId = UUID()
    let items = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(
          quantity: Decimal(80000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    let (store, _) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday", instrument: .defaultTestInstrument)],
      budgetItems: [earmarkId: items]
    )

    await store.loadBudget(earmarkId: earmarkId)

    #expect(store.budgetItems.count == 1)
    #expect(store.budgetItems.first?.categoryId == catId)
    #expect(store.budgetItems.first?.amount.quantity == Decimal(80000) / 100)
  }

  @Test
  func testLoadBudgetHandlesError() async throws {
    let (backend, _) = try TestBackend.create()
    let store = EarmarkStore(
      repository: backend.earmarks, conversionService: FakeConversionService.fixedRates([:]),
      targetInstrument: .defaultTestInstrument)
    // Loading budget for nonexistent earmark still returns empty
    await store.loadBudget(earmarkId: UUID())
    #expect(store.budgetItems.isEmpty)
  }

  @Test
  func testLoadBudgetClearsPreviousItems() async throws {
    let earmark1Id = UUID()
    let earmark2Id = UUID()
    let cat1Id = UUID()
    let cat2Id = UUID()
    let (store, _) = try await makeStore(
      earmarks: [
        Earmark(id: earmark1Id, name: "Holiday", instrument: .defaultTestInstrument),
        Earmark(id: earmark2Id, name: "Car", instrument: .defaultTestInstrument),
      ],
      budgetItems: [
        earmark1Id: [
          EarmarkBudgetItem(
            categoryId: cat1Id,
            amount: InstrumentAmount(
              quantity: Decimal(80000) / 100, instrument: Instrument.defaultTestInstrument))
        ],
        earmark2Id: [
          EarmarkBudgetItem(
            categoryId: cat2Id,
            amount: InstrumentAmount(
              quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
        ],
      ]
    )

    await store.loadBudget(earmarkId: earmark1Id)
    #expect(store.budgetItems.count == 1)
    #expect(store.budgetItems.first?.categoryId == cat1Id)

    await store.loadBudget(earmarkId: earmark2Id)
    #expect(store.budgetItems.count == 1)
    #expect(store.budgetItems.first?.categoryId == cat2Id)
  }

  // MARK: - updateBudgetItem

  @Test
  func testUpdateBudgetItemModifiesExistingItem() async throws {
    let earmarkId = UUID()
    let catId = UUID()
    let items = [
      EarmarkBudgetItem(
        categoryId: catId,
        amount: InstrumentAmount(
          quantity: Decimal(80000) / 100, instrument: Instrument.defaultTestInstrument))
    ]
    let (store, backend) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday", instrument: .defaultTestInstrument)],
      budgetItems: [earmarkId: items]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.updateBudgetItem(
      earmarkId: earmarkId,
      categoryId: catId,
      amount: InstrumentAmount(
        quantity: Decimal(120000) / 100, instrument: Instrument.defaultTestInstrument)
    )

    #expect(store.budgetItems.first?.amount.quantity == Decimal(120000) / 100)

    // Verify repository state
    let persisted = try await backend.earmarks.fetchBudget(earmarkId: earmarkId)
    #expect(persisted.first?.amount.quantity == Decimal(120000) / 100)
  }

  // MARK: - addBudgetItem

  @Test
  func testAddBudgetItemAppendsToList() async throws {
    let earmarkId = UUID()
    let catId = UUID()
    let (store, _) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday", instrument: .defaultTestInstrument)]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.addBudgetItem(
      earmarkId: earmarkId,
      categoryId: catId,
      amount: InstrumentAmount(
        quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument)
    )

    #expect(store.budgetItems.count == 1)
    #expect(store.budgetItems.first?.categoryId == catId)
  }

  @Test
  func testAddBudgetItemCallsRepositoryWithFullList() async throws {
    let earmarkId = UUID()
    let cat1Id = UUID()
    let cat2Id = UUID()
    let (store, backend) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday", instrument: .defaultTestInstrument)],
      budgetItems: [
        earmarkId: [
          EarmarkBudgetItem(
            categoryId: cat1Id,
            amount: InstrumentAmount(
              quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
        ]
      ]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.addBudgetItem(
      earmarkId: earmarkId,
      categoryId: cat2Id,
      amount: InstrumentAmount(
        quantity: Decimal(30000) / 100, instrument: Instrument.defaultTestInstrument)
    )

    let persisted = try await backend.earmarks.fetchBudget(earmarkId: earmarkId)
    #expect(persisted.count == 2)
  }

  // MARK: - removeBudgetItem

  @Test
  func testRemoveBudgetItemRemovesFromList() async throws {
    let earmarkId = UUID()
    let catId = UUID()
    let (store, backend) = try await makeStore(
      earmarks: [Earmark(id: earmarkId, name: "Holiday", instrument: .defaultTestInstrument)],
      budgetItems: [
        earmarkId: [
          EarmarkBudgetItem(
            categoryId: catId,
            amount: InstrumentAmount(
              quantity: Decimal(50000) / 100, instrument: Instrument.defaultTestInstrument))
        ]
      ]
    )
    await store.loadBudget(earmarkId: earmarkId)

    await store.removeBudgetItem(earmarkId: earmarkId, categoryId: catId)

    #expect(store.budgetItems.isEmpty)
    let persisted = try await backend.earmarks.fetchBudget(earmarkId: earmarkId)
    #expect(persisted.isEmpty)
  }
}
