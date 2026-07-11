import Foundation

/// Summary of capital gains for a financial year.
struct CapitalGainsSummary: Sendable {
  /// Net gains/losses by holding-period bucket, used for display.
  let shortTermGain: Decimal
  let longTermGain: Decimal
  let totalGain: Decimal
  let eventCount: Int
  /// Positive gains from assets held 12 months or less, before capital-loss offsets.
  let shortTermCapitalGains: Decimal
  /// Positive gains from assets held > 12 months, before capital-loss offsets.
  let longTermCapitalGains: Decimal
  /// Current-year capital losses as a positive amount.
  let capitalLosses: Decimal
  private let netCapitalGainOverride: Decimal?

  init(
    shortTermGain: Decimal,
    longTermGain: Decimal,
    totalGain: Decimal,
    eventCount: Int,
    shortTermCapitalGains: Decimal? = nil,
    longTermCapitalGains: Decimal? = nil,
    capitalLosses: Decimal? = nil,
    netCapitalGain: Decimal? = nil
  ) {
    self.shortTermGain = shortTermGain
    self.longTermGain = longTermGain
    self.totalGain = totalGain
    self.eventCount = eventCount
    self.shortTermCapitalGains = shortTermCapitalGains ?? max(0, shortTermGain)
    self.longTermCapitalGains = longTermCapitalGains ?? max(0, longTermGain)
    self.capitalLosses = capitalLosses ?? -(min(0, shortTermGain) + min(0, longTermGain))
    self.netCapitalGainOverride = netCapitalGain
  }

  /// Australian CGT discount: 50% on long-term gains for individuals.
  var discountedLongTermGain: Decimal {
    remainingLongTermDiscountableGain / 2
  }

  /// Net capital gain after applying CGT discount (losses offset gains before discount).
  var netCapitalGain: Decimal {
    netCapitalGainOverride ?? (remainingShortTermGain + discountedLongTermGain)
  }

  private var remainingShortTermGain: Decimal {
    max(0, shortTermCapitalGains - capitalLosses)
  }

  private var remainingLongTermDiscountableGain: Decimal {
    let lossesAfterShortTerm = max(0, capitalLosses - shortTermCapitalGains)
    return max(0, longTermCapitalGains - lossesAfterShortTerm)
  }

  /// Capital-gains values in a form suitable for populating
  /// `TaxYearAdjustments` fields. Nested because it is only ever produced
  /// by `asTaxAdjustmentValues(currency:)` below.
  struct TaxAdjustmentValues {
    /// Gains from assets held 12 months or less.
    let shortTerm: InstrumentAmount
    /// Pre-discount gains from assets held > 12 months.
    let longTerm: InstrumentAmount
    /// Magnitude of net losses, expressed as a non-negative quantity for the
    /// "Capital losses" `TaxYearAdjustments` field. Built from the negative
    /// portions of `shortTermGain` / `longTermGain` via unary minus, so the
    /// monetary sign is preserved through the flip rather than discarded
    /// with `abs()`.
    let losses: InstrumentAmount
  }
}

extension CapitalGainsSummary {
  /// Convert to values suitable for `TaxYearAdjustments` fields.
  func asTaxAdjustmentValues(currency: Instrument) -> TaxAdjustmentValues {
    let shortTerm = InstrumentAmount(
      quantity: shortTermCapitalGains, instrument: currency
    )
    let longTerm = InstrumentAmount(
      quantity: longTermCapitalGains, instrument: currency
    )
    let losses = InstrumentAmount(
      quantity: capitalLosses, instrument: currency
    )
    return TaxAdjustmentValues(shortTerm: shortTerm, longTerm: longTerm, losses: losses)
  }
}
