import Foundation

/// One cost-basis event derived from a transaction's legs, valued in the
/// reference currency (AUD) on the event date. Feeds the account-aware
/// `CostBasisEngine`: acquisitions buy lots, disposals sell them, and moves
/// carry a lot between tracked accounts (cost preserved) while recording the
/// market value for return calculations.
///
/// Ordering invariant for the downstream FIFO engine (Task 3): within one
/// transaction, disposals are expected to be applied *before* acquisitions, so
/// a fee/gas leg draws from pre-existing lots rather than the lot acquired in
/// the same transaction. The crypto-fee dual-role test encodes this.
enum CostBasisEvent {
  /// A lot enters holdings: a fiat-paired buy, a non-fiat income/opening
  /// balance (valued at market), or the acquiring side of a swap.
  case acquisition(instrument: Instrument, quantity: Decimal, costPerUnit: Decimal, account: UUID?)
  /// A lot leaves holdings for proceeds: a sell, or a non-fiat expense
  /// (crypto spend / gas) valued at market.
  case disposal(
    instrument: Instrument, quantity: Decimal, proceedsPerUnit: Decimal, account: UUID?)
  // swiftlint:disable enum_case_associated_values_count
  // Flat 5-value shape matches the .move destructuring used identically across
  // HoldingsCostLedger/CapitalGainsCalculator (Tasks 3–4); a payload struct
  // would churn every call site for one case. (disable/enable pair, not :next,
  // keeps the doc comment attached to avoid orphaned_doc_comment.)
  /// A tracked→tracked transfer: the lot's cost carries in the engine while
  /// `marketValue` records what the moved quantity was worth on the date.
  case move(instrument: Instrument, quantity: Decimal, from: UUID?, to: UUID?, marketValue: Decimal)
  // swiftlint:enable enum_case_associated_values_count
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
  let remainingInvested: Decimal
}

extension InvestedSnapshot: Sendable {}

extension InvestedSnapshot: Equatable {}
