import Foundation

struct HoldingsCostLedgerPass {
  var engine = CostBasisEngine()
  var realised: [CapitalGainEvent] = []
  var flows: [HoldingsFlowEntry] = []

  mutating func apply(_ event: CostBasisEvent, on date: Date) {
    switch event {
    case let .disposal(instrument, quantity, proceedsPerUnit, context):
      applyDisposal(
        instrument: instrument,
        quantity: quantity,
        proceedsPerUnit: proceedsPerUnit,
        context: context,
        on: date)
    case let .move(instrument, quantity, route, marketValue):
      applyMove(
        instrument: instrument,
        quantity: quantity,
        route: route,
        marketValue: marketValue,
        on: date)
    case let .acquisition(instrument, quantity, costPerUnit, holding):
      applyAcquisition(
        instrument: instrument,
        quantity: quantity,
        costPerUnit: costPerUnit,
        holding: holding,
        on: date)
    }
  }

  private mutating func applyDisposal(
    instrument: Instrument,
    quantity: Decimal,
    proceedsPerUnit: Decimal,
    context: CostBasisDisposalContext,
    on date: Date
  ) {
    realised.append(
      contentsOf: engine.processSell(
        instrument: instrument,
        quantity: quantity,
        proceedsPerUnit: proceedsPerUnit,
        date: date,
        account: context.holding.account,
        taxOwnerId: context.holding.taxOwnerId,
        sourceTransactionId: context.sourceTransactionId))
    flows.append(
      HoldingsFlowEntry(
        date: date,
        account: context.holding.account,
        instrument: instrument,
        amount: -(quantity * proceedsPerUnit),
        counterpartyAccount: nil))
  }

  private mutating func applyMove(
    instrument: Instrument,
    quantity: Decimal,
    route: CostBasisMoveRoute,
    marketValue: Decimal,
    on date: Date
  ) {
    engine.moveLots(
      instrument: instrument,
      quantity: quantity,
      from: route.from,
      to: route.to,
      taxOwnerId: route.taxOwnerId)
    flows.append(
      HoldingsFlowEntry(
        date: date,
        account: route.from,
        instrument: instrument,
        amount: -marketValue,
        counterpartyAccount: route.to))
    flows.append(
      HoldingsFlowEntry(
        date: date,
        account: route.to,
        instrument: instrument,
        amount: marketValue,
        counterpartyAccount: route.from))
  }

  private mutating func applyAcquisition(
    instrument: Instrument,
    quantity: Decimal,
    costPerUnit: Decimal,
    holding: CostBasisEventHolding,
    on date: Date
  ) {
    engine.processBuy(
      instrument: instrument,
      quantity: quantity,
      costPerUnit: costPerUnit,
      date: date,
      account: holding.account,
      taxOwnerId: holding.taxOwnerId)
    flows.append(
      HoldingsFlowEntry(
        date: date,
        account: holding.account,
        instrument: instrument,
        amount: quantity * costPerUnit,
        counterpartyAccount: nil))
  }
}
