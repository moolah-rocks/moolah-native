import Foundation
import Testing
import os

@testable import Moolah

/// Thread-safe progress step collector for testing.
private final class ProgressTracker: Sendable {
  private let _steps = OSAllocatedUnfairLock(initialState: [String]())

  func record(_ step: String) {
    _steps.withLock { $0.append(step) }
  }

  var steps: [String] {
    _steps.withLock { $0 }
  }
}

@Suite("DataExporter")
struct DataExporterTests {

  private let instrument = Instrument.defaultTestInstrument
  private let defaultTaxOwnerId = UUID()

  private func makeBackendWithData() async throws -> CloudKitBackend {
    let (backend, _) = try TestBackend.create(instrument: instrument)
    try await seedAccountsAndEarmarks(backend: backend)
    try await seedBackendTransactions(backend: backend)
    return backend
  }

  private func seedAccountsAndEarmarks(backend: CloudKitBackend) async throws {
    _ = try await backend.accounts.create(
      Account(name: "Checking", type: .bank, instrument: instrument), openingBalance: nil)
    _ = try await backend.accounts.create(
      Account(name: "Savings", type: .bank, instrument: instrument), openingBalance: nil)
    _ = try await backend.accounts.create(
      Account(name: "Portfolio", type: .investment, instrument: instrument), openingBalance: nil)

    let food = try await backend.categories.create(Category(name: "Food"))
    _ = try await backend.categories.create(Category(name: "Groceries", parentId: food.id))

    let holiday = try await backend.earmarks.create(
      Earmark(name: "Holiday", instrument: instrument))
    let budgetAmount = InstrumentAmount(quantity: dec("50.00"), instrument: instrument)
    try await backend.earmarks.setBudget(
      earmarkId: holiday.id, categoryId: food.id, amount: budgetAmount)
  }

  private func seedBackendTransactions(backend: CloudKitBackend) async throws {
    let accounts = try await backend.accounts.fetchAll()
    let checking = try #require(accounts.first { $0.name == "Checking" })
    let categories = try await backend.categories.fetchAll()
    let food = try #require(categories.first { $0.name == "Food" && $0.parentId == nil })
    let earmarks = try await backend.earmarks.fetchAll()
    let holiday = try #require(earmarks.first { $0.name == "Holiday" })

    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Employer",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: dec("1000.00"), type: .income)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Shop",
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: dec("-25.00"), type: .expense,
            categoryId: food.id, earmarkId: holiday.id)
        ]))
    _ = try await backend.transactions.create(
      Transaction(
        date: Date(), payee: "Streaming",
        recurPeriod: .month, recurEvery: 1,
        legs: [
          TransactionLeg(
            accountId: checking.id, instrument: instrument,
            quantity: dec("-10.00"), type: .expense)
        ]))
  }

  @Test("exports all data from InMemory backend")
  func exportAll() async throws {
    let backend = try await makeBackendWithData()
    let exporter = DataExporter(backend: backend)

    let progressSteps = ProgressTracker()
    let data = try await exporter.export(
      profileLabel: "Test",
      currencyCode: instrument.id,
      financialYearStartMonth: 7,
      defaultTaxOwnerId: defaultTaxOwnerId
    ) { progress in
      if case .downloading(let step) = progress {
        progressSteps.record(step)
      }
    }

    #expect(data.accounts.count == 3)
    #expect(data.categories.count == 2)
    #expect(data.earmarks.count == 1)
    #expect(data.transactions.count == 3)

    // Verify progress was reported
    let steps = progressSteps.steps
    #expect(steps.contains("accounts"))
    #expect(steps.contains("categories"))
    #expect(steps.contains("transactions"))
  }

  @Test("exports earmark budgets keyed by earmark ID")
  func exportBudgets() async throws {
    let backend = try await makeBackendWithData()
    let exporter = DataExporter(backend: backend)

    let data = try await exporter.export(
      profileLabel: "Test",
      currencyCode: instrument.id,
      financialYearStartMonth: 7,
      defaultTaxOwnerId: defaultTaxOwnerId
    ) { _ in }

    let earmark = try #require(data.earmarks.first)
    let budgetItems = try #require(data.earmarkBudgets[earmark.id])
    #expect(budgetItems.count == 1)
    let firstBudgetItem = try #require(budgetItems.first)
    #expect(firstBudgetItem.amount.quantity == dec("50.00"))
  }

  @Test("exports empty data from empty backend")
  func exportEmpty() async throws {
    let (backend, _) = try TestBackend.create()
    let exporter = DataExporter(backend: backend)

    let data = try await exporter.export(
      profileLabel: "Test",
      currencyCode: instrument.id,
      financialYearStartMonth: 7,
      defaultTaxOwnerId: defaultTaxOwnerId
    ) { _ in }

    #expect(data.accounts.isEmpty)
    #expect(data.categories.isEmpty)
    #expect(data.earmarks.isEmpty)
    #expect(data.transactions.isEmpty)
  }

  @Test("includes scheduled transactions in export")
  func exportIncludesScheduled() async throws {
    let backend = try await makeBackendWithData()
    let exporter = DataExporter(backend: backend)

    let data = try await exporter.export(
      profileLabel: "Test",
      currencyCode: instrument.id,
      financialYearStartMonth: 7,
      defaultTaxOwnerId: defaultTaxOwnerId
    ) { _ in }

    let scheduled = data.transactions.filter { $0.isScheduled }
    #expect(scheduled.count == 1)
    #expect(scheduled.first?.recurPeriod == .month)
  }
}
