import Foundation

// On-demand total computations for `AccountStore`. Pure pass-throughs to
// the calculator that need no privileged access to the store's
// `private(set)` setters.
extension AccountStore {
  /// Total value of `accountList` in `target`, summing positions directly.
  func computeConvertedTotal(for accountList: [Account], in target: Instrument) async throws
    -> InstrumentAmount
  {
    try await balanceCalculator.totalConverted(for: accountList, to: target)
  }

  /// Total value of current accounts in `target`.
  func computeConvertedCurrentTotal(in target: Instrument) async throws -> InstrumentAmount {
    try await balanceCalculator.totalConverted(for: currentAccounts, to: target)
  }

  /// Total value of investment accounts in `target`, summing positions in a
  /// single pass to avoid chaining two conversions.
  func computeConvertedInvestmentTotal(in target: Instrument) async throws -> InstrumentAmount {
    try await balanceCalculator.totalConverted(for: investmentAccounts, to: target)
  }

  /// Net worth (current + investment) in `target`.
  func computeConvertedNetWorth(in target: Instrument) async throws -> InstrumentAmount {
    let current = try await computeConvertedCurrentTotal(in: target)
    let investment = try await computeConvertedInvestmentTotal(in: target)
    return current + investment
  }
}
