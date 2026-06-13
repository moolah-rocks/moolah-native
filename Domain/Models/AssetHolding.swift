import Foundation

/// One row in the holdings surface. Represents either a single instrument or a
/// rollup of several per-chain instruments that share a canonical asset key
/// (e.g. ETH on mainnet + Optimism). Monetary fields are in the host currency.
///
/// Per the project's "never display a partial aggregate" rule, `value` and
/// `costBasis` are `nil` if *any* contributing position's corresponding field
/// is `nil`. `value` and `costBasis` are independent: a row may carry a known
/// cost basis while `value` is unavailable (mirrors per-row `ValuedPosition`).
struct AssetHolding: Sendable, Hashable, Identifiable {
  /// The canonical asset key for crypto rollups, otherwise the instrument's id.
  let id: String
  let kind: Instrument.Kind
  let name: String
  let displayLabel: String
  /// Max decimals across contributors — drives quantity formatting.
  let decimals: Int
  /// ISO currency code for fiat rows (which never roll up); `nil` otherwise.
  let currencyCode: String?
  /// Chain id when the holding is a single-chain crypto position; `nil` for a
  /// multi-chain rollup, stocks, and fiat.
  let chainId: Int?
  /// Exchange for stocks; `nil` otherwise.
  let exchange: String?
  let quantity: Decimal
  let unitPrice: InstrumentAmount?
  let costBasis: InstrumentAmount?
  let value: InstrumentAmount?
  /// The per-chain instrument ids that contribute to this row (1+). Drives
  /// chart filtering when the row is selected.
  let contributingInstrumentIds: [String]

  /// Number of distinct chains contributing. 1 for single-instrument rows.
  var chainCount: Int { contributingInstrumentIds.count }

  /// Value minus cost basis in the host currency, or `nil` if either side is
  /// missing. Sign preserved (CLAUDE.md) — callers must not `abs()`.
  var gainLoss: InstrumentAmount? {
    guard let value, let costBasis else { return nil }
    return value - costBasis
  }

  /// Gain as a percentage of cost basis. `nil` when value/cost missing or cost
  /// is zero. Sign preserved.
  var gainLossPercent: Decimal? {
    guard let value, let costBasis, costBasis.quantity != 0 else { return nil }
    return (value.quantity - costBasis.quantity) / costBasis.quantity * 100
  }

  var hasCostBasis: Bool { costBasis != nil }

  var quantityFormatted: String {
    QuantityFormatting.formatted(
      kind: kind,
      quantity: quantity,
      decimals: decimals,
      displayLabel: displayLabel,
      currencyCode: currencyCode)
  }

  var quantityCaption: String {
    QuantityFormatting.caption(
      kind: kind,
      quantity: quantity,
      decimals: decimals,
      displayLabel: displayLabel,
      currencyCode: currencyCode)
  }
}

// MARK: - Sortable accessors (mirror ValuedPosition for Table columns)

extension AssetHolding {
  var unitPriceQuantity: Decimal { unitPrice?.quantity ?? 0 }
  var costBasisQuantity: Decimal { costBasis?.quantity ?? 0 }
  var valueQuantity: Decimal { value?.quantity ?? 0 }
  var gainQuantity: Decimal { gainLoss?.quantity ?? 0 }
}
