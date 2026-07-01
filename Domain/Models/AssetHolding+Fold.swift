import Foundation

extension AssetHolding {
  /// Folds per-chain `ValuedPosition`s into asset rows. Crypto positions that
  /// share an `assetKey` merge into one `AssetHolding`; stocks, fiat, and
  /// crypto without a key each stand alone.
  ///
  /// - Parameters:
  ///   - assetKeys: `[instrumentId: assetKey]`. A missing entry (or a
  ///     non-crypto instrument) means the position stands alone under its own id.
  ///   - hostCurrency: the currency every position's `value`/`costBasis` is
  ///     expressed in. Used as the seed for the monetary sums; the caller
  ///     (`PositionsViewInput`) holds this as the single source of truth, so the
  ///     sums never touch mismatched `InstrumentAmount`s.
  ///
  /// Output is sorted by id so SwiftUI rows have stable identity and tests are
  /// deterministic; the backend's input order is arbitrary.
  static func fold(
    _ positions: [ValuedPosition], assetKeys: [String: String], hostCurrency: Instrument
  ) -> [AssetHolding] {
    var orderedGroups: [(key: String, positions: [ValuedPosition])] = []
    var indexByKey: [String: Int] = [:]
    for position in positions {
      let groupKey = Self.groupKey(for: position, assetKeys: assetKeys)
      if let i = indexByKey[groupKey] {
        orderedGroups[i].positions.append(position)
      } else {
        indexByKey[groupKey] = orderedGroups.count
        orderedGroups.append((key: groupKey, positions: [position]))
      }
    }
    return
      orderedGroups
      .map { Self.merge($0.positions, key: $0.key, hostCurrency: hostCurrency) }
      .sorted { $0.id < $1.id }
  }

  /// The key a position groups under: its curated asset key for crypto tokens
  /// (so the same asset on different chains rolls up), otherwise its own id
  /// (stocks, fiat, and crypto without a mapping each stand alone).
  private static func groupKey(for position: ValuedPosition, assetKeys: [String: String]) -> String
  {
    guard position.instrument.kind == .cryptoToken else { return position.instrument.id }
    return assetKeys[position.instrument.id] ?? position.instrument.id
  }

  /// Sums an optional host-currency amount across the group, propagating nil:
  /// the result is nil if *any* contributor's amount is nil (the project's
  /// "never display a partial aggregate" rule). Seeded with the host currency
  /// so every `+` is same-instrument.
  private static func sum(
    _ keyPath: KeyPath<ValuedPosition, InstrumentAmount?>,
    over group: [ValuedPosition],
    hostCurrency: Instrument
  ) -> InstrumentAmount? {
    var result: InstrumentAmount? = .zero(instrument: hostCurrency)
    for row in group {
      guard let accumulated = result, let contribution = row[keyPath: keyPath] else { return nil }
      result = accumulated + contribution
    }
    return result
  }

  /// Merges a non-empty group of same-asset positions into one row.
  private static func merge(
    _ group: [ValuedPosition], key: String, hostCurrency: Instrument
  ) -> AssetHolding {
    precondition(!group.isEmpty, "merge called with empty group")
    // Diagnostic: when present, value/costBasis must be in the host currency,
    // so the nil-propagating `+` in `sum` never traps on mismatched instruments.
    for row in group {
      precondition(
        (row.value?.instrument ?? hostCurrency) == hostCurrency,
        "AssetHolding.merge: value not in host currency")
      precondition(
        (row.costBasis?.instrument ?? hostCurrency) == hostCurrency,
        "AssetHolding.merge: costBasis not in host currency")
    }
    let first = group[0]
    // Same-unit assumption: contributors sharing an asset key are the same
    // token, so summing raw quantities and taking the max decimals is valid.
    let quantity = group.reduce(Decimal(0)) { $0 + $1.quantity }

    let value = Self.sum(\.value, over: group, hostCurrency: hostCurrency)
    let costBasis = Self.sum(\.costBasis, over: group, hostCurrency: hostCurrency)

    // Unit price in host currency: value / quantity when available.
    let unitPrice: InstrumentAmount? = {
      guard let value, quantity != 0 else { return nil }
      return InstrumentAmount(quantity: value.quantity / quantity, instrument: value.instrument)
    }()

    // Prefer the owning-account chain, falling back to the instrument's chain.
    // The account chain is authoritative once cross-chain identity unifies;
    // until then `instrument.chainId` still identifies the chain, so the
    // fallback keeps behavior identical for group/exchange/unwired paths (whose
    // positions carry a nil `accountChainId`) while letting `accountChainId` win
    // where it is set. Mirrors the block-explorer tier logic
    // (`accountId chain ?? instrument.chainId`).
    let chainIds = Set(group.compactMap { $0.accountChainId ?? $0.instrument.chainId })

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
      contributingInstrumentIds: Array(Set(group.map { $0.instrument.id })).sorted(),
      contributingChainIds: chainIds.sorted()
    )
  }
}
