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
  /// Short ticker/symbol (e.g. "ETH"), not the full `name` — used as the
  /// quantity suffix and inline label.
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
  /// The distinct chain ids contributing to this row, sorted. Empty for
  /// non-crypto holdings (stocks and fiat have no chain).
  let contributingChainIds: [Int]

  /// Number of distinct chains contributing; drives whether the row shows a
  /// chain-breakdown indicator (a count of 1 is a plain single-chain row).
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

  /// `true` iff a cost basis has been provided for this row.
  var hasCostBasis: Bool { costBasis != nil }

  /// Quantity string for the primary cell; delegates to `QuantityFormatting`
  /// so this row model renders identically to `ValuedPosition`.
  var quantityFormatted: String {
    QuantityFormatting.formatted(
      kind: kind,
      quantity: quantity,
      decimals: decimals,
      displayLabel: displayLabel,
      currencyCode: currencyCode)
  }

  /// Caption-style quantity for a row's secondary line; delegates to
  /// `QuantityFormatting` so it mirrors `ValuedPosition`'s display.
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

/// Non-optional `Decimal` views of the optional monetary fields for sortable
/// Table columns. Missing values sort as zero — paired with the `—`
/// placeholder rendered in the cell, this groups failed/unknown rows at one end.
extension AssetHolding {
  var unitPriceQuantity: Decimal { unitPrice?.quantity ?? 0 }
  var costBasisQuantity: Decimal { costBasis?.quantity ?? 0 }
  var valueQuantity: Decimal { value?.quantity ?? 0 }
  var gainQuantity: Decimal { gainLoss?.quantity ?? 0 }
}

// MARK: - Chain display helpers

/// Domain-level chain naming, reused by both the wide (`Table`) and narrow
/// (`List`) holdings layouts so they stay in lockstep. Uses
/// `Instrument.chainName(for:)`, which is domain logic.
extension AssetHolding {
  /// Resolved chain names for a crypto holding's contributing chains, sorted.
  /// Empty for non-crypto holdings.
  var contributingChainNames: [String] {
    guard kind == .cryptoToken else { return [] }
    return contributingChainIds.map { Instrument.chainName(for: $0) }
  }

  /// Secondary row label naming the chains a crypto holding spans: the chain
  /// names joined for a small rollup (≤3), a count beyond that, or the single
  /// chain name. `nil` when there are no chains to show (non-crypto, or crypto
  /// with no known chain ids).
  var chainSummaryLabel: String? {
    let names = contributingChainNames
    guard !names.isEmpty else { return nil }
    return names.count <= 3 ? names.joined(separator: " · ") : "\(names.count) chains"
  }

  /// Spoken form of the chains for VoiceOver — same ≤3 rule but comma/`and`
  /// joined (no "·"), e.g. "Ethereum and Optimism" or "4 chains".
  var chainAccessibilitySummary: String? {
    let names = contributingChainNames
    guard !names.isEmpty else { return nil }
    if names.count > 3 { return "\(names.count) chains" }
    return ListFormatter.localizedString(byJoining: names)
  }
}
