import Foundation

struct HoldingsCostLedgerPass {
  var engine = CostBasisEngine()
  var realised: [CapitalGainEvent] = []
  var flows: [HoldingsFlowEntry] = []

  mutating func apply(_ event: CostBasisEvent, on date: Date) {
    switch event {
    case let .disposal(instrument, quantity, proceedsPerUnit, account, sourceTransactionId):
      realised.append(
        contentsOf: engine.processSell(
          instrument: instrument,
          quantity: quantity,
          proceedsPerUnit: proceedsPerUnit,
          date: date,
          account: account,
          sourceTransactionId: sourceTransactionId))
      flows.append(
        HoldingsFlowEntry(
          date: date,
          account: account,
          instrument: instrument,
          amount: -(quantity * proceedsPerUnit),
          counterpartyAccount: nil))
    case let .move(instrument, quantity, from, to, marketValue):
      engine.moveLots(instrument: instrument, quantity: quantity, from: from, to: to)
      flows.append(
        HoldingsFlowEntry(
          date: date,
          account: from,
          instrument: instrument,
          amount: -marketValue,
          counterpartyAccount: to))
      flows.append(
        HoldingsFlowEntry(
          date: date,
          account: to,
          instrument: instrument,
          amount: marketValue,
          counterpartyAccount: from))
    case let .acquisition(instrument, quantity, costPerUnit, account):
      engine.processBuy(
        instrument: instrument,
        quantity: quantity,
        costPerUnit: costPerUnit,
        date: date,
        account: account)
      flows.append(
        HoldingsFlowEntry(
          date: date,
          account: account,
          instrument: instrument,
          amount: quantity * costPerUnit,
          counterpartyAccount: nil))
    }
  }
}
