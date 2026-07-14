extension TransactionListView {
  struct PresentedValues {
    let displayAmounts: [InstrumentAmount]
    let balance: InstrumentAmount?
    let amountStyle: TransactionListAmountStyle
    let showsOwnerShareIndicator: Bool
  }

  func presentedValues(
    for entry: TransactionWithBalance
  ) -> PresentedValues {
    guard let amountPresentation else {
      return PresentedValues(
        displayAmounts: entry.displayAmounts,
        balance: entry.balance,
        amountStyle: .standard,
        showsOwnerShareIndicator: false)
    }
    return PresentedValues(
      displayAmounts: amountPresentation.displayAmounts(for: entry.transaction.id),
      balance: amountPresentation.balance(for: entry.transaction.id),
      amountStyle: amountPresentation.style,
      showsOwnerShareIndicator: amountPresentation.showsOwnerShareIndicator(
        for: entry.transaction.id))
  }
}
