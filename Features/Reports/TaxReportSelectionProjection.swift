import Foundation

@MainActor
struct TaxReportSelectionProjection {
  let effectiveOwnerId: UUID?
  let events: [CapitalGainEvent]
  let capitalGainsSummary: CapitalGainsSummary?
  let capitalGainsHasUnavailableData: Bool
  let capitalGainsUnavailableInstruments: [Instrument]
  let taxIncomeExpenseSummaries: [TaxIncomeExpenseSummary]
  let taxIncomeExpenseRollup: TaxIncomeExpenseSummary?
  let profitLoss: [InstrumentProfitLoss]
  let profitLossHasUnavailableData: Bool
  let profitLossUnavailableInstruments: [Instrument]
  let ownerScopeUsesTrustTreatment: Bool

  init(
    ownerSelection: TaxReportOwnerSelection,
    events: [CapitalGainEvent],
    allOwnerCapitalGainsSummary: CapitalGainsSummary?,
    capitalGainsHasUnavailableData: Bool,
    capitalGainsUnavailableInstruments: [Instrument],
    capitalGainsHasUnavailableDataByOwner: [UUID: Bool],
    ownerUnavailableCapitalGainsInstruments: [UUID: [Instrument]],
    taxIncomeExpenseSummaries: [TaxIncomeExpenseSummary],
    allOwnerTaxIncomeExpenseRollup: TaxIncomeExpenseSummary?,
    profitLoss: [InstrumentProfitLoss],
    profitLossHasUnavailableData: Bool,
    profitLossUnavailableInstruments: [Instrument],
    profitLossByOwner: [UUID: [InstrumentProfitLoss]],
    profitLossHasUnavailableDataByOwner: [UUID: Bool],
    profitLossUnavailableInstrumentsByOwner: [UUID: [Instrument]],
    defaultTaxOwnerId: UUID,
    profileInstrument: Instrument,
    taxOwnerKinds: [UUID: TaxOwnerKind]
  ) {
    let selectedOwnerId = ownerSelection.selectedOwnerId
    self.effectiveOwnerId = selectedOwnerId
    self.events = Self.selectedCapitalGainEvents(
      from: events,
      selectedOwnerId: selectedOwnerId,
      defaultTaxOwnerId: defaultTaxOwnerId)
    self.capitalGainsSummary = Self.selectedCapitalGainsSummary(
      from: events,
      selectedOwnerId: selectedOwnerId,
      defaultTaxOwnerId: defaultTaxOwnerId,
      allOwnerSummary: allOwnerCapitalGainsSummary)
    self.capitalGainsHasUnavailableData =
      selectedOwnerId.map { capitalGainsHasUnavailableDataByOwner[$0] ?? false }
      ?? capitalGainsHasUnavailableData
    self.capitalGainsUnavailableInstruments =
      selectedOwnerId.flatMap { ownerUnavailableCapitalGainsInstruments[$0] }
      ?? capitalGainsUnavailableInstruments
    self.taxIncomeExpenseSummaries = Self.selectedTaxIncomeExpenseSummaries(
      from: taxIncomeExpenseSummaries,
      selectedOwnerId: selectedOwnerId)
    self.taxIncomeExpenseRollup = Self.selectedTaxIncomeExpenseRollup(
      from: taxIncomeExpenseSummaries,
      selectedOwnerId: selectedOwnerId,
      allOwnerRollup: allOwnerTaxIncomeExpenseRollup,
      instrument: profileInstrument)
    self.profitLoss = selectedOwnerId.flatMap { profitLossByOwner[$0] } ?? profitLoss
    self.profitLossHasUnavailableData =
      selectedOwnerId.map { profitLossHasUnavailableDataByOwner[$0] ?? false }
      ?? profitLossHasUnavailableData
    self.profitLossUnavailableInstruments =
      selectedOwnerId.flatMap { profitLossUnavailableInstrumentsByOwner[$0] }
      ?? profitLossUnavailableInstruments
    self.ownerScopeUsesTrustTreatment = Self.ownerScopeUsesTrustTreatment(
      selectedOwnerId: selectedOwnerId,
      taxOwnerKinds: taxOwnerKinds)
  }

  private static func selectedCapitalGainEvents(
    from events: [CapitalGainEvent],
    selectedOwnerId: UUID?,
    defaultTaxOwnerId: UUID
  ) -> [CapitalGainEvent] {
    ReportingStore.selectedCapitalGainEvents(
      from: events,
      selectedOwnerId: selectedOwnerId,
      defaultTaxOwnerId: defaultTaxOwnerId)
  }

  private static func selectedCapitalGainsSummary(
    from events: [CapitalGainEvent],
    selectedOwnerId: UUID?,
    defaultTaxOwnerId: UUID,
    allOwnerSummary: CapitalGainsSummary?
  ) -> CapitalGainsSummary? {
    ReportingStore.selectedCapitalGainsSummary(
      from: events,
      selectedOwnerId: selectedOwnerId,
      defaultTaxOwnerId: defaultTaxOwnerId,
      allOwnerSummary: allOwnerSummary)
  }

  private static func selectedTaxIncomeExpenseSummaries(
    from summaries: [TaxIncomeExpenseSummary],
    selectedOwnerId: UUID?
  ) -> [TaxIncomeExpenseSummary] {
    guard let selectedOwnerId else { return summaries }
    return summaries.filter { $0.ownerId == selectedOwnerId }
  }

  private static func selectedTaxIncomeExpenseRollup(
    from summaries: [TaxIncomeExpenseSummary],
    selectedOwnerId: UUID?,
    allOwnerRollup: TaxIncomeExpenseSummary?,
    instrument: Instrument
  ) -> TaxIncomeExpenseSummary? {
    guard let selectedOwnerId else { return allOwnerRollup }
    return ReportingStore.taxIncomeExpenseRollup(
      from: summaries.filter { $0.ownerId == selectedOwnerId },
      instrument: instrument)
  }

  private static func ownerScopeUsesTrustTreatment(
    selectedOwnerId: UUID?,
    taxOwnerKinds: [UUID: TaxOwnerKind]
  ) -> Bool {
    if let selectedOwnerId {
      return taxOwnerKinds[selectedOwnerId] == .trust
    }
    return false
  }
}
