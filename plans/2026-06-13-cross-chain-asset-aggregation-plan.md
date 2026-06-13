# Cross-chain Asset Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Roll same-asset-across-chains crypto holdings (e.g. mainnet ETH `1:native` + Optimism ETH `10:native`) into a single asset line in the holdings surface, while every upstream layer (legs, sync, gas, cost basis, pricing) stays strictly per-chain.

**Architecture:** A presentation-layer fold. A canonical `assetKey` (the crypto instrument's price-provider id, sourced from the registry) groups per-chain `ValuedPosition`s into a unified `AssetHolding` display row. The fold is pure and unit-tested. `AssetHolding` replaces `ValuedPosition` as the row model rendered by `PositionsTable`/`PositionRow`; a single-contributor holding renders identically to today. Chart selection generalises from a single `Instrument` to a `PositionSelection` carrying the contributing instrument ids, and the chart sums their historical series. No schema change, no data migration.

**Tech Stack:** Swift, SwiftUI, Swift Testing (`@Test`/`#expect`), GRDB-backed `TestBackend`. Build/test/format via `just`.

**Design doc:** `plans/2026-06-13-cross-chain-asset-aggregation-design.md`

---

## File Structure

**New files**
- `Domain/Models/AssetHolding.swift` — unified display-row model + computed display surface (gainLoss, sortable accessors).
- `Domain/Models/AssetHolding+Fold.swift` — pure fold `[ValuedPosition] + [instrumentId: assetKey] → [AssetHolding]`.
- `Domain/Models/AssetHolding+Display.swift` — `quantityFormatted` / `quantityCaption` (moved/shared from `ValuedPosition+Display.swift`).
- `Domain/Models/PositionSelection.swift` — selection value type shared by table + chart.
- `MoolahTests/Domain/AssetKeyTests.swift`
- `MoolahTests/Domain/AssetHoldingFoldTests.swift`
- `MoolahTests/Domain/HistoricalValueSeriesAssetTests.swift`

**Modified files**
- `Domain/Models/CryptoProviderMapping.swift` — add `assetKey` + static `assetKeys(from:)` map builder.
- `Domain/Models/HistoricalValueSeries.swift` — add `series(forInstrumentIds:)`.
- `Domain/Models/PositionsViewInput.swift` — add `assetKeysByInstrumentId` (default `[:]`); add `assetHoldings` computed fold entry point.
- `Shared/Views/Positions/PositionsTable.swift` — render `[AssetHolding]`; `InstrumentGroup` over holdings; `PositionSelection` binding.
- `Shared/Views/Positions/PositionRow.swift` — `row: AssetHolding`; multi-chain secondary label.
- `Shared/Views/Positions/PositionsView.swift` — `@State selection: PositionSelection?`.
- `Shared/Views/Positions/PositionsChart.swift` — `@Binding selectedSelection: PositionSelection?`; sum series.
- `Features/Investments/InvestmentStore+PositionsInput.swift` — build + pass asset-key map.
- `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift` — build + pass asset-key map.

---

## Task 1: Asset key derivation + map builder

**Files:**
- Modify: `Domain/Models/CryptoProviderMapping.swift`
- Test: `MoolahTests/Domain/AssetKeyTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Domain/AssetKeyTests.swift`:

```swift
import Testing

@testable import Moolah

@Suite struct AssetKeyTests {
  @Test func coingeckoIdWins() {
    let m = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: "ethereum",
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")
    #expect(m.assetKey == "ethereum")
  }

  @Test func fallsBackToCryptocompareThenBinance() {
    let cc = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: nil,
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")
    #expect(cc.assetKey == "ETH")
    let bn = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: "ETHUSDT")
    #expect(bn.assetKey == "ETHUSDT")
  }

  @Test func standsAloneWhenNoProviderId() {
    let m = CryptoProviderMapping(
      instrumentId: "1:0xabc", coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: nil)
    #expect(m.assetKey == "1:0xabc")
  }

  @Test func mapMergesSameAssetAcrossChains() {
    let eth1 = CryptoRegistration(
      instrument: .crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      mapping: CryptoProviderMapping(instrumentId: "1:native", coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil))
    let eth10 = CryptoRegistration(
      instrument: .crypto(chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18),
      mapping: CryptoProviderMapping(instrumentId: "10:native", coingeckoId: "ethereum", cryptocompareSymbol: nil, binanceSymbol: nil))
    let map = CryptoProviderMapping.assetKeys(from: [eth1, eth10])
    #expect(map["1:native"] == "ethereum")
    #expect(map["10:native"] == "ethereum")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac AssetKeyTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: compile failure — `assetKey` / `assetKeys(from:)` not defined.

- [ ] **Step 3: Implement**

Append to `Domain/Models/CryptoProviderMapping.swift` (inside the struct, after `hasProviderMapping`):

```swift
  /// Canonical cross-chain asset key: the curated price-provider id, which is
  /// shared by every chain's variant of the same asset (e.g. `"ethereum"` for
  /// ETH on mainnet and every L2). Falls back to the instrument's own id when
  /// no provider id is present — an unmapped token cannot safely be claimed to
  /// be "the same asset" as anything else, so it stands alone.
  var assetKey: String {
    coingeckoId ?? cryptocompareSymbol ?? binanceSymbol ?? instrumentId
  }

  /// Builds an `[instrumentId: assetKey]` lookup from a set of crypto
  /// registrations, for the holdings rollup. Instruments absent from the
  /// result stand alone (the fold treats a missing key as the instrument's
  /// own id).
  static func assetKeys(from registrations: [CryptoRegistration]) -> [String: String] {
    var map: [String: String] = [:]
    for reg in registrations {
      map[reg.instrument.id] = reg.mapping.assetKey
    }
    return map
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac AssetKeyTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Domain/Models/CryptoProviderMapping.swift MoolahTests/Domain/AssetKeyTests.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): canonical cross-chain asset key + map builder (#1101)"
```

---

## Task 2: `AssetHolding` model + display surface

**Files:**
- Create: `Domain/Models/AssetHolding.swift`
- Create: `Domain/Models/AssetHolding+Display.swift`

This task defines the type and its computed surface (no fold yet — Task 3). No new behaviour to test in isolation beyond what Task 3 exercises, so it has no standalone test; it compiles and is covered by Task 3.

- [ ] **Step 1: Create the model**

Create `Domain/Models/AssetHolding.swift`:

```swift
import Foundation

/// One row in the holdings surface. Represents either a single instrument or a
/// rollup of several per-chain instruments that share a canonical asset key
/// (e.g. ETH on mainnet + Optimism). Monetary fields are in the host currency.
///
/// Per the project's "never display a partial aggregate" rule, `value` and
/// `costBasis` are `nil` if *any* contributing position's corresponding field
/// is `nil` (a single conversion failure marks the whole rollup unavailable).
struct AssetHolding: Sendable, Hashable, Identifiable {
  /// The canonical asset key for crypto rollups, otherwise the instrument's id.
  let id: String
  let kind: Instrument.Kind
  let name: String
  let displayLabel: String
  /// Max decimals across contributors — drives quantity formatting.
  let decimals: Int
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
}

// MARK: - Sortable accessors (mirror ValuedPosition for Table columns)

extension AssetHolding {
  var unitPriceQuantity: Decimal { unitPrice?.quantity ?? 0 }
  var costBasisQuantity: Decimal { costBasis?.quantity ?? 0 }
  var valueQuantity: Decimal { value?.quantity ?? 0 }
  var gainQuantity: Decimal { gainLoss?.quantity ?? 0 }
}
```

- [ ] **Step 2: Create the display helpers**

Create `Domain/Models/AssetHolding+Display.swift` (mirrors `ValuedPosition+Display.swift`, now keyed off `AssetHolding`):

```swift
import Foundation

extension AssetHolding {
  /// Human-friendly quantity string per kind.
  /// - `.fiatCurrency` → currency-formatted.
  /// - `.stock` → decimal up to `decimals` places, no suffix.
  /// - `.cryptoToken` → decimal (capped at 8 places) + display label.
  var quantityFormatted: String {
    switch kind {
    case .fiatCurrency:
      // Fiat holdings never roll up, so a single contributing instrument id
      // exists; reconstruct its InstrumentAmount for locale formatting.
      let instrument = Instrument.fiat(code: id)
      return InstrumentAmount(quantity: quantity, instrument: instrument).formatted
    case .stock:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.minimumFractionDigits = 0
      formatter.maximumFractionDigits = decimals
      return formatter.string(from: quantity as NSDecimalNumber) ?? "\(quantity)"
    case .cryptoToken:
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.minimumFractionDigits = 0
      formatter.maximumFractionDigits = min(decimals, 8)
      let qty = formatter.string(from: quantity as NSDecimalNumber) ?? "\(quantity)"
      return "\(qty) \(displayLabel)"
    }
  }

  /// Caption-style quantity for the narrow row's secondary line.
  var quantityCaption: String {
    switch kind {
    case .stock: return "\(quantityFormatted) shares"
    case .fiatCurrency, .cryptoToken: return quantityFormatted
    }
  }
}
```

> Note: `ValuedPosition+Display.swift`'s `quantityFormatted`/`quantityCaption` are no longer referenced by the views after Task 7 but remain used by tests; leave them in place. The `signedFormatted` and `GainLossPercentDisplay` helpers in that file stay and are reused unchanged.

- [ ] **Step 3: Build to verify it compiles**

Run: `just build-mac 2>&1 | tee .agent-tmp/t2.txt`
Expected: build succeeds (no warnings).

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Domain/Models/AssetHolding.swift Domain/Models/AssetHolding+Display.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): AssetHolding display-row model (#1101)"
```

---

## Task 3: The fold — `[ValuedPosition] → [AssetHolding]`

**Files:**
- Create: `Domain/Models/AssetHolding+Fold.swift`
- Test: `MoolahTests/Domain/AssetHoldingFoldTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Domain/AssetHoldingFoldTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite struct AssetHoldingFoldTests {
  private let aud = Instrument.AUD
  private func eth(_ chain: Int) -> Instrument {
    .crypto(chainId: chain, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
  }
  private func amt(_ q: Decimal) -> InstrumentAmount { InstrumentAmount(quantity: q, instrument: aud) }

  @Test func mergesEthAcrossChainsWithIssueNumbers() {
    let rows = [
      ValuedPosition(instrument: eth(1), quantity: Decimal(string: "11.36718")!,
        unitPrice: amt(4000), costBasis: amt(30000), value: amt(45468)),
      ValuedPosition(instrument: eth(10), quantity: Decimal(string: "1.58976")!,
        unitPrice: amt(4000), costBasis: amt(5000), value: amt(6359)),
    ]
    let map = ["1:native": "ethereum", "10:native": "ethereum"]
    let holdings = AssetHolding.fold(rows, assetKeys: map)
    #expect(holdings.count == 1)
    let h = holdings[0]
    #expect(h.id == "ethereum")
    #expect(h.quantity == Decimal(string: "12.95694")!)
    #expect(h.value == amt(51827))
    #expect(h.costBasis == amt(35000))
    #expect(h.chainCount == 2)
    #expect(Set(h.contributingInstrumentIds) == ["1:native", "10:native"])
  }

  @Test func partialConversionFailureMakesValueNil() {
    let rows = [
      ValuedPosition(instrument: eth(1), quantity: 1, unitPrice: amt(4000), costBasis: amt(3000), value: amt(4000)),
      ValuedPosition(instrument: eth(10), quantity: 2, unitPrice: nil, costBasis: nil, value: nil),
    ]
    let h = AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum", "10:native": "ethereum"])[0]
    #expect(h.quantity == 3)        // quantity always known
    #expect(h.value == nil)         // partial → unavailable
    #expect(h.costBasis == nil)     // one contributor lacks cost → undefined
    #expect(h.gainLoss == nil)
  }

  @Test func unpricedTokenStandsAlone() {
    let token = Instrument.crypto(chainId: 1, contractAddress: "0xabc", symbol: "FOO", name: "Foo", decimals: 18)
    let rows = [ValuedPosition(instrument: token, quantity: 5, unitPrice: nil, costBasis: nil, value: nil)]
    let h = AssetHolding.fold(rows, assetKeys: [:])  // no key → stands alone
    #expect(h.count == 1)
    #expect(h[0].id == "1:0xabc")
    #expect(h[0].chainCount == 1)
  }

  @Test func stocksAndFiatNeverMerge() {
    let bhp = Instrument.stock(ticker: "BHP.AX", exchange: "ASX", name: "BHP")
    let rows = [
      ValuedPosition(instrument: bhp, quantity: 100, unitPrice: amt(45), costBasis: amt(4000), value: amt(4500)),
      ValuedPosition(instrument: aud, quantity: 1000, unitPrice: nil, costBasis: nil, value: amt(1000)),
    ]
    let h = AssetHolding.fold(rows, assetKeys: [:])
    #expect(h.count == 2)
    #expect(Set(h.map(\.id)) == ["ASX:BHP.AX", "AUD"])
  }

  @Test func singleChainPassthroughKeepsChainId() {
    let rows = [ValuedPosition(instrument: eth(1), quantity: 1, unitPrice: amt(4000), costBasis: amt(3000), value: amt(4000))]
    let h = AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum"])[0]
    #expect(h.chainId == 1)
    #expect(h.chainCount == 1)
    #expect(h.id == "ethereum")
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac AssetHoldingFoldTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: compile failure — `AssetHolding.fold` not defined.

- [ ] **Step 3: Implement**

Create `Domain/Models/AssetHolding+Fold.swift`:

```swift
import Foundation

extension AssetHolding {
  /// Folds per-chain `ValuedPosition`s into asset rows. Crypto positions that
  /// share an `assetKey` merge into one `AssetHolding`; stocks, fiat, and
  /// crypto without a key each stand alone. Input order is irrelevant; output
  /// is sorted by id for determinism.
  ///
  /// - Parameter assetKeys: `[instrumentId: assetKey]`. A missing entry (or a
  ///   non-crypto instrument) means the position stands alone under its own id.
  static func fold(
    _ positions: [ValuedPosition], assetKeys: [String: String]
  ) -> [AssetHolding] {
    func key(for position: ValuedPosition) -> String {
      guard position.instrument.kind == .cryptoToken else { return position.instrument.id }
      return assetKeys[position.instrument.id] ?? position.instrument.id
    }

    // Preserve grouping order by first appearance, then sort the result.
    var order: [String] = []
    var groups: [String: [ValuedPosition]] = [:]
    for position in positions {
      let k = key(for: position)
      if groups[k] == nil { order.append(k) }
      groups[k, default: []].append(position)
    }

    return order.compactMap { k in groups[k].map { Self.merge($0, key: k) } }
      .sorted { $0.id < $1.id }
  }

  /// Merges a non-empty group of same-asset positions into one row.
  private static func merge(_ group: [ValuedPosition], key: String) -> AssetHolding {
    let first = group[0]
    let quantity = group.reduce(Decimal(0)) { $0 + $1.quantity }

    // "Never display a partial aggregate": nil if ANY contributor is nil.
    let value: InstrumentAmount? = group.reduce(InstrumentAmount.zero(instrument: hostInstrument(group))) {
      acc, row in
      guard let acc, let v = row.value else { return nil }
      return acc + v
    }
    // Cost basis: defined only when EVERY contributor has one.
    let costBasis: InstrumentAmount? = group.reduce(InstrumentAmount.zero(instrument: hostInstrument(group))) {
      acc, row in
      guard let acc, let c = row.costBasis else { return nil }
      return acc + c
    }
    // Unit price in host currency: value / quantity when available.
    let unitPrice: InstrumentAmount? = {
      guard let value, quantity != 0 else { return nil }
      return InstrumentAmount(quantity: value.quantity / quantity, instrument: value.instrument)
    }()

    let chainIds = Set(group.compactMap { $0.instrument.chainId })
    let ids = group.map { $0.instrument.id }.sorted()

    return AssetHolding(
      id: key,
      kind: first.instrument.kind,
      name: first.instrument.name,
      displayLabel: first.instrument.displayLabel,
      decimals: group.map { $0.instrument.decimals }.max() ?? first.instrument.decimals,
      chainId: ids.count == 1 ? first.instrument.chainId : nil,
      exchange: ids.count == 1 ? first.instrument.exchange : nil,
      quantity: quantity,
      unitPrice: unitPrice,
      costBasis: costBasis,
      value: value,
      contributingInstrumentIds: ids
    )
  }

  /// The host currency for the group's monetary fields — taken from the first
  /// available converted amount; falls back to the position's own instrument
  /// only for the all-nil case (where the resulting zero is discarded by the
  /// nil-propagating reduce anyway).
  private static func hostInstrument(_ group: [ValuedPosition]) -> Instrument {
    group.compactMap { $0.value?.instrument ?? $0.costBasis?.instrument }.first
      ?? group[0].instrument
  }
}
```

> Implementation note: `InstrumentAmount.zero(instrument:)` and `+` trap on instrument mismatch — safe here because all contributors' `value`/`costBasis` are in the same host currency by construction (the store converts every row to one host currency). The `reduce` seeds with the host instrument so the first real add matches.

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac AssetHoldingFoldTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: PASS (all 5 tests).

- [ ] **Step 5: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Domain/Models/AssetHolding+Fold.swift MoolahTests/Domain/AssetHoldingFoldTests.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): fold per-chain positions into asset rows (#1101)"
```

---

## Task 4: `HistoricalValueSeries.series(forInstrumentIds:)`

**Files:**
- Modify: `Domain/Models/HistoricalValueSeries.swift`
- Test: `MoolahTests/Domain/HistoricalValueSeriesAssetTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Domain/HistoricalValueSeriesAssetTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite struct HistoricalValueSeriesAssetTests {
  private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }

  @Test func sumsContributingSeriesByDate() {
    let series = HistoricalValueSeries(
      hostCurrency: .AUD,
      total: [],
      perInstrument: [
        "1:native": [
          .init(date: day(1), value: 100, cost: 80, contributions: nil),
          .init(date: day(2), value: 110, cost: 80, contributions: nil),
        ],
        "10:native": [
          .init(date: day(1), value: 20, cost: 15, contributions: nil),
          .init(date: day(2), value: 25, cost: 15, contributions: nil),
        ],
      ])
    let summed = series.series(forInstrumentIds: ["1:native", "10:native"])
    #expect(summed.count == 2)
    #expect(summed[0].date == day(1))
    #expect(summed[0].value == 120)
    #expect(summed[0].cost == 95)
    #expect(summed[1].value == 135)
  }

  @Test func singleIdMatchesSeriesForInstrument() {
    let points: [HistoricalValueSeries.Point] = [.init(date: day(1), value: 100, cost: 80, contributions: nil)]
    let series = HistoricalValueSeries(hostCurrency: .AUD, total: [], perInstrument: ["1:native": points])
    #expect(series.series(forInstrumentIds: ["1:native"]) == points)
  }

  @Test func unknownIdsYieldEmpty() {
    let series = HistoricalValueSeries(hostCurrency: .AUD, total: [], perInstrument: [:])
    #expect(series.series(forInstrumentIds: ["nope"]).isEmpty)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac HistoricalValueSeriesAssetTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: compile failure — `series(forInstrumentIds:)` not defined.

- [ ] **Step 3: Implement**

Add to `Domain/Models/HistoricalValueSeries.swift` (after `series(for:)`):

```swift
  /// Sums the per-instrument series for a set of instrument ids by date —
  /// used when an aggregated asset row (e.g. ETH across chains) is selected.
  /// A date is emitted only if it is present in every contributing series, so
  /// the result never reports a partial-coverage value. `value` and `cost`
  /// sum; `contributions` is left `nil` (per-instrument series carry none).
  func series(forInstrumentIds ids: [String]) -> [Point] {
    let seriesList = ids.compactMap { perInstrument[$0] }
    guard let firstSeries = seriesList.first else { return [] }
    if seriesList.count == 1 { return firstSeries }

    // Index each contributor by date for intersection + summation.
    let byDate: [[Date: Point]] = seriesList.map { series in
      Dictionary(series.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
    }
    return firstSeries.compactMap { anchor -> Point? in
      let date = anchor.date
      var value = Decimal(0)
      var cost = Decimal(0)
      for table in byDate {
        guard let p = table[date] else { return nil }  // partial coverage → drop date
        value += p.value
        cost += p.cost
      }
      return Point(date: date, value: value, cost: cost, contributions: nil)
    }
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac HistoricalValueSeriesAssetTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Domain/Models/HistoricalValueSeries.swift MoolahTests/Domain/HistoricalValueSeriesAssetTests.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): sum historical series across an asset's chains (#1101)"
```

---

## Task 5: `PositionSelection` + `PositionsViewInput` plumbing

**Files:**
- Create: `Domain/Models/PositionSelection.swift`
- Modify: `Domain/Models/PositionsViewInput.swift`
- Test: `MoolahTests/Domain/PositionsViewInputTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Add to `MoolahTests/Domain/PositionsViewInputTests.swift` (new `@Test` in the existing suite):

```swift
  @Test func assetHoldingsFoldCryptoUsingAssetKeyMap() {
    let eth1 = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let eth10 = Instrument.crypto(chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let aud = Instrument.AUD
    func amt(_ q: Decimal) -> InstrumentAmount { InstrumentAmount(quantity: q, instrument: aud) }
    let input = PositionsViewInput(
      title: "Wallet", hostCurrency: aud,
      positions: [
        ValuedPosition(instrument: eth1, quantity: 2, unitPrice: amt(4000), costBasis: amt(6000), value: amt(8000)),
        ValuedPosition(instrument: eth10, quantity: 1, unitPrice: amt(4000), costBasis: amt(3000), value: amt(4000)),
      ],
      historicalValue: nil,
      assetKeysByInstrumentId: ["1:native": "ethereum", "10:native": "ethereum"])
    let holdings = input.assetHoldings
    #expect(holdings.count == 1)
    #expect(holdings[0].quantity == 3)
    #expect(holdings[0].value == amt(12000))
  }

  @Test func assetHoldingsDefaultEmptyMapStandsAlone() {
    let eth1 = Instrument.crypto(chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let eth10 = Instrument.crypto(chainId: 10, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
    let aud = Instrument.AUD
    func amt(_ q: Decimal) -> InstrumentAmount { InstrumentAmount(quantity: q, instrument: aud) }
    let input = PositionsViewInput(
      title: "Wallet", hostCurrency: aud,
      positions: [
        ValuedPosition(instrument: eth1, quantity: 2, unitPrice: amt(4000), costBasis: amt(6000), value: amt(8000)),
        ValuedPosition(instrument: eth10, quantity: 1, unitPrice: amt(4000), costBasis: amt(3000), value: amt(4000)),
      ],
      historicalValue: nil)  // no map → no merge
    #expect(input.assetHoldings.count == 2)
  }
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac PositionsViewInputTests 2>&1 | tee .agent-tmp/t5.txt`
Expected: compile failure — extra argument `assetKeysByInstrumentId` / `assetHoldings` not defined.

- [ ] **Step 3: Create `PositionSelection`**

Create `Domain/Models/PositionSelection.swift`:

```swift
import Foundation

/// A selected holdings row, shared by the table (sets it) and the chart
/// (reads it to filter). Carries enough to render the filter chip and to sum
/// the contributing instruments' historical series, without re-deriving from
/// the registry.
struct PositionSelection: Sendable, Hashable, Identifiable {
  /// The row id — an `assetKey` for a crypto rollup, otherwise an instrument id.
  let id: String
  let kind: Instrument.Kind
  let displayLabel: String
  /// The per-chain instrument ids this selection covers (1+).
  let instrumentIds: [String]

  init(holding: AssetHolding) {
    self.id = holding.id
    self.kind = holding.kind
    self.displayLabel = holding.displayLabel
    self.instrumentIds = holding.contributingInstrumentIds
  }
}
```

- [ ] **Step 4: Add the field + fold entry point to `PositionsViewInput`**

In `Domain/Models/PositionsViewInput.swift`, add the stored property (after `historicalValue`):

```swift
  /// `[instrumentId: assetKey]` used to roll same-asset-across-chains crypto
  /// positions into a single holdings row. Empty (the default) means no
  /// rollup — every position stands alone, preserving pre-aggregation
  /// behaviour at call sites that don't supply it.
  let assetKeysByInstrumentId: [String: String]
```

Add the parameter to the designated initializer (with a default so existing call sites compile unchanged), placed after `historicalValue`:

```swift
    historicalValue: HistoricalValueSeries?,
    assetKeysByInstrumentId: [String: String] = [:],
    performance: AccountPerformance? = nil,
```

…and assign it in the body: `self.assetKeysByInstrumentId = assetKeysByInstrumentId`.

Add the computed fold entry point (after `shouldHide`/`rendersNothing`):

```swift
  /// The positions folded into asset rows for display. Crypto positions
  /// sharing an `assetKey` (per `assetKeysByInstrumentId`) merge into one row;
  /// stocks, fiat, and unmapped crypto stand alone.
  var assetHoldings: [AssetHolding] {
    AssetHolding.fold(positions, assetKeys: assetKeysByInstrumentId)
  }
```

> `PositionsViewInput` is `Hashable`; adding a `[String: String]` stored property keeps synthesis valid. Confirm no manual `Hashable`/`==` exists (it does not — synthesised).

- [ ] **Step 5: Run test to verify it passes**

Run: `just test-mac PositionsViewInputTests 2>&1 | tee .agent-tmp/t5.txt`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Domain/Models/PositionSelection.swift Domain/Models/PositionsViewInput.swift MoolahTests/Domain/PositionsViewInputTests.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): PositionSelection + assetHoldings fold entry point (#1101)"
```

---

## Task 6: `PositionRow` renders `AssetHolding`

**Files:**
- Modify: `Shared/Views/Positions/PositionRow.swift`

No standalone unit test (view); covered by build + the snapshot in Task 11.

- [ ] **Step 1: Change the row type and secondary label**

In `Shared/Views/Positions/PositionRow.swift`:

- Change `let row: ValuedPosition` → `let row: AssetHolding`.
- Replace all `row.instrument.kind` → `row.kind`, `row.instrument.name` → `row.name`.
- Replace `secondaryIdentifier` with the multi-chain-aware version:

```swift
  private var secondaryIdentifier: String? {
    switch row.kind {
    case .stock: return row.exchange
    case .cryptoToken:
      if row.chainCount > 1 { return "\(row.chainCount) chains" }
      if let chainId = row.chainId { return Instrument.chainName(for: chainId) }
      return nil
    case .fiatCurrency: return nil
    }
  }
```

- `row.quantityCaption`, `row.value`, `row.gainLoss`, `row.gainLossPercent` all exist on `AssetHolding` (Tasks 2) — no change needed at those call sites.
- Update `previewRows()` to return `[AssetHolding]` (construct two single-chain holdings + one multi-chain ETH rollup for visual coverage):

```swift
private func previewRows() -> [AssetHolding] {
  let aud = Instrument.AUD
  func amt(_ q: Decimal) -> InstrumentAmount { InstrumentAmount(quantity: q, instrument: aud) }
  return [
    AssetHolding(
      id: "ASX:BHP.AX", kind: .stock, name: "BHP", displayLabel: "BHP.AX", decimals: 0,
      chainId: nil, exchange: "ASX", quantity: 250, unitPrice: amt(45.30),
      costBasis: amt(10_125), value: amt(11_325), contributingInstrumentIds: ["ASX:BHP.AX"]),
    AssetHolding(
      id: "ethereum", kind: .cryptoToken, name: "Ethereum", displayLabel: "ETH", decimals: 18,
      chainId: nil, exchange: nil, quantity: Decimal(string: "12.95694")!, unitPrice: amt(4_000),
      costBasis: amt(35_000), value: amt(51_827),
      contributingInstrumentIds: ["1:native", "10:native"]),
    AssetHolding(
      id: "AUD", kind: .fiatCurrency, name: "AUD", displayLabel: "$", decimals: 2,
      chainId: nil, exchange: nil, quantity: 1_520, unitPrice: nil, costBasis: nil,
      value: amt(1_520), contributingInstrumentIds: ["AUD"]),
  ]
}
```

- `#Preview("rows")` body changes `PositionRow(row: row)` (unchanged signature shape; `row` is now an `AssetHolding`).

- [ ] **Step 2: Build to verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/t6.txt`
Expected: builds. (`PositionsTable` still references `ValuedPosition` rows — it will not compile yet; do Task 7 in the same working session before building.) If building standalone fails only with `PositionsTable` errors, that is expected and resolved by Task 7.

- [ ] **Step 3: Commit (after Task 7 builds clean — see note)**

Defer the commit; commit Tasks 6+7 together at the end of Task 7 since they are mutually dependent (both touch the shared `selection` type and row model).

---

## Task 7: `PositionsTable` renders `[AssetHolding]` + `PositionSelection`

**Files:**
- Modify: `Shared/Views/Positions/PositionsTable.swift`

- [ ] **Step 1: Switch the selection binding and row source**

In `Shared/Views/Positions/PositionsTable.swift`:

- Change `@Binding var selection: Instrument?` → `@Binding var selection: PositionSelection?`.
- Change the sort comparator generic and default:

```swift
  @State private var sortOrder: [KeyPathComparator<AssetHolding>] = [
    .init(\.valueQuantity, order: .reverse)
  ]
```

- Replace `groups`:

```swift
  private var holdings: [AssetHolding] { input.assetHoldings }
  private var groups: [InstrumentGroup] { InstrumentGroup.from(holdings) }
```

- `wideLayout`: `let sortedRows = groups.flatMap(\.rows).sorted(using: sortOrder)` — now `[AssetHolding]`. Update column key paths/value closures: `\.instrument.name` → `\.name`; `\.quantity` stays; `row.quantityFormatted`, `row.unitPrice`, `row.costBasis`, `row.value`, `row.gainLoss`, `row.gainLossPercent`, `row.unitPriceQuantity`, `row.costBasisQuantity`, `row.valueQuantity`, `row.gainQuantity` all exist on `AssetHolding`.
- `instrumentCell(for:)`: `row.instrument.kind` → `row.kind`; `row.instrument.name` → `row.name`; `row.instrument.exchange` → `row.exchange`.

- [ ] **Step 2: Update the selection bindings**

Replace `rowSelectionBinding` and `narrowSelectionBinding` to resolve ids against `holdings` and produce a `PositionSelection`:

```swift
  private var rowSelectionBinding: Binding<Set<String>> {
    Binding(
      get: { selection.map { [$0.id] } ?? [] },
      set: { ids in
        if let id = ids.first, let holding = holdings.first(where: { $0.id == id }) {
          selection = (selection?.id == id) ? nil : PositionSelection(holding: holding)
        } else {
          selection = nil
        }
      })
  }

  private var narrowSelectionBinding: Binding<String?> {
    Binding(
      get: { selection?.id },
      set: { id in
        if let id, let holding = holdings.first(where: { $0.id == id }) {
          selection = (selection?.id == id) ? nil : PositionSelection(holding: holding)
        } else {
          selection = nil
        }
      })
  }
```

- Update `instrumentLabel(for:)` to take `AssetHolding` (use `row.kind`, `row.name`, `row.exchange`).
- Update `InstrumentGroup.from(_:)` signature to take `[AssetHolding]` and filter on `$0.kind` (was `$0.instrument.kind`); change the stored `rows` to `[AssetHolding]`.
- Update this file's `#Preview` helpers (`mixedPositionsInput`) — they pass `ValuedPosition`s into `PositionsViewInput.positions`, which is still correct (input holds `ValuedPosition`s); the table folds internally. The `selection: .constant(nil)` previews still compile (type is now `PositionSelection?`).

- [ ] **Step 3: Build to verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/t7.txt`
Expected: builds clean **except** `PositionsView`/`PositionsChart` still pass `Instrument?` selection — resolved in Task 8. If only those two files error, proceed to Task 8 before final build.

- [ ] **Step 4: Commit (Tasks 6 + 7 + 8 together)**

These three views share the `selection` type; commit them as one unit at the end of Task 8.

---

## Task 8: `PositionsView` + `PositionsChart` use `PositionSelection`

**Files:**
- Modify: `Shared/Views/Positions/PositionsView.swift`
- Modify: `Shared/Views/Positions/PositionsChart.swift`

- [ ] **Step 1: `PositionsView` selection state**

In `Shared/Views/Positions/PositionsView.swift`:

- `@State private var selection: Instrument?` → `@State private var selection: PositionSelection?`.
- `PositionsChart(... selectedInstrument: $selection)` → `selectedSelection: $selection`.
- `PositionsTable(input: input, selection: $selection)` — unchanged call; binding type now matches.
- `.onExitCommand { selection = nil }` and `.onChange(of: input) { selection = nil }` unchanged.

- [ ] **Step 2: `PositionsChart` reads the selection**

In `Shared/Views/Positions/PositionsChart.swift`:

- `@Binding var selectedInstrument: Instrument?` → `@Binding var selectedSelection: PositionSelection?`.
- Header: replace `selectedInstrument` references with `selectedSelection`; `KindBadge(kind: selectedSelection.kind)` and `Text(selectedSelection.displayLabel)`. The clear button sets `self.selectedSelection = nil`.
- `chartBody`: `let mode: PositionsChartMode = (selectedSelection == nil) ? .aggregate : .perInstrument`.
- `visiblePoints`:

```swift
  private var visiblePoints: [HistoricalValueSeries.Point] {
    guard let series = input.historicalValue else { return [] }
    if let selectedSelection {
      return series.series(forInstrumentIds: selectedSelection.instrumentIds)
    }
    return input.showsAggregateChart ? series.totalSeries : []
  }
```

- `chartSnapshot()`: `selectedInstrument.map { "Chart of \($0.displayLabel)" }` → `selectedSelection.map { "Chart of \($0.displayLabel)" }`; the two `selectedInstrument == nil` baseline checks → `selectedSelection == nil`.
- Update the two `#Preview`s: the filtered preview passes `selectedSelection: .constant(...)`. Construct a `PositionSelection` from an `AssetHolding`:

```swift
#Preview("Chart - filtered to instrument") {
  let bhp = AssetHolding(
    id: "ASX:BHP.AX", kind: .stock, name: "BHP", displayLabel: "BHP.AX", decimals: 0,
    chainId: nil, exchange: "ASX", quantity: 100, unitPrice: nil, costBasis: nil,
    value: nil, contributingInstrumentIds: ["ASX:BHP.AX"])
  return PositionsChart(
    input: previewChartInput(days: 30, base: 4_500, step: 25, cost: 4_000),
    range: .constant(.oneMonth),
    selectedSelection: .constant(PositionSelection(holding: bhp))
  )
  .frame(width: 600, height: 320)
  .padding()
}
```

> Note: the filtered preview's series is keyed by `bhp.id` in `previewChartInput` (`perInstrument: [bhp.id: points]`) where `bhp.id` was the stock instrument id `"ASX:BHP.AX"`. The `PositionSelection.instrumentIds` is `["ASX:BHP.AX"]`, so `series(forInstrumentIds:)` resolves it. Good.

- [ ] **Step 3: Build to verify the whole view layer**

Run: `just build-mac 2>&1 | tee .agent-tmp/t8.txt`
Expected: builds clean, no warnings.

- [ ] **Step 4: Commit Tasks 6 + 7 + 8**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Shared/Views/Positions/PositionRow.swift Shared/Views/Positions/PositionsTable.swift Shared/Views/Positions/PositionsView.swift Shared/Views/Positions/PositionsChart.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): render asset rows; generalise chart selection to an asset (#1101)"
```

---

## Task 9: Wire `InvestmentStore` to populate the asset-key map

**Files:**
- Modify: `Features/Investments/InvestmentStore+PositionsInput.swift`
- Modify: `Features/Investments/InvestmentStore.swift` (only if a registry handle must be exposed — verify first)

- [ ] **Step 1: Confirm registry access**

Run: `rg -n "registry|Registry|allCryptoRegistrations|InstrumentRegistry" Features/Investments/InvestmentStore.swift`
Expected: a registry repository reference exists (the store already observes `observeInstrumentRegistryChanges`). Identify the property name (call it `instrumentRegistry`). If only a narrow change-observing seam is held, add a stored `InstrumentRegistryRepository?` injected the same way other repositories are (mirror `transactionRepository`).

- [ ] **Step 2: Build the map and pass it in**

In `Features/Investments/InvestmentStore+PositionsInput.swift`, inside `positionsViewInput(title:range:)`, after `rowsWithCost` is computed and before the final `return`, add:

```swift
    let assetKeys: [String: String]
    if let instrumentRegistry {
      let registrations = (try? await instrumentRegistry.allCryptoRegistrations()) ?? []
      assetKeys = CryptoProviderMapping.assetKeys(from: registrations)
    } else {
      assetKeys = [:]
    }
```

Then pass `assetKeysByInstrumentId: assetKeys` into the final `PositionsViewInput(...)` (the one with `historicalValue: series`). Also pass `assetKeysByInstrumentId: [:]` is unnecessary for the early `guard let transactionRepository` return — leave that branch using the default (it has no crypto rollup context and is a degraded path).

- [ ] **Step 3: Add a store test**

In the relevant existing investment-store test file (find with `rg -l "positionsViewInput" MoolahTests`), add a `@Test` that seeds a `TestBackend` profile with two ETH chains (register `1:native` and `10:native` crypto instruments with coingeckoId `"ethereum"`), records holdings on an account, builds the input via the store, and asserts `input.assetHoldings` contains a single `"ethereum"` row whose quantity equals the sum. Use the existing store-test harness pattern in that file (do not mock the repository — use `TestBackend`).

- [ ] **Step 4: Build + test**

Run: `just test-mac InvestmentStore 2>&1 | tee .agent-tmp/t9.txt` (adjust filter to the store's test class name)
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Features/Investments/ MoolahTests/
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): supply asset-key map from registry in InvestmentStore (#1101)"
```

---

## Task 10: Wire `MultiInstrumentPositionsSplitModifier`

**Files:**
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`

- [ ] **Step 1: Inspect the existing build path**

Run: `sed -n '60,120p' Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`
Identify where `rows` (the `[ValuedPosition]`) and `positionsInput` are built, and how it already obtains `registrationsVersion` (it observes the registry). Locate the registry handle it reads (likely `@Environment(BackendProvider.self)` → `instrumentRegistry`).

- [ ] **Step 2: Build the map and pass it in**

In the function that assigns `positionsInput = PositionsViewInput(...)`, fetch registrations and build the map (the modifier is on the main actor and already async-loads in a `.task`):

```swift
    let registrations = (try? await backend.instrumentRegistry.allCryptoRegistrations()) ?? []
    let assetKeys = CryptoProviderMapping.assetKeys(from: registrations)
```

Pass `assetKeysByInstrumentId: assetKeys` into the `PositionsViewInput(...)` initializer (line ~104). Use the exact `backend`/registry accessor confirmed in Step 1; if the modifier holds only `positions` and a version int without a registry handle, add `@Environment(BackendProvider.self) private var backend` and read `backend.instrumentRegistry`.

- [ ] **Step 3: Build to verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/t10.txt`
Expected: builds clean, no warnings.

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): supply asset-key map in transaction-list positions split (#1101)"
```

---

## Task 11: Full verification + review

**Files:** none (verification only)

- [ ] **Step 1: Full format-check**

Run: `just format-check 2>&1 | tee .agent-tmp/fmt.txt`
Expected: clean. If anything fails, run `just format`, re-inspect the diff, and fix any SwiftLint policy violations by editing code (never re-baseline; see `fixing-format-check`). Re-run until clean.

- [ ] **Step 2: Full build (both platforms)**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-mac.txt` and `just build-ios 2>&1 | tee .agent-tmp/build-ios.txt`
Expected: both succeed, zero warnings (`SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`).

- [ ] **Step 3: Full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test.txt`
Expected: 0 failures. Confirm the new suites ran: `grep -iE "AssetKeyTests|AssetHoldingFoldTests|HistoricalValueSeriesAssetTests" .agent-tmp/test.txt`.

- [ ] **Step 4: Render the holdings preview to confirm the single ETH line**

Use `reviewing-ui-with-preview` (RenderPreview) against `PositionRow`'s `#Preview("rows")` (or a new `PositionsTable` preview seeded with `assetKeysByInstrumentId`) and visually confirm one "ETH 12.95694" row with a "2 chains" secondary line. Attach the snapshot to the PR.

- [ ] **Step 5: Run reviewer agents** (per user instruction)

Run, in order, over the diff: `@instrument-conversion-review` (the fold sums `InstrumentAmount`s — verify no mismatched-instrument trap and that host-currency invariants hold), `@code-review` (naming, thin-view discipline, optional handling, extension organisation), `@ui-review` (`PositionsTable`/`PositionRow`/`PositionsChart` — accessibility labels for the rolled-up row, "N chains" secondary, monospaced digits). Apply all Critical/Important/Minor findings (project policy: fix everything, separate PR only if genuinely out of scope).

- [ ] **Step 6: Clean up temp files**

Run: `rm -f .agent-tmp/t*.txt .agent-tmp/build-*.txt .agent-tmp/test.txt .agent-tmp/fmt.txt`

- [ ] **Step 7: Open the PR**

```bash
git -C .worktrees/cross-chain-asset-aggregation push origin cross-chain-asset-aggregation:cross-chain-asset-aggregation
gh pr create --repo moolah-rocks/moolah-native --base main --head cross-chain-asset-aggregation \
  --title "Aggregate same-asset multi-chain holdings into one line (#1101)" \
  --body "Closes #1101. Presentation-layer rollup: per-chain instruments stay the recorded truth; the holdings surface folds same-asset crypto (by registry price-provider id) into a single AssetHolding row, with chart selection summing the asset's per-chain series. No schema change, no data migration. See plans/2026-06-13-cross-chain-asset-aggregation-design.md."
```

Then enable auto-merge per the `landing-prs` skill.

---

## Self-Review

**Spec coverage:**
- Canonical asset key from `coingeckoId` (fallback chain) → Task 1. ✓
- `AssetHolding` rollup model + partial-failure / mixed-cost / unpriced-standalone / stocks-not-merged / single-passthrough → Tasks 2–3. ✓
- Issue-reproduction numbers (11.36718 + 1.58976 = 12.95694) → Task 3 test. ✓
- No data migration; reconstructed venues left as-is → no migration task (documented in design). ✓
- Summary-row-only display with per-chain context (chain count) → Task 6. ✓
- Chart selection generalised to an asset (not papered over) → Tasks 4, 8. ✓
- Totals unchanged → `PositionsViewInput.totalValue` untouched; verified by full test suite (Task 11). ✓
- Reviewer agents → Task 11 Step 5. ✓

**Placeholder scan:** Tasks 9 & 10 contain verify-then-wire steps (registry handle name, exact line) rather than blind code because the store/modifier's registry accessor must be confirmed at the call site; the grep command and the exact code to insert are both given, so there is no unresolved placeholder — the engineer confirms one identifier and proceeds. Acceptable.

**Type consistency:** `assetKey` (Task 1), `AssetHolding.fold(_:assetKeys:)` (Task 3), `series(forInstrumentIds:)` (Task 4), `assetKeysByInstrumentId` + `assetHoldings` (Task 5), `PositionSelection(holding:)` + `selectedSelection` (Tasks 5, 8) are used consistently across all later tasks. ✓
