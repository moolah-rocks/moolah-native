import Foundation
import Testing

@testable import Moolah

@MainActor
@Suite("Tax income expense transaction drill-down")
struct TaxIncomeExpenseDetailStoreTests {
  @Test("split owner contributions replace transaction amounts and preserve the report total")
  func splitOwnerContributionsPreserveReportTotal() async throws {
    let ownerId = UUID()
    let categoryId = UUID()
    let older = transaction(payee: "Older", dateOffset: -1)
    let newer = transaction(payee: "Newer", dateOffset: 0)
    let store = TaxIncomeExpenseDetailStore(
      profileInstrument: .AUD,
      showsOwnerShareIndicators: true
    ) {
      [
        detailRow(
          transactionId: older.id,
          ownerId: ownerId,
          categoryId: categoryId,
          amount: 40,
          isSplitAcrossTaxOwners: true),
        detailRow(
          transactionId: newer.id,
          ownerId: ownerId,
          categoryId: categoryId,
          amount: 60,
          isSplitAcrossTaxOwners: true),
      ]
    }

    await store.load()
    let presentation = store.presentation(for: [entry(newer), entry(older)])

    #expect(presentation.displayAmounts(for: newer.id).first?.quantity == 60)
    #expect(presentation.displayAmounts(for: older.id).first?.quantity == 40)
    #expect(presentation.balance(for: newer.id)?.quantity == 100)
    #expect(presentation.balance(for: older.id)?.quantity == 40)
    #expect(presentation.showsOwnerShareIndicator(for: newer.id))
    #expect(presentation.showsOwnerShareIndicator(for: older.id))
  }

  @Test("the newest contributor exposes the report total while preserving older balances")
  func newestContributorExposesReportTotal() async throws {
    let newer = transaction(payee: "Newer", dateOffset: 0)
    let olderVisible = transaction(payee: "Visible", dateOffset: -1)
    let store = TaxIncomeExpenseDetailStore(profileInstrument: .AUD) {
      [
        self.detailRow(
          transactionId: newer.id,
          ownerId: UUID(),
          categoryId: UUID(),
          amount: 60),
        self.detailRow(
          transactionId: olderVisible.id,
          ownerId: UUID(),
          categoryId: UUID(),
          amount: 40),
      ]
    }

    await store.load()
    let presentation = store.presentation(
      for: [entry(newer), entry(olderVisible)])

    #expect(presentation.balance(for: newer.id)?.quantity == 100)
    #expect(presentation.balance(for: olderVisible.id)?.quantity == 40)
  }

  @Test("an all-owner total does not label the complete amount as an owner share")
  func allOwnerTotalSuppressesOwnerShareIndicator() async throws {
    let transaction = transaction(payee: "Joint income", dateOffset: 0)
    let store = TaxIncomeExpenseDetailStore(profileInstrument: .AUD) {
      [
        detailRow(
          transactionId: transaction.id,
          ownerId: UUID(),
          categoryId: UUID(),
          amount: 50,
          isSplitAcrossTaxOwners: true),
        detailRow(
          transactionId: transaction.id,
          ownerId: UUID(),
          categoryId: UUID(),
          amount: 50,
          isSplitAcrossTaxOwners: true),
      ]
    }

    await store.load()
    let presentation = store.presentation(for: [entry(transaction)])

    #expect(presentation.displayAmounts(for: transaction.id).first?.quantity == 100)
    #expect(presentation.showsOwnerShareIndicator(for: transaction.id) == false)
  }

  @Test("multiple contribution rows for one transaction are combined")
  func multipleContributionsForOneTransactionAreCombined() async throws {
    let transaction = transaction(payee: "Distribution", dateOffset: 0)
    let store = TaxIncomeExpenseDetailStore(profileInstrument: .AUD) {
      [
        detailRow(
          transactionId: transaction.id,
          ownerId: UUID(),
          categoryId: UUID(),
          amount: 25),
        detailRow(
          transactionId: transaction.id,
          ownerId: UUID(),
          categoryId: UUID(),
          amount: 35),
      ]
    }

    await store.load()
    let presentation = store.presentation(for: [entry(transaction)])

    #expect(presentation.displayAmounts(for: transaction.id).first?.quantity == 60)
    #expect(presentation.balance(for: transaction.id)?.quantity == 60)
  }

  @Test("an unavailable contribution hides its transaction amount and every dependent balance")
  func unavailableContributionHidesDependentBalances() async throws {
    let healthy = transaction(payee: "Healthy", dateOffset: 0)
    let unavailable = transaction(payee: "Unavailable", dateOffset: -1)
    let store = TaxIncomeExpenseDetailStore(profileInstrument: .AUD) {
      [
        detailRow(
          transactionId: healthy.id,
          ownerId: UUID(),
          categoryId: UUID(),
          amount: 80),
        TaxIncomeExpenseDetailRow(
          transactionId: unavailable.id,
          ownerId: UUID(),
          categoryId: UUID(),
          instrument: .USD,
          day: Date(),
          amount: nil,
          hasUnavailableData: true),
      ]
    }

    await store.load()
    let presentation = store.presentation(for: [entry(healthy), entry(unavailable)])

    #expect(presentation.displayAmounts(for: healthy.id).first?.quantity == 80)
    #expect(presentation.displayAmounts(for: unavailable.id).isEmpty)
    #expect(presentation.balance(for: healthy.id) == nil)
    #expect(presentation.balance(for: unavailable.id) == nil)
    #expect(store.hasUnavailableData)
  }

  @Test("an unavailable newer contribution preserves an independent older balance")
  func unavailableNewerContributionPreservesOlderBalance() async throws {
    let newer = transaction(payee: "Unavailable", dateOffset: 0)
    let older = transaction(payee: "Healthy", dateOffset: -1)
    let store = TaxIncomeExpenseDetailStore(profileInstrument: .AUD) {
      [
        TaxIncomeExpenseDetailRow(
          transactionId: newer.id,
          ownerId: UUID(),
          categoryId: UUID(),
          instrument: .USD,
          day: Date(),
          amount: nil,
          hasUnavailableData: true),
        detailRow(
          transactionId: older.id,
          ownerId: UUID(),
          categoryId: UUID(),
          amount: 40),
      ]
    }

    await store.load()
    let presentation = store.presentation(for: [entry(newer), entry(older)])

    #expect(presentation.balance(for: newer.id) == nil)
    #expect(presentation.balance(for: older.id)?.quantity == 40)
  }

  @Test("an older load cannot replace newer tax amounts")
  func olderLoadCannotReplaceNewerAmounts() async throws {
    let transaction = transaction(payee: "Edited", dateOffset: 0)
    let loader = ControlledTaxDetailLoader()
    let store = TaxIncomeExpenseDetailStore(profileInstrument: .AUD) {
      await loader.load()
    }

    let olderLoad = Task { await store.load() }
    await loader.waitForRequestCount(1)
    let newerLoad = Task { await store.load() }
    await loader.waitForRequestCount(2)

    await loader.resume(
      request: 1,
      with: [
        detailRow(transactionId: transaction.id, ownerId: UUID(), categoryId: UUID(), amount: 75)
      ])
    await newerLoad.value
    await loader.resume(
      request: 0,
      with: [
        detailRow(transactionId: transaction.id, ownerId: UUID(), categoryId: UUID(), amount: 25)
      ])
    await olderLoad.value

    let presentation = store.presentation(for: [entry(transaction)])
    #expect(presentation.displayAmounts(for: transaction.id).first?.quantity == 75)
  }

  @Test("a failed refresh preserves values and surfaces a retryable warning")
  func failedRefreshPreservesValuesAndSurfacesWarning() async throws {
    let transaction = transaction(payee: "Edited", dateOffset: 0)
    var shouldFail = false
    let store = TaxIncomeExpenseDetailStore(profileInstrument: .AUD) {
      if shouldFail { throw TaxDetailTestError.refreshFailed }
      return [
        detailRow(
          transactionId: transaction.id,
          ownerId: UUID(),
          categoryId: UUID(),
          amount: 75)
      ]
    }

    await store.load()
    shouldFail = true
    await store.load()

    let presentation = store.presentation(for: [entry(transaction)])
    #expect(presentation.displayAmounts(for: transaction.id).first?.quantity == 75)
    #expect(store.errorMessage == nil)
    #expect(store.refreshErrorMessage == "Tax amounts could not be refreshed.")
  }

  @Test("cancelling the current initial load clears the blocking state")
  func cancelledInitialLoadClearsBlockingState() async throws {
    let store = TaxIncomeExpenseDetailStore(profileInstrument: .AUD) {
      try await Task.sleep(for: .seconds(60))
      return []
    }

    let load = Task { await store.load() }
    await Task.yield()
    load.cancel()
    await load.value

    #expect(store.isLoading == false)
  }
}

private enum TaxDetailTestError: Error {
  case refreshFailed
}

private actor ControlledTaxDetailLoader {
  private var continuations: [CheckedContinuation<[TaxIncomeExpenseDetailRow], Never>] = []

  func load() async -> [TaxIncomeExpenseDetailRow] {
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }

  func waitForRequestCount(_ count: Int) async {
    while continuations.count < count {
      await Task.yield()
    }
  }

  func resume(request: Int, with rows: [TaxIncomeExpenseDetailRow]) {
    continuations[request].resume(returning: rows)
  }
}

extension TaxIncomeExpenseDetailStoreTests {
  private func detailRow(
    transactionId: UUID,
    ownerId: UUID,
    categoryId: UUID,
    amount: Decimal,
    isSplitAcrossTaxOwners: Bool = false
  ) -> TaxIncomeExpenseDetailRow {
    TaxIncomeExpenseDetailRow(
      transactionId: transactionId,
      ownerId: ownerId,
      categoryId: categoryId,
      instrument: .AUD,
      day: Date(),
      amount: InstrumentAmount(quantity: amount, instrument: .AUD),
      isSplitAcrossTaxOwners: isSplitAcrossTaxOwners)
  }

  private func transaction(payee: String, dateOffset: TimeInterval) -> Transaction {
    Transaction(
      date: Date(timeIntervalSinceReferenceDate: 1_000 + dateOffset),
      payee: payee,
      legs: [
        TransactionLeg(
          accountId: UUID(),
          instrument: .AUD,
          quantity: 1,
          type: .income)
      ])
  }

  private func entry(_ transaction: Transaction) -> TransactionWithBalance {
    TransactionWithBalance(
      transaction: transaction,
      convertedLegs: [],
      displayAmounts: [],
      displayAmount: nil,
      balance: nil)
  }
}
