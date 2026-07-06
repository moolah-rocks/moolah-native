// Domain/Models/AccountPerformance.swift
import Foundation

/// Account-level performance numbers in the profile currency.
///
/// All monetary fields are independently optional: a single conversion
/// failure marks the affected aggregate unavailable rather than showing a
/// partial sum (Rule 11 in `guides/INSTRUMENT_CONVERSION_GUIDE.md`). The
/// sign of `profitLoss` is preserved through all arithmetic — callers
/// must not `abs()` it.
///
/// `firstFlowDate` powers the "since Mar 2023" subtitle on the annualised-
/// return tile.
struct AccountPerformance {
  let instrument: Instrument
  let currentValue: InstrumentAmount?
  /// Remaining amount invested — the AUD cost basis of the currently-held
  /// lots (a stock, ≥ 0 by construction). For ledger-sourced accounts this
  /// is `HoldingsCostLedger.remainingInvested`; for legacy manual-valuation
  /// accounts it is the net-deposit sum. `nil` when any in-scope figure is
  /// unavailable (Rule 11 — never a partial sum).
  let amountInvested: InstrumentAmount?
  let profitLoss: InstrumentAmount?
  /// Period return on invested capital (not annualised). The ledger path
  /// computes it as the simple `gain / amountInvested` ratio; the legacy
  /// manual-valuation path uses Modified Dietz. `nil` when the invested base is
  /// zero or any input is unavailable.
  let profitLossPercent: Decimal?
  /// Effective annual rate from `IRRSolver`. `nil` for spans < 1 day,
  /// pathological multi-root cases, or when inputs are unavailable.
  let annualisedReturn: Decimal?
  let firstFlowDate: Date?
}

extension AccountPerformance: Sendable {}

extension AccountPerformance: Hashable {}

extension AccountPerformance {
  /// All-`nil` performance for the given instrument. Used when conversion
  /// fails or no data is available — keeps the row count stable while
  /// reporting unavailability per Rule 11.
  static func unavailable(in instrument: Instrument) -> AccountPerformance {
    AccountPerformance(
      instrument: instrument,
      currentValue: nil,
      amountInvested: nil,
      profitLoss: nil,
      profitLossPercent: nil,
      annualisedReturn: nil,
      firstFlowDate: nil
    )
  }

  /// Current value known, every other aggregate unavailable. Used by the
  /// unified multi-instrument path when the account has no cost basis (a
  /// wallet funded solely by on-chain receives / airdrops) or when the flow
  /// history cannot be converted: the current-value tile still shows while
  /// the P&L and annualised-return tiles hide — Rule 11 (no phantom zeros, no
  /// phantom gains). Distinct from `unavailable(in:)`, which nils the current
  /// value too.
  static func currentValueOnly(
    _ currentValue: InstrumentAmount?, in instrument: Instrument
  ) -> AccountPerformance {
    AccountPerformance(
      instrument: instrument,
      currentValue: currentValue,
      amountInvested: nil,
      profitLoss: nil,
      profitLossPercent: nil,
      annualisedReturn: nil,
      firstFlowDate: nil)
  }
}
