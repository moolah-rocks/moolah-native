import Foundation
import OSLog

@MainActor
@Observable
final class TaxIncomeExpenseDetailStore {
  private let profileInstrument: Instrument
  private let showsOwnerShareIndicators: Bool
  private let loadRows: () async throws -> [TaxIncomeExpenseDetailRow]
  private let logger = Logger(
    subsystem: "com.moolah.app", category: "TaxIncomeExpenseDetailStore")

  private var amountsByTransactionId: [UUID: InstrumentAmount] = [:]
  private var unavailableTransactionIds: Set<UUID> = []
  private var ownerShareTransactionIds: Set<UUID> = []
  private var loadGeneration = 0
  private(set) var hasLoadedRows = false
  private(set) var isLoading = true
  private(set) var errorMessage: String?
  private(set) var refreshErrorMessage: String?

  var hasUnavailableData: Bool { !unavailableTransactionIds.isEmpty }

  init(
    profileInstrument: Instrument,
    showsOwnerShareIndicators: Bool = false,
    loadRows: @escaping () async throws -> [TaxIncomeExpenseDetailRow]
  ) {
    self.profileInstrument = profileInstrument
    self.showsOwnerShareIndicators = showsOwnerShareIndicators
    self.loadRows = loadRows
  }

  func load() async {
    loadGeneration += 1
    let generation = loadGeneration
    defer {
      if generation == loadGeneration {
        isLoading = false
      }
    }
    if !hasLoadedRows {
      isLoading = true
      errorMessage = nil
    }
    refreshErrorMessage = nil
    do {
      let rows = try await loadRows()
      guard generation == loadGeneration, !Task.isCancelled else { return }
      apply(rows)
      hasLoadedRows = true
      errorMessage = nil
      refreshErrorMessage = nil
    } catch is CancellationError {
      return
    } catch {
      guard generation == loadGeneration, !Task.isCancelled else { return }
      logger.error(
        "Could not load tax transaction detail rows: \(error.localizedDescription, privacy: .public)"
      )
      if !hasLoadedRows {
        errorMessage = "The transactions behind this total could not be loaded."
        amountsByTransactionId = [:]
        unavailableTransactionIds = []
        ownerShareTransactionIds = []
      } else {
        refreshErrorMessage = "Tax amounts could not be refreshed."
      }
    }
  }

  func presentation(
    for transactions: [TransactionWithBalance],
    style: TransactionListAmountStyle = .standard
  ) -> TransactionListAmountPresentation {
    let displayAmounts = Dictionary(
      uniqueKeysWithValues: transactions.map { entry in
        let amount = amountsByTransactionId[entry.id]
        return (entry.id, amount.map { [$0] } ?? [])
      })
    let balances = transactionBalances(for: transactions)
    return TransactionListAmountPresentation(
      displayAmountsByTransactionId: displayAmounts,
      balancesByTransactionId: balances,
      ownerShareTransactionIds: ownerShareTransactionIds,
      style: style)
  }
}

extension TaxIncomeExpenseDetailStore {
  private func apply(_ rows: [TaxIncomeExpenseDetailRow]) {
    var amounts: [UUID: InstrumentAmount] = [:]
    var unavailable: Set<UUID> = []
    var ownerShares: Set<UUID> = []
    let zero = InstrumentAmount.zero(instrument: profileInstrument)
    for row in rows {
      if showsOwnerShareIndicators, row.isSplitAcrossTaxOwners {
        ownerShares.insert(row.transactionId)
      }
      guard !row.hasUnavailableData, let amount = row.amount,
        amount.instrument == profileInstrument
      else {
        unavailable.insert(row.transactionId)
        continue
      }
      amounts[row.transactionId, default: zero] += amount
    }
    for transactionId in unavailable {
      amounts[transactionId] = nil
    }
    amountsByTransactionId = amounts
    unavailableTransactionIds = unavailable
    ownerShareTransactionIds = ownerShares
  }

  private func transactionBalances(
    for transactions: [TransactionWithBalance]
  ) -> [UUID: InstrumentAmount] {
    let loadedTransactionIds = Set(transactions.map(\.id))
    let knownTransactionIds = Set(amountsByTransactionId.keys).union(unavailableTransactionIds)
    guard loadedTransactionIds.isSubset(of: knownTransactionIds) else { return [:] }

    let zero = InstrumentAmount.zero(instrument: profileInstrument)
    let unloadedTransactionIds = knownTransactionIds.subtracting(loadedTransactionIds)
    var runningBalance: InstrumentAmount? =
      unloadedTransactionIds.isDisjoint(with: unavailableTransactionIds)
      ? unloadedTransactionIds.reduce(zero) { balance, transactionId in
        balance + (amountsByTransactionId[transactionId] ?? zero)
      }
      : nil
    var balances: [UUID: InstrumentAmount] = [:]
    for transaction in transactions.reversed() {
      guard let balance = runningBalance,
        !unavailableTransactionIds.contains(transaction.id),
        let amount = amountsByTransactionId[transaction.id]
      else {
        runningBalance = nil
        continue
      }
      let updatedBalance = balance + amount
      balances[transaction.id] = updatedBalance
      runningBalance = updatedBalance
    }
    return balances
  }
}
