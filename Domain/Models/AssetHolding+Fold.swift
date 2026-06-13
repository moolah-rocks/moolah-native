import Foundation

extension AssetHolding {
  /// Folds per-chain `ValuedPosition`s into asset rows. Crypto positions that
  /// share an `assetKey` merge into one `AssetHolding`; stocks, fiat, and
  /// crypto without a key each stand alone. Input order is irrelevant; output
  /// is sorted by id for determinism.
  ///
  /// - Parameters:
  ///   - assetKeys: `[instrumentId: assetKey]`. A missing entry (or a
  ///     non-crypto instrument) means the position stands alone under its own id.
  ///   - hostCurrency: the currency every position's `value`/`costBasis` is
  ///     expressed in. Used as the seed for the monetary sums; the caller
  ///     (`PositionsViewInput`) holds this as the single source of truth, so the
  ///     sums never touch mismatched `InstrumentAmount`s.
  static func fold(
    _ positions: [ValuedPosition], assetKeys: [String: String], hostCurrency: Instrument
  ) -> [AssetHolding] {
    func key(for position: ValuedPosition) -> String {
      guard position.instrument.kind == .cryptoToken else { return position.instrument.id }
      return assetKeys[position.instrument.id] ?? position.instrument.id
    }

    var order: [String] = []
    var groups: [String: [ValuedPosition]] = [:]
    for position in positions {
      let groupKey = key(for: position)
      if groups[groupKey] == nil { order.append(groupKey) }
      groups[groupKey, default: []].append(position)
    }

    return order.compactMap { groupKey -> AssetHolding? in
      guard let group = groups[groupKey] else { return nil }
      return Self.merge(group, key: groupKey, hostCurrency: hostCurrency)
    }
    .sorted { $0.id < $1.id }
  }

  /// Merges a non-empty group of same-asset positions into one row.
  ///
  /// Quantity is a plain `Decimal` sum: this is only valid because every
  /// contributor shares the same asset *and* the same unit (decimals). The
  /// asset key is the curated price-provider id, which today never maps two
  /// instruments of differing `decimals` to the same key.
  private static func merge(
    _ group: [ValuedPosition], key: String, hostCurrency: Instrument
  ) -> AssetHolding {
    precondition(!group.isEmpty, "merge called with empty group")
    let first = group[0]
    let quantity = group.reduce(Decimal(0)) { $0 + $1.quantity }

    // "Never display a partial aggregate": nil if ANY contributor is nil.
    // Seeded with the explicit host currency so the `+` is always same-instrument.
    var value: InstrumentAmount? = .zero(instrument: hostCurrency)
    for row in group {
      guard let accumulated = value, let rowValue = row.value else {
        value = nil
        break
      }
      value = accumulated + rowValue
    }
    // Cost basis is independent of value: defined iff EVERY contributor has one.
    var costBasis: InstrumentAmount? = .zero(instrument: hostCurrency)
    for row in group {
      guard let accumulated = costBasis, let rowCost = row.costBasis else {
        costBasis = nil
        break
      }
      costBasis = accumulated + rowCost
    }
    // Unit price in host currency: value / quantity when available.
    let unitPrice: InstrumentAmount? = {
      guard let value, quantity != 0 else { return nil }
      return InstrumentAmount(quantity: value.quantity / quantity, instrument: value.instrument)
    }()

    let chainIds = Set(group.compactMap { $0.instrument.chainId })

    return AssetHolding(
      id: key,
      kind: first.instrument.kind,
      name: first.instrument.name,
      displayLabel: first.instrument.displayLabel,
      decimals: group.map { $0.instrument.decimals }.max() ?? first.instrument.decimals,
      currencyCode: first.instrument.kind == .fiatCurrency ? first.instrument.id : nil,
      chainId: chainIds.count == 1 ? chainIds.first : nil,
      exchange: group.count == 1 ? first.instrument.exchange : nil,
      quantity: quantity,
      unitPrice: unitPrice,
      costBasis: costBasis,
      value: value,
      contributingInstrumentIds: group.map { $0.instrument.id }.sorted()
    )
  }
}
