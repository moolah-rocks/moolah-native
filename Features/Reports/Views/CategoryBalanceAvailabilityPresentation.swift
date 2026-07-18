enum CategoryBalanceAvailabilityPresentation {
  static func displayedAmount(
    _ amount: InstrumentAmount, hasUnavailableData: Bool
  ) -> InstrumentAmount? {
    hasUnavailableData ? nil : amount
  }
}
