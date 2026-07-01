import Foundation

/// One row in a `PositionsView`: instrument identity + quantity, plus the
/// current unit price, cost basis, and total value all expressed in the host
/// currency. `value`, `unitPrice`, and `costBasis` are independently optional
/// so callers can supply only what they have:
///
/// - Flow contexts (filtered transaction list): `costBasis` and `unitPrice`
///   are `nil`; `value` is the converted flow amount or `nil` on failure.
/// - Investment account: all four are populated where the conversion service
///   succeeds. A per-row conversion failure leaves `value` (and the derived
///   `gainLoss`) `nil`; the caller still renders qty + identifier.
struct ValuedPosition {
  let instrument: Instrument
  let quantity: Decimal
  let unitPrice: InstrumentAmount?
  let costBasis: InstrumentAmount?
  let value: InstrumentAmount?
  /// The chain ID of the account that owns this position, when the position
  /// originates from a chain-scoped (crypto) account. `nil` for fiat and
  /// stock positions, and for crypto positions where chain context is not
  /// available to the caller.
  let accountChainId: Int?

  init(
    instrument: Instrument,
    quantity: Decimal,
    unitPrice: InstrumentAmount?,
    costBasis: InstrumentAmount?,
    value: InstrumentAmount?,
    accountChainId: Int? = nil
  ) {
    self.instrument = instrument
    self.quantity = quantity
    self.unitPrice = unitPrice
    self.costBasis = costBasis
    self.value = value
    self.accountChainId = accountChainId
  }

  /// The position quantity wrapped as an `InstrumentAmount` in the
  /// instrument's own units (not the host currency).
  var amount: InstrumentAmount {
    InstrumentAmount(quantity: quantity, instrument: instrument)
  }

  /// `true` iff a cost basis has been provided for this row.
  var hasCostBasis: Bool { costBasis != nil }

  /// Value minus cost basis in the host currency, or `nil` if either side is
  /// missing. Per CLAUDE.md sign convention the result preserves its sign —
  /// callers must not `abs()` the gain when colouring or sorting.
  var gainLoss: InstrumentAmount? {
    guard let value, let costBasis else { return nil }
    return value - costBasis
  }

  /// Gain as a percentage of cost basis (e.g. `12.5` for +12.5%). `nil`
  /// when `value` is missing, `costBasis` is missing, or `costBasis` is
  /// zero. The sign is preserved through all arithmetic; callers must
  /// not `abs()` the result when colouring or sorting.
  var gainLossPercent: Decimal? {
    guard let value, let costBasis, costBasis.quantity != 0 else { return nil }
    return (value.quantity - costBasis.quantity) / costBasis.quantity * 100
  }
}

extension ValuedPosition: Sendable {}

extension ValuedPosition: Hashable {}

extension ValuedPosition: Identifiable {
  var id: String { instrument.id }
}
