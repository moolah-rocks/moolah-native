# Cross-chain Asset Aggregation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Roll same-asset-across-chains crypto holdings (e.g. mainnet ETH `1:native` + Optimism ETH `10:native`) into a single asset line in the holdings surface, while every upstream layer (legs, sync, gas, cost basis, pricing) stays strictly per-chain.

**Architecture:** A presentation-layer fold. A canonical `assetKey` (the crypto instrument's price-provider id, sourced from the registry) groups per-chain `ValuedPosition`s into a unified `AssetHolding` display row. The fold is pure and unit-tested, seeded with an explicit host currency. `AssetHolding` replaces `ValuedPosition` as the row model rendered by `PositionsTable`/`PositionRow`; a single-contributor holding renders identically to today. Chart selection generalises from a single `Instrument` to a `PositionSelection` carrying the contributing instrument ids, and the chart sums their historical series. No schema change, no data migration.

**Tech Stack:** Swift, SwiftUI, Swift Testing (`@Test`/`#expect`), GRDB-backed `TestBackend`. Build/test/format via `just`.

**Design doc:** `plans/2026-06-13-cross-chain-asset-aggregation-design.md`
**Review findings applied:** `plans/REVIEW_FINDINGS.md` (delete before PR).

---

## File Structure

**New files**
- `Domain/Models/AssetHolding.swift` — unified display-row model + computed display surface.
- `Domain/Models/AssetHolding+Fold.swift` — pure fold `([ValuedPosition], assetKeys, hostCurrency) → [AssetHolding]`.
- `Domain/Models/QuantityFormatting.swift` — shared quantity-formatting used by both `ValuedPosition` and `AssetHolding` (eliminates duplication).
- `Domain/Models/PositionSelection.swift` — selection value type shared by table + chart.
- `MoolahTests/Domain/AssetKeyTests.swift`
- `MoolahTests/Domain/AssetHoldingFoldTests.swift`
- `MoolahTests/Domain/HistoricalValueSeriesAssetTests.swift`

**Modified files**
- `Domain/Models/CryptoProviderMapping.swift` — add `assetKey` + static `assetKeys(from:)` map builder.
- `Domain/Models/ValuedPosition+Display.swift` — delegate `quantityFormatted`/`quantityCaption` to `QuantityFormatting`.
- `Domain/Models/HistoricalValueSeries.swift` — add `series(forInstrumentIds:)`.
- `Domain/Models/PositionsViewInput.swift` — add `assetKeysByInstrumentId` (default `[:]`); add `assetHoldings` computed fold entry point.
- `Domain/Repositories/BackendProvider.swift` — expose `instrumentRegistry` (default-nil).
- `Backends/CloudKit/CloudKitBackend.swift` — surface its existing `instrumentRegistry` through the protocol.
- `Shared/Views/Positions/PositionsTable.swift` — render `[AssetHolding]`; `InstrumentGroup` over holdings; `PositionSelection` binding.
- `Shared/Views/Positions/PositionRow.swift` — `row: AssetHolding`; multi-chain secondary label + accessibility.
- `Shared/Views/Positions/PositionsView.swift` — `@State selection: PositionSelection?`.
- `Shared/Views/Positions/PositionsChart.swift` — `@Binding selectedSelection: PositionSelection?`; sum series.
- `Features/Investments/InvestmentStore.swift` — inject `instrumentRegistry`; cache asset-key map in `loadAllData`.
- `Features/Investments/InvestmentStore+PositionsInput.swift` — pass cached map into the input.
- `App/ProfileSession+Factories.swift` — pass `instrumentRegistry` when building `InvestmentStore`.
- `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift` — read registry via `@Environment(BackendProvider.self)`; build + pass map.

---

## Task 1: Asset key derivation + map builder

**Files:**
- Modify: `Domain/Models/CryptoProviderMapping.swift`
- Test: `MoolahTests/Domain/AssetKeyTests.swift`

- [ ] **Step 1: Write the failing tests**

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

  @Test func fallsBackToCryptocompareWhenCoingeckoAbsent() {
    let m = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: nil,
      cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")
    #expect(m.assetKey == "ETH")
  }

  @Test func fallsBackToBinanceWhenCryptocompareAlsoAbsent() {
    let m = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: "ETHUSDT")
    #expect(m.assetKey == "ETHUSDT")
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

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac AssetKeyTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: compile failure — `assetKey` / `assetKeys(from:)` not defined.

- [ ] **Step 3: Implement**

Append inside the struct in `Domain/Models/CryptoProviderMapping.swift` (after `hasProviderMapping`):

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
    registrations.reduce(into: [String: String]()) { map, reg in
      map[reg.instrument.id] = reg.mapping.assetKey
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac AssetKeyTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Domain/Models/CryptoProviderMapping.swift MoolahTests/Domain/AssetKeyTests.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): canonical cross-chain asset key + map builder (#1101)"
```

---

## Task 2: Shared quantity formatting + `AssetHolding` model

**Files:**
- Create: `Domain/Models/QuantityFormatting.swift`
- Modify: `Domain/Models/ValuedPosition+Display.swift`
- Create: `Domain/Models/AssetHolding.swift`

No standalone unit test (pure formatting covered indirectly by Task 3 + the existing `ValuedPosition` display tests). Verified by build.

- [ ] **Step 1: Extract the shared formatter**

Create `Domain/Models/QuantityFormatting.swift`:

```swift
import Foundation

/// Single source of truth for the human-friendly quantity string shown in the
/// holdings surface, shared by `ValuedPosition` and `AssetHolding` so the
/// formatting rules live in exactly one place.
enum QuantityFormatting {
  /// - `.fiatCurrency` → currency-formatted using `currencyCode`.
  /// - `.stock` → decimal up to `decimals` places, no suffix.
  /// - `.cryptoToken` → decimal (capped at 8 places) + `displayLabel`.
  static func formatted(
    kind: Instrument.Kind, quantity: Decimal, decimals: Int,
    displayLabel: String, currencyCode: String?
  ) -> String {
    switch kind {
    case .fiatCurrency:
      // Fiat rows are always single-instrument; `currencyCode` is its ISO code.
      guard let currencyCode else { return "\(quantity)" }
      return InstrumentAmount(
        quantity: quantity, instrument: .fiat(code: currencyCode)
      ).formatted
    case .stock:
      return decimalString(quantity, maxFraction: decimals)
    case .cryptoToken:
      return "\(decimalString(quantity, maxFraction: min(decimals, 8))) \(displayLabel)"
    }
  }

  /// Caption variant: adds "shares" for stock; identical otherwise.
  static func caption(
    kind: Instrument.Kind, quantity: Decimal, decimals: Int,
    displayLabel: String, currencyCode: String?
  ) -> String {
    let base = formatted(
      kind: kind, quantity: quantity, decimals: decimals,
      displayLabel: displayLabel, currencyCode: currencyCode)
    return kind == .stock ? "\(base) shares" : base
  }

  private static func decimalString(_ value: Decimal, maxFraction: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.minimumFractionDigits = 0
    formatter.maximumFractionDigits = maxFraction
    return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
  }
}
```

> Note: the fiat branch routes through `InstrumentAmount(...).formatted` exactly as `ValuedPosition+Display.swift` does today, so fiat output is byte-identical. `currencyCode` is the instrument's ISO id; constructing `.fiat(code:)` here is the single, documented place that does so — not a per-call reconstruction scattered across types.

- [ ] **Step 2: Delegate `ValuedPosition+Display` to the shared formatter**

In `Domain/Models/ValuedPosition+Display.swift`, replace the bodies of `quantityFormatted` and `quantityCaption`:

```swift
  var quantityFormatted: String {
    QuantityFormatting.formatted(
      kind: instrument.kind, quantity: quantity, decimals: instrument.decimals,
      displayLabel: instrument.displayLabel,
      currencyCode: instrument.kind == .fiatCurrency ? instrument.id : nil)
  }

  var quantityCaption: String {
    QuantityFormatting.caption(
      kind: instrument.kind, quantity: quantity, decimals: instrument.decimals,
      displayLabel: instrument.displayLabel,
      currencyCode: instrument.kind == .fiatCurrency ? instrument.id : nil)
  }
```

Leave `signedFormatted` and `GainLossPercentDisplay` untouched.

- [ ] **Step 3: Create the `AssetHolding` model**

Create `Domain/Models/AssetHolding.swift`:

```swift
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
      kind: kind, quantity: quantity, decimals: decimals,
      displayLabel: displayLabel, currencyCode: currencyCode)
  }

  var quantityCaption: String {
    QuantityFormatting.caption(
      kind: kind, quantity: quantity, decimals: decimals,
      displayLabel: displayLabel, currencyCode: currencyCode)
  }

  /// A selection value for this row, used to drive the chart filter.
  var positionSelection: PositionSelection {
    PositionSelection(
      id: id, kind: kind, displayLabel: displayLabel,
      instrumentIds: contributingInstrumentIds)
  }
}

// MARK: - Sortable accessors (mirror ValuedPosition for Table columns)

extension AssetHolding {
  var unitPriceQuantity: Decimal { unitPrice?.quantity ?? 0 }
  var costBasisQuantity: Decimal { costBasis?.quantity ?? 0 }
  var valueQuantity: Decimal { value?.quantity ?? 0 }
  var gainQuantity: Decimal { gainLoss?.quantity ?? 0 }
}
```

> `positionSelection` references `PositionSelection`, created in Task 5. Tasks 2 and 5 must both be present before this file compiles — do Task 5 in the same working session, or temporarily stub `PositionSelection`. Recommended order: Task 5 before final build of Task 2 (they are committed separately but compiled together).

- [ ] **Step 4: Build to verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/t2.txt`
Expected: builds after Task 5's `PositionSelection` exists. If building standalone errors only on `PositionSelection`, proceed to Task 5 then rebuild.

- [ ] **Step 5: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Domain/Models/QuantityFormatting.swift Domain/Models/ValuedPosition+Display.swift Domain/Models/AssetHolding.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): AssetHolding model + shared quantity formatting (#1101)"
```

---

## Task 3: The fold — `[ValuedPosition] → [AssetHolding]`

**Files:**
- Create: `Domain/Models/AssetHolding+Fold.swift`
- Test: `MoolahTests/Domain/AssetHoldingFoldTests.swift`

- [ ] **Step 1: Write the failing tests**

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
  private let ethKeys = ["1:native": "ethereum", "10:native": "ethereum"]

  @Test func mergesEthAcrossChains() {
    let rows = [
      ValuedPosition(instrument: eth(1), quantity: Decimal(string: "11.36718")!,
        unitPrice: amt(4000), costBasis: amt(30000), value: amt(45468)),
      ValuedPosition(instrument: eth(10), quantity: Decimal(string: "1.58976")!,
        unitPrice: amt(4000), costBasis: amt(5000), value: amt(6359)),
    ]
    let holdings = AssetHolding.fold(rows, assetKeys: ethKeys, hostCurrency: aud)
    #expect(holdings.count == 1)
    let h = holdings[0]
    #expect(h.id == "ethereum")
    #expect(h.quantity == Decimal(string: "12.95694")!)
    #expect(h.value == amt(51827))
    #expect(h.costBasis == amt(35000))
    #expect(h.chainCount == 2)
    #expect(h.chainId == nil)  // multi-chain
    #expect(Set(h.contributingInstrumentIds) == ["1:native", "10:native"])
  }

  @Test func partialConversionFailureMakesValueNil() {
    let rows = [
      ValuedPosition(instrument: eth(1), quantity: 1, unitPrice: amt(4000), costBasis: amt(3000), value: amt(4000)),
      ValuedPosition(instrument: eth(10), quantity: 2, unitPrice: nil, costBasis: nil, value: nil),
    ]
    let h = AssetHolding.fold(rows, assetKeys: ethKeys, hostCurrency: aud)[0]
    #expect(h.quantity == 3)        // quantity always known
    #expect(h.value == nil)         // partial → unavailable
    #expect(h.costBasis == nil)     // one contributor lacks cost → undefined
    #expect(h.gainLoss == nil)
  }

  @Test func costBasisIndependentOfValue() {
    // value fails on one chain, but BOTH have a cost basis → costBasis sums,
    // value is nil, gainLoss is nil (guarded by the missing value).
    let rows = [
      ValuedPosition(instrument: eth(1), quantity: 1, unitPrice: amt(4000), costBasis: amt(3000), value: amt(4000)),
      ValuedPosition(instrument: eth(10), quantity: 2, unitPrice: nil, costBasis: amt(6000), value: nil),
    ]
    let h = AssetHolding.fold(rows, assetKeys: ethKeys, hostCurrency: aud)[0]
    #expect(h.value == nil)
    #expect(h.costBasis == amt(9000))
    #expect(h.gainLoss == nil)
  }

  @Test func unpricedTokenStandsAlone() {
    let token = Instrument.crypto(chainId: 1, contractAddress: "0xabc", symbol: "FOO", name: "Foo", decimals: 18)
    let rows = [ValuedPosition(instrument: token, quantity: 5, unitPrice: nil, costBasis: nil, value: nil)]
    let h = AssetHolding.fold(rows, assetKeys: [:], hostCurrency: aud)  // no key → stands alone
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
    let h = AssetHolding.fold(rows, assetKeys: [:], hostCurrency: aud)
    #expect(h.count == 2)
    #expect(Set(h.map(\.id)) == ["ASX:BHP.AX", "AUD"])
    #expect(h.first(where: { $0.id == "AUD" })?.currencyCode == "AUD")
  }

  @Test func singleChainPassthroughKeepsChainId() {
    let rows = [ValuedPosition(instrument: eth(1), quantity: 1, unitPrice: amt(4000), costBasis: amt(3000), value: amt(4000))]
    let h = AssetHolding.fold(rows, assetKeys: ["1:native": "ethereum"], hostCurrency: aud)[0]
    #expect(h.chainId == 1)
    #expect(h.chainCount == 1)
    #expect(h.id == "ethereum")
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

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
      let k = key(for: position)
      if groups[k] == nil { order.append(k) }
      groups[k, default: []].append(position)
    }

    return order.compactMap { k -> AssetHolding? in
      guard let group = groups[k] else { return nil }
      return Self.merge(group, key: k, hostCurrency: hostCurrency)
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
      guard let acc = value, let v = row.value else { value = nil; break }
      value = acc + v
    }
    // Cost basis is independent of value: defined iff EVERY contributor has one.
    var costBasis: InstrumentAmount? = .zero(instrument: hostCurrency)
    for row in group {
      guard let acc = costBasis, let c = row.costBasis else { costBasis = nil; break }
      costBasis = acc + c
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac AssetHoldingFoldTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: PASS (7 tests).

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

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Domain/HistoricalValueSeriesAssetTests.swift`:

```swift
import Foundation
import Testing

@testable import Moolah

@Suite struct HistoricalValueSeriesAssetTests {
  private func day(_ d: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(d) * 86_400) }
  private func point(_ d: Int, _ v: Decimal, _ c: Decimal) -> HistoricalValueSeries.Point {
    .init(date: day(d), value: v, cost: c, contributions: nil)
  }

  @Test func sumsContributingSeriesByDate() {
    let series = HistoricalValueSeries(
      hostCurrency: .AUD, total: [],
      perInstrument: [
        "1:native": [point(1, 100, 80), point(2, 110, 80)],
        "10:native": [point(1, 20, 15), point(2, 25, 15)],
      ])
    let summed = series.series(forInstrumentIds: ["1:native", "10:native"])
    #expect(summed.count == 2)
    #expect(summed[0].date == day(1))
    #expect(summed[0].value == 120)
    #expect(summed[0].cost == 95)
    #expect(summed[1].value == 135)
  }

  @Test func dropsDatesNotPresentInEveryContributor() {
    // "1:native" has days 1,2,3; "10:native" has only day 2. Intersection = day 2.
    let series = HistoricalValueSeries(
      hostCurrency: .AUD, total: [],
      perInstrument: [
        "1:native": [point(1, 100, 80), point(2, 110, 80), point(3, 120, 80)],
        "10:native": [point(2, 25, 15)],
      ])
    let summed = series.series(forInstrumentIds: ["1:native", "10:native"])
    #expect(summed.count == 1)
    #expect(summed[0].date == day(2))
    #expect(summed[0].value == 135)
  }

  @Test func singleIdMatchesSeriesForInstrument() {
    let points = [point(1, 100, 80)]
    let series = HistoricalValueSeries(hostCurrency: .AUD, total: [], perInstrument: ["1:native": points])
    #expect(series.series(forInstrumentIds: ["1:native"]) == points)
  }

  @Test func unknownIdsYieldEmpty() {
    let series = HistoricalValueSeries(hostCurrency: .AUD, total: [], perInstrument: [:])
    #expect(series.series(forInstrumentIds: ["nope"]).isEmpty)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac HistoricalValueSeriesAssetTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: compile failure — `series(forInstrumentIds:)` not defined.

- [ ] **Step 3: Implement**

Add to `Domain/Models/HistoricalValueSeries.swift` (after `series(for:)`):

```swift
  /// Sums the per-instrument series for a set of instrument ids by date —
  /// used when an aggregated asset row (e.g. ETH across chains) is selected.
  /// A date is emitted only if it is present in *every* contributing series
  /// (anchored on the first series, which is correct because a date missing
  /// from the first is by definition not in all). This preserves the "never
  /// display a partial aggregate" rule. `value` and `cost` sum; `contributions`
  /// is left `nil` (per-instrument series carry none).
  func series(forInstrumentIds ids: [String]) -> [Point] {
    let seriesList = ids.compactMap { perInstrument[$0] }
    guard let firstSeries = seriesList.first else { return [] }
    if seriesList.count == 1 { return firstSeries }

    let byDate: [[Date: Point]] = seriesList.map { series in
      Dictionary(series.map { ($0.date, $0) }, uniquingKeysWith: { a, _ in a })
    }
    return firstSeries.compactMap { anchor -> Point? in
      var value = Decimal(0)
      var cost = Decimal(0)
      for table in byDate {
        guard let p = table[anchor.date] else { return nil }  // partial coverage → drop
        value += p.value
        cost += p.cost
      }
      return Point(date: anchor.date, value: value, cost: cost, contributions: nil)
    }
  }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac HistoricalValueSeriesAssetTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: PASS (4 tests).

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

- [ ] **Step 1: Write the failing tests**

Add to the existing suite in `MoolahTests/Domain/PositionsViewInputTests.swift`:

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

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac PositionsViewInputTests 2>&1 | tee .agent-tmp/t5.txt`
Expected: compile failure — extra argument `assetKeysByInstrumentId` / `assetHoldings` undefined.

- [ ] **Step 3: Create `PositionSelection`**

Create `Domain/Models/PositionSelection.swift`:

```swift
import Foundation

/// A selected holdings row, shared by the table (sets it) and the chart
/// (reads it to filter). A plain data carrier — carries enough to render the
/// filter chip and to sum the contributing instruments' historical series,
/// without re-deriving from the registry. Construct via
/// `AssetHolding.positionSelection`.
struct PositionSelection: Sendable, Hashable, Identifiable {
  /// The row id — an `assetKey` for a crypto rollup, otherwise an instrument id.
  let id: String
  let kind: Instrument.Kind
  let displayLabel: String
  /// The per-chain instrument ids this selection covers (1+).
  let instrumentIds: [String]
}
```

- [ ] **Step 4: Add the field + fold entry point to `PositionsViewInput`**

In `Domain/Models/PositionsViewInput.swift`, add the stored property after `historicalValue`:

```swift
  /// `[instrumentId: assetKey]` used to roll same-asset-across-chains crypto
  /// positions into a single holdings row. Empty (the default) means no
  /// rollup — every position stands alone, preserving pre-aggregation
  /// behaviour at call sites that don't supply it.
  let assetKeysByInstrumentId: [String: String]
```

Add the parameter to the designated initializer after `historicalValue` (default keeps existing call sites compiling):

```swift
    historicalValue: HistoricalValueSeries?,
    assetKeysByInstrumentId: [String: String] = [:],
    performance: AccountPerformance? = nil,
```

…and assign in the body: `self.assetKeysByInstrumentId = assetKeysByInstrumentId`.

Add the computed fold entry point (after `rendersNothing`):

```swift
  /// The positions folded into asset rows for display. Crypto positions
  /// sharing an `assetKey` (per `assetKeysByInstrumentId`) merge into one row;
  /// stocks, fiat, and unmapped crypto stand alone.
  var assetHoldings: [AssetHolding] {
    AssetHolding.fold(positions, assetKeys: assetKeysByInstrumentId, hostCurrency: hostCurrency)
  }
```

> `PositionsViewInput`'s `Hashable`/`Sendable` are synthesised; `[String: String]` is both, so synthesis stays valid. `assetHoldings` is computed, not stored, so it is not part of equality.

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test-mac PositionsViewInputTests AssetHoldingFoldTests 2>&1 | tee .agent-tmp/t5.txt`
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

No standalone unit test (view); covered by build + Task 12 snapshot.

- [ ] **Step 1: Change the row type, secondary label, and accessibility**

In `Shared/Views/Positions/PositionRow.swift`:

- `let row: ValuedPosition` → `let row: AssetHolding`.
- Replace `row.instrument.kind` → `row.kind`, `row.instrument.name` → `row.name` (in `leadingColumn`).
- Replace `secondaryIdentifier`:

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

- `row.quantityCaption`, `row.value`, `row.gainLoss`, `row.gainLossPercent` exist on `AssetHolding` (Task 2) — unchanged.
- Update `accessibilityLabel` to use `row.name` and add the multi-chain phrasing as the first detail:

```swift
  private var accessibilityLabel: String {
    var parts: [String] = [row.name]
    if row.chainCount > 1 { parts.append("across \(row.chainCount) chains") }
    parts.append(row.quantityCaption)
    if let value = row.value {
      parts.append("valued at \(value.formatted)")
    } else {
      parts.append("value unavailable")
    }
    if let gain = row.gainLoss {
      let pctSuffix = GainLossPercentDisplay.accessibilitySuffix(row.gainLossPercent)
      if gain.isNegative {
        parts.append("loss of \((-gain).formatted)\(pctSuffix)")
      } else if gain.isZero {
        parts.append(pctSuffix.isEmpty ? "no change" : "no change\(pctSuffix)")
      } else {
        parts.append("gain of \(gain.formatted)\(pctSuffix)")
      }
    }
    return parts.joined(separator: ", ")
  }
```

- Replace `previewRows()` to return `[AssetHolding]`:

```swift
private func previewRows() -> [AssetHolding] {
  let aud = Instrument.AUD
  func amt(_ q: Decimal) -> InstrumentAmount { InstrumentAmount(quantity: q, instrument: aud) }
  return [
    AssetHolding(
      id: "ASX:BHP.AX", kind: .stock, name: "BHP", displayLabel: "BHP.AX", decimals: 0,
      currencyCode: nil, chainId: nil, exchange: "ASX", quantity: 250, unitPrice: amt(45.30),
      costBasis: amt(10_125), value: amt(11_325), contributingInstrumentIds: ["ASX:BHP.AX"]),
    AssetHolding(
      id: "ethereum", kind: .cryptoToken, name: "Ethereum", displayLabel: "ETH", decimals: 18,
      currencyCode: nil, chainId: nil, exchange: nil, quantity: Decimal(string: "12.95694")!,
      unitPrice: amt(4_000), costBasis: amt(35_000), value: amt(51_827),
      contributingInstrumentIds: ["1:native", "10:native"]),
    AssetHolding(
      id: "AUD", kind: .fiatCurrency, name: "AUD", displayLabel: "$", decimals: 2,
      currencyCode: "AUD", chainId: nil, exchange: nil, quantity: 1_520, unitPrice: nil,
      costBasis: nil, value: amt(1_520), contributingInstrumentIds: ["AUD"]),
  ]
}
```

`#Preview("rows")` keeps `PositionRow(row: row)` (now an `AssetHolding`).

- [ ] **Step 2: Build (with Task 7) — see note**

`PositionsTable` still references `ValuedPosition` rows until Task 7. Build clean after Task 7. Commit Tasks 6+7+8 together at the end of Task 8.

---

## Task 7: `PositionsTable` renders `[AssetHolding]` + `PositionSelection`

**Files:**
- Modify: `Shared/Views/Positions/PositionsTable.swift`

- [ ] **Step 1: Selection binding + row source**

In `Shared/Views/Positions/PositionsTable.swift`:

- `@Binding var selection: Instrument?` → `@Binding var selection: PositionSelection?`.
- Sort comparator generic:

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

- `wideLayout`: `sortedRows` is now `[AssetHolding]`. Column key paths: `\.instrument.name` → `\.name`; `\.quantity` stays; the value closures use `row.quantityFormatted`, `row.unitPrice`, `row.costBasis`, `row.value`, `row.gainLoss`, `row.gainLossPercent`, and the sortable accessors — all present on `AssetHolding`.
- `instrumentCell(for row: AssetHolding)`: `row.instrument.kind` → `row.kind`; `row.instrument.name` → `row.name`; `row.instrument.exchange` → `row.exchange`.

- [ ] **Step 2: Selection bindings + grouping helper**

Replace both selection bindings to resolve against `holdings` and emit a `PositionSelection`:

```swift
  private var rowSelectionBinding: Binding<Set<String>> {
    Binding(
      get: { selection.map { [$0.id] } ?? [] },
      set: { ids in
        if let id = ids.first, let holding = holdings.first(where: { $0.id == id }) {
          selection = (selection?.id == id) ? nil : holding.positionSelection
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
          selection = (selection?.id == id) ? nil : holding.positionSelection
        } else {
          selection = nil
        }
      })
  }
```

- `instrumentLabel(for row: AssetHolding)`: use `row.kind`, `row.name`, `row.exchange`.
- `InstrumentGroup`: change stored `rows` to `[AssetHolding]`; `from(_ rows: [AssetHolding])` filters on `$0.kind` (was `$0.instrument.kind`).
- The `#Preview` helper `mixedPositionsInput()` still passes `ValuedPosition`s into `PositionsViewInput.positions` (correct — the input holds `ValuedPosition`s and folds internally). `selection: .constant(nil)` compiles against the new `PositionSelection?` type.

- [ ] **Step 3: Build (with Task 8) — see note**

`PositionsView`/`PositionsChart` still pass `Instrument?` until Task 8. If only those two files error, proceed to Task 8.

---

## Task 8: `PositionsView` + `PositionsChart` use `PositionSelection`

**Files:**
- Modify: `Shared/Views/Positions/PositionsView.swift`
- Modify: `Shared/Views/Positions/PositionsChart.swift`

- [ ] **Step 1: `PositionsView` selection state**

In `Shared/Views/Positions/PositionsView.swift`:

- `@State private var selection: Instrument?` → `@State private var selection: PositionSelection?`.
- `PositionsChart(... selectedInstrument: $selection)` → `selectedSelection: $selection`.
- `PositionsTable(input: input, selection: $selection)` — unchanged call (binding type now matches).
- `.onExitCommand`/`.onChange(of: input)` setting `selection = nil` — unchanged.

- [ ] **Step 2: `PositionsChart` reads the selection**

In `Shared/Views/Positions/PositionsChart.swift`:

- `@Binding var selectedInstrument: Instrument?` → `@Binding var selectedSelection: PositionSelection?`.
- `header`: replace `selectedInstrument` with `selectedSelection`; `KindBadge(kind: selectedSelection.kind)`, `Text(selectedSelection.displayLabel)`, clear button sets `self.selectedSelection = nil`.
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

- `chartSnapshot()` — update **all three** `selectedInstrument` references:
  1. `let title = selectedInstrument.map { "Chart of \($0.displayLabel)" } ?? ...` → `selectedSelection.map { ... }`.
  2. `let baseline: Decimal? = selectedInstrument == nil ? point.contributions : point.cost` → `selectedSelection == nil ? ...`.
  3. `let baselineName = selectedInstrument == nil ? "Invested amount" : "Cost basis"` → `selectedSelection == nil ? ...`.
- Update the two `#Preview`s. The filtered preview builds a `PositionSelection` from an `AssetHolding`:

```swift
#Preview("Chart - filtered to instrument") {
  let bhp = AssetHolding(
    id: "ASX:BHP.AX", kind: .stock, name: "BHP", displayLabel: "BHP.AX", decimals: 0,
    currencyCode: nil, chainId: nil, exchange: "ASX", quantity: 100, unitPrice: nil,
    costBasis: nil, value: nil, contributingInstrumentIds: ["ASX:BHP.AX"])
  return PositionsChart(
    input: previewChartInput(days: 30, base: 4_500, step: 25, cost: 4_000),
    range: .constant(.oneMonth),
    selectedSelection: .constant(bhp.positionSelection)
  )
  .frame(width: 600, height: 320)
  .padding()
}
```

> `previewChartInput` keys `perInstrument` by `bhp.id == "ASX:BHP.AX"`; `bhp.positionSelection.instrumentIds == ["ASX:BHP.AX"]`, so `series(forInstrumentIds:)` resolves it.

- [ ] **Step 3: Build the whole view layer**

Run: `just build-mac 2>&1 | tee .agent-tmp/t8.txt`
Expected: builds clean, no warnings.

- [ ] **Step 4: Commit Tasks 6 + 7 + 8**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Shared/Views/Positions/PositionRow.swift Shared/Views/Positions/PositionsTable.swift Shared/Views/Positions/PositionsView.swift Shared/Views/Positions/PositionsChart.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): render asset rows; generalise chart selection to an asset (#1101)"
```

---

## Task 9: Expose `instrumentRegistry` on `BackendProvider`

**Files:**
- Modify: `Domain/Repositories/BackendProvider.swift`
- Modify: `Backends/CloudKit/CloudKitBackend.swift`

`CloudKitBackend` already holds `let instrumentRegistry: any InstrumentRegistryRepository` but only surfaces the narrow `instrumentChangeObserver`. Features must talk to the registry through `BackendProvider` (never import `Backends/`).

- [ ] **Step 1: Add the protocol member with a default**

In `Domain/Repositories/BackendProvider.swift`, add to the protocol (near `instrumentChangeObserver`):

```swift
  /// The full instrument registry, when the backend has one. Mirrors the
  /// narrow `instrumentChangeObserver` seam but exposes read access to crypto
  /// registrations (for the holdings asset-key rollup). `nil` for backends
  /// without a registry (e.g. preview/empty backends).
  var instrumentRegistry: (any InstrumentRegistryRepository)? { get }
```

In the existing default-implementation extension (the one that defaults `instrumentChangeObserver` to `nil`), add:

```swift
  var instrumentRegistry: (any InstrumentRegistryRepository)? { nil }
```

- [ ] **Step 2: Override on `CloudKitBackend`**

`CloudKitBackend` already stores `let instrumentRegistry: any InstrumentRegistryRepository`. The protocol requires an *optional*. Add a computed bridge (rename the stored property is risky — keep it, add the protocol witness):

```swift
  // Protocol witness for BackendProvider.instrumentRegistry (optional).
  var instrumentRegistryProvider: (any InstrumentRegistryRepository)? { instrumentRegistry }
```

…then in the `BackendProvider` conformance, expose it. Simplest: rename the protocol requirement to read the stored non-optional directly by adding this computed property that satisfies the optional requirement:

```swift
  var instrumentRegistry: (any InstrumentRegistryRepository)? { grdbInstruments }
```

**Conflict check:** `CloudKitBackend` already declares `let instrumentRegistry: any InstrumentRegistryRepository` (non-optional, line ~19) AND `let grdbInstruments: GRDBInstrumentRegistryRepository` (line ~38). A second `var instrumentRegistry` (optional) collides with the stored `let`. Resolve by renaming the stored constant to `instrumentRegistryRepository` (and updating its in-file references at lines ~29/152) and adding the optional protocol witness:

```swift
  // store (renamed):
  let instrumentRegistryRepository: any InstrumentRegistryRepository
  // protocol witness:
  var instrumentRegistry: (any InstrumentRegistryRepository)? { instrumentRegistryRepository }
```

Verify in-file references first: `rg -n "instrumentRegistry\b" Backends/CloudKit/CloudKitBackend.swift` and update each non-protocol use to `instrumentRegistryRepository`. (The `instrumentChangeObserver` computed property that returns the registry must also point at the renamed constant.)

- [ ] **Step 3: Build to verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/t9.txt`
Expected: builds clean. `TestBackend` (a `CloudKitBackend`) inherits the override automatically.

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Domain/Repositories/BackendProvider.swift Backends/CloudKit/CloudKitBackend.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(backend): expose instrumentRegistry on BackendProvider (#1101)"
```

---

## Task 10: Inject the registry into `InvestmentStore` and supply the asset-key map

**Files:**
- Modify: `Features/Investments/InvestmentStore.swift`
- Modify: `Features/Investments/InvestmentStore+PositionsInput.swift`
- Modify: `App/ProfileSession+Factories.swift`
- Test: existing investment-store test file (find with `rg -l "positionsViewInput\|InvestmentStore(" MoolahTests`)

- [ ] **Step 1: Add the dependency + cached map to the store**

In `Features/Investments/InvestmentStore.swift`:

- Add a stored dependency next to `instrumentChanges`:

```swift
  private let instrumentRegistry: (any InstrumentRegistryRepository)?
```

- Add a cached map (recomputed on load and on registry change):

```swift
  /// `[instrumentId: assetKey]` for the holdings rollup, refreshed by
  /// `loadAllData`. Empty until first load, or if the registry is absent /
  /// errored (the surface then shows per-chain rows — a safe degradation).
  private(set) var assetKeysByInstrumentId: [String: String] = [:]
```

- Add `instrumentRegistry` to `init` (default `nil`) and assign it:

```swift
    instrumentChanges: (any InstrumentChangeObserving)? = nil,
    instrumentRegistry: (any InstrumentRegistryRepository)? = nil
  ) {
    ...
    self.instrumentChanges = instrumentChanges
    self.instrumentRegistry = instrumentRegistry
```

- Add a helper to refresh the map, mirroring the existing `fetchAllTransactions` error style (log + fall back, re-throw cancellation):

```swift
  private func refreshAssetKeys() async {
    guard let instrumentRegistry else { assetKeysByInstrumentId = [:]; return }
    do {
      let registrations = try await instrumentRegistry.allCryptoRegistrations()
      try Task.checkCancellation()
      assetKeysByInstrumentId = CryptoProviderMapping.assetKeys(from: registrations)
    } catch is CancellationError {
      // leave the previous map intact on cancellation
    } catch {
      logger.warning(
        "allCryptoRegistrations failed, asset rollup disabled: \(error.localizedDescription, privacy: .public)")
      assetKeysByInstrumentId = [:]
    }
  }
```

- Call `await refreshAssetKeys()` inside `loadAllData(...)` (alongside the other loads). Also call it from `observeInstrumentRegistryChanges` so a registry edit refreshes the map.

- [ ] **Step 2: Use the cached map in the input**

In `Features/Investments/InvestmentStore+PositionsInput.swift`, pass `assetKeysByInstrumentId: assetKeysByInstrumentId` into the final `PositionsViewInput(...)` (the one with `historicalValue: series`). Leave the early degraded `guard let transactionRepository` return on the default `[:]`.

- [ ] **Step 3: Wire the construction site**

In `App/ProfileSession+Factories.swift` (~line 349, `let investment = InvestmentStore(`), pass the registry from the backend (the same place `instrumentChanges` is sourced):

```swift
      instrumentChanges: backend.instrumentChangeObserver,
      instrumentRegistry: backend.instrumentRegistry)
```

Confirm the local is named `backend` (or adjust); the factory already references the backend to build `instrumentChanges`.

- [ ] **Step 4: Add a store test (TestBackend, not a mock)**

In the existing investment-store test file, add a `@Test` that:
1. Builds a `TestBackend`, registers `1:native` and `10:native` crypto instruments via `backend.instrumentRegistry.registerCrypto(_:mapping:)` both with `coingeckoId: "ethereum"`.
2. Records holdings on a crypto account so both per-chain ETH positions exist.
3. Constructs the `InvestmentStore` with `instrumentRegistry: backend.instrumentRegistry`, runs `loadAndBuildPositionsInput(...)`.
4. Asserts the returned `input.assetHoldings` contains exactly one row with `id == "ethereum"` whose `quantity` equals the sum.

Follow the existing harness pattern in that file (do not mock the repository).

- [ ] **Step 5: Build + test**

Run: `just test-mac InvestmentStore 2>&1 | tee .agent-tmp/t10.txt` (adjust filter to the store's test class)
Expected: PASS, no warnings.

- [ ] **Step 6: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Features/Investments/ App/ProfileSession+Factories.swift MoolahTests/
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): supply asset-key map from registry in InvestmentStore (#1101)"
```

---

## Task 11: Wire `MultiInstrumentPositionsSplitModifier`

**Files:**
- Modify: `Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`

- [ ] **Step 1: Inspect the existing build path**

Run: `rg -n "PositionsViewInput\(|valuatePositions|Task.isCancelled|conversionService|@Environment" Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift`
Identify where `positionsInput` is assigned and where the existing `guard !Task.isCancelled` lives in `valuatePositions()`.

- [ ] **Step 2: Read the registry via the environment + build the map**

Add to the modifier struct:

```swift
  @Environment(BackendProvider.self) private var backend
```

In `valuatePositions()`, after the existing valuation and **before** building `positionsInput`, fetch the map with the same logged-degradation style and a cancellation re-check:

```swift
    var assetKeys: [String: String] = [:]
    if let registry = backend.instrumentRegistry {
      do {
        let registrations = try await registry.allCryptoRegistrations()
        try Task.checkCancellation()
        assetKeys = CryptoProviderMapping.assetKeys(from: registrations)
      } catch is CancellationError {
        return
      } catch {
        Self.logger.warning(
          "allCryptoRegistrations failed, asset rollup disabled: \(error.localizedDescription, privacy: .public)")
      }
    }
    guard !Task.isCancelled else { return }
```

Pass `assetKeysByInstrumentId: assetKeys` into the `PositionsViewInput(...)` initializer. (If the modifier has no `logger`, add a `private static let logger = Logger(subsystem:category:)` matching the file's conventions, or reuse an existing one — confirm in Step 1.)

- [ ] **Step 3: Build to verify**

Run: `just build-mac 2>&1 | tee .agent-tmp/t11.txt`
Expected: builds clean, no warnings.

- [ ] **Step 4: Commit**

```bash
git -C .worktrees/cross-chain-asset-aggregation add Features/Transactions/Views/MultiInstrumentPositionsSplitModifier.swift
git -C .worktrees/cross-chain-asset-aggregation commit -m "feat(holdings): supply asset-key map in transaction-list positions split (#1101)"
```

---

## Task 12: Full verification + review + PR

**Files:** none (verification only)

- [ ] **Step 1: Format-check**

Run: `just format-check 2>&1 | tee .agent-tmp/fmt.txt`
Expected: clean. On failure run `just format`, inspect the diff, fix SwiftLint policy violations by editing code (never re-baseline; see `fixing-format-check`). Re-run until clean.

- [ ] **Step 2: Build both platforms**

Run: `just build-mac 2>&1 | tee .agent-tmp/build-mac.txt` and `just build-ios 2>&1 | tee .agent-tmp/build-ios.txt`
Expected: both succeed, zero warnings.

- [ ] **Step 3: Full test suite**

Run: `just test 2>&1 | tee .agent-tmp/test.txt`
Expected: 0 failures. Confirm new suites ran: `grep -iE "AssetKeyTests|AssetHoldingFoldTests|HistoricalValueSeriesAssetTests" .agent-tmp/test.txt`.

- [ ] **Step 4: Preview the rolled-up row**

Use `reviewing-ui-with-preview` (RenderPreview) against `PositionRow`'s `#Preview("rows")` and confirm one "ETH 12.95694" row with a "2 chains" secondary line. Attach the snapshot to the PR.

- [ ] **Step 5: Reviewer agents (per user instruction)**

Run over the diff: `@instrument-conversion-review`, `@code-review`, `@ui-review`. Apply all Critical/Important/Minor findings (project policy: fix everything; separate PR only if genuinely out of scope).

- [ ] **Step 6: Clean up**

Run: `rm -f .agent-tmp/t*.txt .agent-tmp/build-*.txt .agent-tmp/test.txt .agent-tmp/fmt.txt && git -C .worktrees/cross-chain-asset-aggregation rm plans/REVIEW_FINDINGS.md`
Then commit the removal.

- [ ] **Step 7: Open the PR + auto-merge**

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
- `AssetHolding` rollup + partial-failure / cost-independent-of-value / unpriced-standalone / stocks-not-merged / single-passthrough → Tasks 2–3. ✓
- Issue numbers (11.36718 + 1.58976 = 12.95694) → Task 3. ✓
- Registry seam (features never import `Backends/`) → Task 9. ✓
- Asset-key map sourced from registry, cached, degraded-safe with logging → Tasks 10–11. ✓
- No data migration; reconstructed venues left as-is → no migration task (design doc). ✓
- Summary-row-only display + chain-count secondary + accessibility → Task 6. ✓
- Chart selection generalised to an asset → Tasks 4, 8. ✓
- Totals unchanged → `PositionsViewInput.totalValue` untouched; verified by full suite (Task 12). ✓
- Reviewer agents → Task 12 Step 5. ✓

**Placeholder scan:** Tasks 9–11 contain one "confirm the local/property name, then apply this code" step each (the registry constant rename in `CloudKitBackend`, the `backend` local in the factory, the modifier's logger). The grep command and the exact code are both given, so the engineer confirms one identifier and proceeds — no unresolved placeholder. The Task 10 store test references "the existing harness pattern in that file" rather than inlining a full seeded-backend setup; this is deliberate (the harness differs per file and must be matched), and the four assertions are spelled out.

**Type consistency:** `assetKey`/`assetKeys(from:)` (T1) · `QuantityFormatting.formatted/caption` (T2) · `AssetHolding` fields incl. `currencyCode`, `positionSelection` (T2) · `AssetHolding.fold(_:assetKeys:hostCurrency:)` (T3) · `series(forInstrumentIds:)` (T4) · `PositionSelection` plain-init + `assetKeysByInstrumentId`/`assetHoldings` (T5) · `selectedSelection` (T8) · `BackendProvider.instrumentRegistry` (T9) · `InvestmentStore.assetKeysByInstrumentId` (T10) — all used consistently downstream. ✓
