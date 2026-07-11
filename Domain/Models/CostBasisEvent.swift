import Foundation

/// One cost-basis event derived from a transaction's legs, valued in the
/// reference currency (AUD) on the event date. Feeds the account-aware
/// `CostBasisEngine`: acquisitions buy lots, disposals sell them, and moves
/// carry a lot between tracked accounts (cost preserved) while recording the
/// market value for return calculations.
///
/// Ordering invariant for the downstream FIFO engine (Task 3): within one
/// transaction, acquisitions are applied *before* disposals. FIFO appends new
/// lots to the tail and consumes from the head, so a fee/gas disposal still
/// drains older pre-existing lots first when they exist — but when none do
/// (e.g. gas paid in a token bought in the *same* transaction, with no prior
/// holding), the disposal can draw the just-acquired lot instead of being
/// silently dropped against an empty bucket. The crypto-fee dual-role test
/// encodes this.
struct CostBasisEventHolding: Sendable, Equatable {
  let account: UUID?
  let taxOwnerId: UUID?
}

struct CostBasisDisposalContext: Sendable, Equatable {
  let holding: CostBasisEventHolding
  let sourceTransactionId: UUID?
}

struct CostBasisMoveRoute: Sendable, Equatable {
  let from: UUID?
  let to: UUID?
  let taxOwnerId: UUID?
}

enum CostBasisEvent {
  /// A lot enters holdings: a fiat-paired buy, a non-fiat income/opening
  /// balance (valued at market), or the acquiring side of a swap.
  case acquisition(
    instrument: Instrument, quantity: Decimal, costPerUnit: Decimal, holding: CostBasisEventHolding)
  /// A lot leaves holdings for proceeds: a sell, or a non-fiat expense
  /// (crypto spend / gas) valued at market.
  case disposal(
    instrument: Instrument,
    quantity: Decimal,
    proceedsPerUnit: Decimal,
    context: CostBasisDisposalContext)
  /// A tracked→tracked transfer: the lot's cost carries in the engine while
  /// `marketValue` records what the moved quantity was worth on the date.
  case move(
    instrument: Instrument, quantity: Decimal, route: CostBasisMoveRoute, marketValue: Decimal)
}

extension CostBasisEvent: Sendable {}

extension CostBasisEvent: Equatable {}

/// A market-valued capital flow into or out of an account, in the reference
/// currency. Sign convention: `+` is capital into the account, `−` is out.
/// `instrument` lets `ProfitLossCalculator` attribute `totalInvested` per
/// instrument; `counterpartyAccount` is the other side of a tracked transfer.
struct HoldingsFlowEntry {
  let date: Date
  let account: UUID?
  var taxOwnerId: UUID?
  let instrument: Instrument
  let amount: Decimal
  let counterpartyAccount: UUID?
}

extension HoldingsFlowEntry: Sendable {}

extension HoldingsFlowEntry: Equatable {}

/// The remaining amount invested for one (account, instrument) at a point in
/// time — a change-point in the step function the ledger emits. Consumers
/// carry forward the latest snapshot at-or-before a day.
struct InvestedSnapshot {
  let date: Date
  let account: UUID?
  let instrument: Instrument
  let taxOwnerId: UUID?
  let remainingInvested: Decimal
}

extension InvestedSnapshot: Sendable {}

extension InvestedSnapshot: Equatable {}
