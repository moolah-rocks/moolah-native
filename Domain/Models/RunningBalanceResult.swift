import Foundation

/// The outcome of `TransactionPage.withRunningBalances`: the computed rows plus
/// the first conversion failure encountered (if any).
///
/// Callers that need only the rendered rows can read `rows`. Stores that drive
/// a user-visible error state should observe `firstConversionError` and publish
/// it so the user sees a retry path rather than silently blanked balances.
/// See Rule 11 of `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
struct RunningBalanceResult: Sendable {
  let rows: [TransactionWithBalance]
  let firstConversionError: RunningBalanceConversionError?
}

/// A typed, Sendable wrapper around the first conversion error encountered
/// during running-balance computation. Carries the failing transaction id so
/// diagnostics can correlate logs with the surfaced user-visible error.
///
/// `errorDescription` is the user-facing copy and stays free of the raw
/// `underlyingDescription` — the provider's raw text leaks Swift enum
/// case names, contract addresses and provider identifiers that are
/// noise to the user (and often misleadingly attribute the failure,
/// e.g. blaming Binance for a stablecoin it can't trade).
/// `underlyingDescription` remains a stored property so the diagnostic
/// logger in `TransactionStore+Observation` can record the full provider
/// detail without it ever reaching the alert.
struct RunningBalanceConversionError: LocalizedError, Sendable {
  let transactionId: UUID
  let targetInstrumentId: String
  let underlyingDescription: String

  var errorDescription: String? {
    "Couldn't update the running balance in \(targetInstrumentId). "
      + "A price source is temporarily unavailable — try again in a moment."
  }
}

/// A transaction paired with converted leg amounts and the account balance after it was applied.
///
/// `displayAmount` and `balance` are `nil` when conversion failed — either for
/// this transaction's legs or for an earlier transaction in the running-balance
/// chain. `convertedLegs` is empty in the same case.
struct TransactionWithBalance: Sendable, Identifiable {
  let transaction: Transaction
  let convertedLegs: [ConvertedTransactionLeg]
  /// Per-instrument leg sums in the legs' native instruments, restricted
  /// to the legs that match the row's scope (account / earmark filter, or
  /// all legs when unfiltered). Empty when conversion failed (paired with
  /// `displayAmount == nil`). See design §4.2.
  let displayAmounts: [InstrumentAmount]
  /// Single scalar in the running-balance target instrument. Used for
  /// diagnostics and any consumer that wants the converted total; the
  /// row does not read it for rendering.
  let displayAmount: InstrumentAmount?
  let balance: InstrumentAmount?

  var id: UUID { transaction.id }

  /// Returns converted legs belonging to the given account.
  func legs(forAccount accountId: UUID) -> [ConvertedTransactionLeg] {
    convertedLegs.filter { $0.leg.accountId == accountId }
  }

  /// Returns converted legs belonging to the given earmark.
  func legs(forEarmark earmarkId: UUID) -> [ConvertedTransactionLeg] {
    convertedLegs.filter { $0.leg.earmarkId == earmarkId }
  }
}
