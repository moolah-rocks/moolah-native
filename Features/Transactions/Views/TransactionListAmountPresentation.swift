import Foundation

enum TransactionListAmountStyle: Sendable, Equatable {
  case standard
  case deduction
}

struct TransactionListAmountPresentation: Sendable, Equatable {
  private let displayAmountsByTransactionId: [UUID: [InstrumentAmount]]
  private let balancesByTransactionId: [UUID: InstrumentAmount]
  private let ownerShareTransactionIds: Set<UUID>
  let style: TransactionListAmountStyle

  init(
    displayAmountsByTransactionId: [UUID: [InstrumentAmount]],
    balancesByTransactionId: [UUID: InstrumentAmount],
    ownerShareTransactionIds: Set<UUID> = [],
    style: TransactionListAmountStyle = .standard
  ) {
    self.displayAmountsByTransactionId = displayAmountsByTransactionId
    self.balancesByTransactionId = balancesByTransactionId
    self.ownerShareTransactionIds = ownerShareTransactionIds
    self.style = style
  }

  func displayAmounts(for transactionId: UUID) -> [InstrumentAmount] {
    displayAmountsByTransactionId[transactionId] ?? []
  }

  func balance(for transactionId: UUID) -> InstrumentAmount? {
    balancesByTransactionId[transactionId]
  }

  func showsOwnerShareIndicator(for transactionId: UUID) -> Bool {
    ownerShareTransactionIds.contains(transactionId)
  }
}
