import Foundation
import Testing

@testable import Moolah

@Suite("Tax report owner selection")
struct TaxReportOwnerSelectionTests {
  @Test
  func pickerIsHiddenForSingleOwnerProfiles() {
    let ownerId = UUID()

    let options = TaxReportOwnerSelection.options(for: [ownerId: "Alex"])

    #expect(options.isPickerVisible == false)
    #expect(options.choices.map(\.id) == [nil])
  }

  @Test
  func pickerDefaultsToAllOwnersForMultiOwnerProfiles() {
    let ownerA = UUID()
    let ownerB = UUID()

    let options = TaxReportOwnerSelection.options(
      for: [ownerB: "Sam", ownerA: "Alex"], selectedOwnerId: nil)

    #expect(options.isPickerVisible)
    #expect(options.selectedOwnerId == nil)
    #expect(options.choices.map(\.label) == ["All owners", "Alex", "Sam"])
  }

  @Test
  func pickerPreservesIndividualOwnerSelection() {
    let ownerA = UUID()
    let ownerB = UUID()

    let options = TaxReportOwnerSelection.options(
      for: [ownerA: "Alex", ownerB: "Sam"], selectedOwnerId: ownerB)

    #expect(options.isPickerVisible)
    #expect(options.selectedOwnerId == ownerB)
  }

  @Test
  func pickerResetsMissingSelectionToAllOwners() {
    let ownerA = UUID()

    let options = TaxReportOwnerSelection.options(
      for: [ownerA: "Alex", UUID(): "Sam"], selectedOwnerId: UUID())

    #expect(options.selectedOwnerId == nil)
  }

  @Test
  @MainActor
  func pickerBindingReadsNormalizedSelection() {
    let owner = UUID()
    let view = taxReportView(
      defaultTaxOwnerId: owner,
      taxOwnerNames: [owner: "Alex", UUID(): "Sam"],
      selectedOwnerId: UUID())

    #expect(view.ownerPickerSelection.wrappedValue == nil)
  }

  @Test
  @MainActor
  func defaultOwnerSelectionIncludesUnassignedCapitalGainEvents() {
    let defaultOwner = UUID()
    let otherOwner = UUID()
    let saleId = UUID()
    let event = CapitalGainEvent(
      sourceTransactionId: saleId,
      instrument: .AUD,
      sellDate: Date(timeIntervalSince1970: 0),
      acquiredDate: Date(timeIntervalSince1970: -86_400),
      quantity: 1,
      costBasis: 1,
      proceeds: 2,
      holdingDays: 1,
      taxOwnerId: nil)
    let view = taxReportView(
      summary: ReportingStore.capitalGainsSummary(from: [event]),
      events: [event],
      defaultTaxOwnerId: defaultOwner,
      taxOwnerNames: [defaultOwner: "Alex", otherOwner: "Sam"],
      selectedOwnerId: defaultOwner)

    #expect(view.selectedReport.events.map(\.sourceTransactionId) == [saleId])
    #expect(view.selectedReport.capitalGainsSummary?.eventCount == 1)
  }

  @Test
  @MainActor
  func allOwnerTrustTreatmentRequiresTrustOwnerActivity() {
    let owner = UUID()
    let inactiveTrust = UUID()
    let view = TaxReportView(
      financialYear: 2027,
      holdingsDate: Date(timeIntervalSince1970: 0),
      profileInstrument: .AUD,
      summary: nil,
      events: [
        CapitalGainEvent(
          sourceTransactionId: UUID(),
          instrument: .AUD,
          sellDate: Date(timeIntervalSince1970: 0),
          acquiredDate: Date(timeIntervalSince1970: -86_400),
          quantity: 1,
          costBasis: 1,
          proceeds: 2,
          holdingDays: 1,
          taxOwnerId: owner)
      ],
      capitalGainsHasUnavailableData: false,
      capitalGainsUnavailableInstruments: [],
      capitalGainsHasUnavailableDataByOwner: [:],
      ownerUnavailableCapitalGainsInstruments: [:],
      taxIncomeExpenseSummaries: [],
      taxIncomeExpenseRollup: nil,
      defaultTaxOwnerId: owner,
      taxIncomeExpenseDateInterval: nil,
      taxIncomeExpenseError: nil,
      taxOwnerNames: [owner: "Alex", inactiveTrust: "Family Trust"],
      taxOwnerKinds: [owner: .individual, inactiveTrust: .trust],
      profitLoss: [],
      profitLossHasUnavailableData: false,
      profitLossUnavailableInstruments: [],
      profitLossByOwner: [:],
      profitLossHasUnavailableDataByOwner: [:],
      profitLossUnavailableInstrumentsByOwner: [:],
      isLoading: false,
      error: nil,
      isMigratingCrossChainIdentity: false,
      reload: {})

    #expect(!view.selectedReport.ownerScopeUsesTrustTreatment)
  }
}

@MainActor
private func taxReportView(
  summary: CapitalGainsSummary? = nil,
  events: [CapitalGainEvent] = [],
  defaultTaxOwnerId: UUID = UUID(),
  taxOwnerNames: [UUID: String] = [:],
  taxOwnerKinds: [UUID: TaxOwnerKind] = [:],
  selectedOwnerId: UUID? = nil
) -> TaxReportView {
  TaxReportView(
    financialYear: 2027,
    holdingsDate: Date(timeIntervalSince1970: 0),
    profileInstrument: .AUD,
    summary: summary,
    events: events,
    capitalGainsHasUnavailableData: false,
    capitalGainsUnavailableInstruments: [],
    capitalGainsHasUnavailableDataByOwner: [:],
    ownerUnavailableCapitalGainsInstruments: [:],
    taxIncomeExpenseSummaries: [],
    taxIncomeExpenseRollup: nil,
    defaultTaxOwnerId: defaultTaxOwnerId,
    taxIncomeExpenseDateInterval: nil,
    taxIncomeExpenseError: nil,
    taxOwnerNames: taxOwnerNames,
    taxOwnerKinds: taxOwnerKinds,
    profitLoss: [],
    profitLossHasUnavailableData: false,
    profitLossUnavailableInstruments: [],
    profitLossByOwner: [:],
    profitLossHasUnavailableDataByOwner: [:],
    profitLossUnavailableInstrumentsByOwner: [:],
    isLoading: false,
    error: nil,
    isMigratingCrossChainIdentity: false,
    reload: {},
    selectedOwnerId: selectedOwnerId)
}
