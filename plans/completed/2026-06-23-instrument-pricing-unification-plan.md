# Instrument Pricing Unification — Implementation Plan (Sub-project A)

Companion to the approved spec `plans/2026-06-23-instrument-pricing-unification.md`. Execute
the tasks in order; each is an independently committable TDD slice. **Read the spec's
"common-quote selection" algorithm and 7-case verification table before Task 3 — implement that
algorithm exactly, do not invent a variant.**

---

## Goal

Collapse `FullConversionService`'s 7-case `computeUnitFactor` switch into one generic
`factor(source → target)` algorithm driven by a per-instrument `PriceSource` resolver, and move
crypto provider-metadata resolution *out* of `FullConversionService` (which today scans the
entire crypto registry on every price lookup via the injected `cryptoRegistrations` closure) and
*into* `CryptoPriceService`, which self-resolves a token's mapping + `pricingStatus` from its id
through an **indexed point lookup** (`cryptoRegistration(byId:)`) behind a small in-memory
metadata cache — mirroring how `StockPriceService` self-resolves a ticker's listing currency.

**Behaviour-neutrality is the prime directive.** The existing conversion contract suites are the
proof and must pass with their **expectations unchanged**:
`FullConversionServiceConvertResultTests`, `FullConversionServiceBatchTests`,
`FullConversionServiceCachingTests`, `InstrumentConversionServiceCryptoTests`,
`InstrumentConversionServiceStockTests`, `WrappedNativeConversionTests`,
`FullConversionErrorPropagationTests`, `ConvertCacheInvalidationTests`, plus the registry
contract suites. Their **construction lines** change (the `cryptoRegistrations:` argument is
removed and registrations are injected into `CryptoPriceService` instead) but **no `#expect`
value may change**. If a step would change an asserted value, STOP and flag it.

The measured win: registry cost per batch goes from "full-table scan per distinct key" to "one
indexed point-query per distinct token, then cached". Re-profile after merge against the 2124ms
Analysis cold-first-load baseline.

## Architecture

- **`PriceSource` protocol** (new, `Shared/PriceSource.swift`): the `Instrument → pricing
  metadata` abstraction. Surface:
  - `var nativeQuote: Instrument { get }` — the currency the provider denominates one unit in.
    Fiat: itself. Stock: its listing currency. Crypto: USD.
  - `func pricePerUnit(on date: Date) async throws -> Decimal` — one unit's price in
    `nativeQuote`. Fiat: `1`. Stock/Crypto: the provider price.
  - `func pricingStatus(on date: Date) async throws -> TokenPricingStatus` — `.priced` for
    fiat/stock; crypto reports `.priced` / `.unpriced` / `.spam` so the conversion layer can
    short-circuit to `.knownZero` without a provider call.
- **Three conformers** (`Shared/FiatPriceSource.swift`, `Shared/StockPriceSource.swift`,
  `Shared/CryptoPriceSource.swift`), each a small `struct` wrapping the relevant service.
- **`PriceSourceResolver`** (`Shared/PriceSourceResolver.swift`): maps an `Instrument` to its
  `PriceSource` by `Instrument.kind`. Owned by `FullConversionService`.
- **`CryptoPriceService` self-resolution**: a new injected metadata-lookup closure
  `@Sendable (String) async throws -> CryptoRegistration?` (prod: backed by
  `cryptoRegistration(byId:)`), an in-memory `[String: CryptoRegistration]` metadata cache, and
  a new public `price(for instrument:on:)` that drops the `mapping:` parameter. Wrapped-native
  resolution (WETH→ETH) moves inside the metadata step.
- **`FullConversionService`** loses its `cryptoRegistrations` closure entirely. `computeUnitFactor`
  becomes the generic `factor` algorithm; `convertResultDecision` reads `pricingStatus` from the
  source's `PriceSource`; `convertCryptoToFiat` / `cryptoUsdPrice` / `convertStockToFiat` are
  deleted (folded into the resolvers + `priceIn`).
- **Wiring** (`App/ProfileSession+CloudKitBackendBuild.swift`): inject the keyed metadata plug
  `{ id in try await registry.cryptoRegistration(byId: id) }` into `CryptoPriceService`'s
  construction instead of the all-rows closure into `FullConversionService`.
- `allCryptoRegistrations()` stays intact for its non-conversion callers (spam scan, UI stores,
  presets, search, reconcile). Only the conversion code path stops calling it.

## Tech Stack

- Swift 6, actors (`FullConversionService`, `CryptoPriceService`, `StockPriceService` are all
  `actor`s), `Sendable`, structured concurrency. Follow `guides/CONCURRENCY_GUIDE.md`.
- GRDB for the indexed point lookup; `cryptoRegistration(byId:)` already exists and is
  index-backed (`instrument.id` is the PK).
- **Swift Testing** (`@Suite`, `@Test`, `#expect`, `#require`) — NOT XCTest. Match
  `MoolahTests/Shared/FullConversionServiceConvertResultTests.swift`.
- `dec("…")` and `Instrument.AUD` / `.USD` test helpers already exist and are used throughout
  the conversion suites.

## Global Constraints

- **One extension per protocol conformance.** Each `PriceSource` conformer declares the type in
  one file and conforms in a separate `extension` (no inline `: PriceSource` on the struct
  declaration). See `guides/CODE_GUIDE.md`.
- **`SWIFT_TREAT_WARNINGS_AS_ERRORS: YES`** — no unused vars/results, no dead code left behind.
  When deleting `convertCryptoToFiat` etc., delete them fully; do not leave them `private` and
  unused.
- Build/verify ONLY via `just`: `just build-mac`, `just test-mac <ExactSuiteTypeName>`,
  `just format-check`. **Test filters are the exact suite TYPE name** — a substring or the
  `@Suite("display name")` string runs 0 tests but still prints SUCCEEDED. Use the Swift `struct`
  name (e.g. `FullConversionServiceConvertResultTests`).
- Pipe test output to `.agent-tmp/` (gitignored): `just test-mac Foo 2>&1 | tee
  .agent-tmp/foo.txt`; grep for `failed|error:`; delete the temp file when done.
- Every task ends with: `just build-mac` + its targeted suites green + `just format-check` clean,
  then a commit. Commit footer (two trailing lines, exactly):

  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6
  ```

- Plans/specs live in `plans/`, never `docs/`.
- Do not edit any existing contract test's `#expect` values. New tests are additive.

---

## Current-state reference (read before starting)

Exact signatures / line anchors the tasks depend on (worktree
`moolah-native.instrument-pricing-unification`):

- `Shared/FullConversionService.swift`
  - `let cryptoRegistrations: @Sendable () async throws -> [CryptoRegistration]` (line ~14);
    init param at line ~94 (`cryptoRegistrations: … = { [] }`).
  - `init(exchangeRates:stockPrices:cryptoPrices:cryptoRegistrations:database:)` (~90–103).
  - `convert(_:from:to:on:)` (~105) → `unitFactor` (~129) → `computeUnitFactor(from:to:on:)`
    (~157, the 7-case switch).
  - `convertResult(_:to:on:)` (~230) calls `cryptoRegistrations()` then
    `convertResultDecision(_:to:registrations:)` (~274).
  - `invalidateCache(for:)` (~299) — evicts `rateCache` + `cryptoPrices.purgeCache`; preserves
    wrapped-native eviction.
  - `convertStockToFiat` (~347), `convertCryptoToFiat` (~367), `cryptoUsdPrice(for:on:)` (~379)
    — to be deleted/folded.
- `Shared/FullConversionService+Batch.swift`
  - `convertResultBatch` (~22) calls `cryptoRegistrations()` (line 28) then
    `convertResultDecision(_:to:registrations:)`; `resolveMissingKeys` / `resolveKey` call
    `computeUnitFactor`.
- `Shared/CryptoPriceService.swift`
  - `init(clients:database:resolutionClient:now:timeZone:)` (~55).
  - `price(for instrument:mapping:on:)` (~133); `prices(for instrument:mapping:in:)` (~201);
    `purgeCache(instrumentId:)` (~106).
  - `mapping` is threaded deep through `CryptoPriceService+FetchRange.swift`
    (`extendContiguously`, `coverRangeContiguously`, `extendOneDirection`,
    `fetchWindowCoalesced`, `fetchRange`) — the public surface drops `mapping:` but the
    **internal** plumbing keeps it; `price(for:on:)` resolves the registration then calls the
    existing internal `price(for:mapping:on:)` (kept `internal`, not deleted).
  - `priceLookup(for registration:on:)` in `CryptoPriceService+PriceLookup.swift` — unchanged.
- `Shared/StockPriceService.swift`: `price(ticker:on:)` (~52), `instrument(for:)` (~126) — the
  self-resolution pattern to mirror.
- `Backends/GRDB/Repositories/GRDBInstrumentRegistryRepository+Lookup.swift`:
  `cryptoRegistration(byId id:) async throws -> CryptoRegistration?` (~10) — the indexed point
  lookup; `static func project(row:)` applies inbox/spam visibility rules.
- `Shared/WrappedNativeContracts.swift` (path is `Shared/WrappedNativeContracts.swift`):
  `nativePricingInstrumentId(chainId:contractAddress:) -> String?`,
  `canonicalWrappedInstrumentId(forChainId:) -> String?`.
- `Domain/Models/CryptoRegistration.swift`: `init(instrument:mapping:pricingStatus: = .priced)`,
  `var id: String { instrument.id }`, `var pricingStatus`.
- `Domain/Models/TokenPricingStatus.swift`: `.priced` / `.unpriced` / `.spam`.
- `Domain/Models/Instrument.swift`: `enum Kind { fiatCurrency, stock, cryptoToken }`;
  `static let USD`; `var kind`, `var ticker`, `var chainId`, `var contractAddress`.
- `Domain/Repositories/CryptoPriceClient.swift`: `enum CryptoPriceError` incl.
  `.beforeFirstTrade(tokenId:date:)`.
- `Domain/Services/InstrumentConversionService.swift`: the protocol; `ConversionError`
  (`.unsupportedConversion`, `.noCryptoPriceService`, `.noProviderMapping(instrumentId:)`).

**Construction sites of `FullConversionService(`** (16 hits; 1 prod, 15 test — the prod +
each conversion test must drop `cryptoRegistrations:`):

| File | Line(s) |
|---|---|
| `App/ProfileSession+CloudKitBackendBuild.swift` | 69 (prod wiring) |
| `MoolahTests/Backends/GRDB/PreListingDailyBalanceTests.swift` | 232 |
| `MoolahTests/Features/StockPositionDisplayTests.swift` | 88, 179 |
| `MoolahTests/Shared/InstrumentConversionServiceCryptoTests.swift` | 49, 257 |
| `MoolahTests/Shared/ConvertCacheInvalidationTests.swift` | 48, 90 |
| `MoolahTests/Shared/FullConversionErrorPropagationTests.swift` | 30 |
| `MoolahTests/Shared/InstrumentConversionServiceStockTests.swift` | 28, 155 |
| `MoolahTests/Shared/WrappedNativeConversionTests.swift` | 48 |
| `MoolahTests/Shared/FullConversionServiceConvertResultTests.swift` | 45 |
| `MoolahTests/Shared/FullConversionServiceCachingTests.swift` | 56 |
| `MoolahTests/Shared/FullConversionServiceBatchTests.swift` | 65 |

`MoolahTests/App/ProfileSessionTests.swift:59` is a *method name*
(`cloudKitProfileUsesFullConversionService`), not a constructor — no edit needed.

**Call sites of `CryptoPriceService.price(for:mapping:…)` / `.prices(for:mapping:…)`** that the
signature work touches (the public crypto-price tests):
`MoolahTests/Shared/CryptoPriceServiceTests.swift` (107, 147),
`MoolahTests/Shared/ContiguousExtensionCryptoTests.swift` (126, 137, 224, 236),
`MoolahTests/Shared/CryptoPriceServiceWarmRangeTests.swift` (79),
`MoolahTests/Backends/GRDB/PreListingDailyBalanceTests.swift` (205, 297 build CryptoPriceService).
These keep working against the retained **internal** `price(for:mapping:on:)` (Task 1 keeps it),
so they need no edits unless a task explicitly says so.

---

## Task 1 — `CryptoPriceService` self-resolves mapping + `pricingStatus`

Inject a keyed metadata-lookup closure + an in-memory metadata cache. Add a public
`price(for instrument:on:)` (no `mapping:`) and a `registration(for:on:)` accessor for
classification. Move wrapped-native resolution inside. Keep the existing internal
`price(for:mapping:on:)` so deep FetchRange plumbing and existing tests are untouched.

### Files

- Modify: `Shared/CryptoPriceService.swift`
- Test (new): `MoolahTests/Shared/CryptoPriceServiceMetadataTests.swift`
- Test (new helper): add a `RecordingCryptoRegistrationLookup` double + a
  `CryptoRegistration → metadata-closure` builder in the new test file (keep it local to this
  suite; promote later only if another suite needs it).

### Interfaces

Consumes:
- `CryptoRegistration` (`.instrument`, `.mapping`, `.pricingStatus`, `.id`).
- `WrappedNativeContracts.nativePricingInstrumentId(chainId:contractAddress:) -> String?`.
- `Instrument` (`.id`, `.chainId`, `.contractAddress`, `.kind`).
- `cryptoRegistration(byId:)` shape: `@Sendable (String) async throws -> CryptoRegistration?`.

Produces (new public surface on `CryptoPriceService`):
```swift
init(
  clients: [CryptoPriceClient],
  database: any DatabaseWriter,
  resolutionClient: (any TokenResolutionClient)? = nil,
  metadataLookup: @Sendable @escaping (String) async throws -> CryptoRegistration? = { _ in nil },
  now: @Sendable @escaping () -> Date = { Date() },
  timeZone: TimeZone = .current
)

func price(for instrument: Instrument, on date: Date) async throws -> Decimal
func registration(for instrument: Instrument) async throws -> CryptoRegistration
```
Retained internal (unchanged signature): `price(for instrument:mapping:on:)`.

### Implementation notes

- Add stored props: `private let metadataLookup`, `var metadataCache: [String: CryptoRegistration]
  = [:]` (actor-isolated). The metadata cache is keyed by **the looked-up id** (the
  wrapped-native-resolved id), and also memoised under the original instrument id so a second
  call for the wrapper hits the cache without re-running the WETH→ETH lookup.
- `registration(for:on:)`: compute `lookupId = WrappedNativeContracts.nativePricingInstrumentId(
  chainId:contractAddress:) ?? instrument.id`; if `metadataCache[instrument.id]` present return
  it; else `metadataLookup(lookupId)`; if `nil` throw
  `ConversionError.noProviderMapping(instrumentId: instrument.id)`; cache under both
  `instrument.id` and `lookupId`; return it. (This reproduces the exact wrapped-native +
  no-mapping-throws behaviour previously in `cryptoUsdPrice`.)
- `price(for:on:)`: `let reg = try await registration(for: instrument, on: date); return try
  await price(for: reg.instrument, mapping: reg.mapping, on: date)`. NOTE: `reg.instrument` is the
  native instrument for a wrapper, so the price is fetched/cached under the native id — exactly
  as before.
- `purgeCache(instrumentId:)`: add `metadataCache.removeValue(forKey: instrumentId)` and also
  evict the wrapper id when a native id is purged (use
  `canonicalWrappedInstrumentId(forChainId:)`), mirroring `FullConversionService.invalidateCache`'s
  wrapped-native eviction so an ETH metadata change also drops a cached WETH→ETH mapping. Add the
  eviction near the existing `caches.removeValue` line.
- The metadata lookup must perform **exactly one** call per distinct token; assert via a
  recording double's counter.

### Steps

1. Write failing test file `MoolahTests/Shared/CryptoPriceServiceMetadataTests.swift`:

   ```swift
   import Foundation
   import GRDB
   import Testing

   @testable import Moolah

   @Suite("CryptoPriceService — metadata self-resolution")
   struct CryptoPriceServiceMetadataTests {
     private let eth = Instrument.crypto(
       chainId: 1, contractAddress: nil, symbol: "ETH", name: "Ethereum", decimals: 18)
     private let weth = Instrument.crypto(
       chainId: 1, contractAddress: "0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
       symbol: "WETH", name: "Wrapped Ether", decimals: 18)
     private let ethMapping = CryptoProviderMapping(
       instrumentId: "1:native", coingeckoId: "ethereum",
       cryptocompareSymbol: "ETH", binanceSymbol: "ETHUSDT")

     private func date(_ s: String) -> Date {
       let f = ISO8601DateFormatter(); f.formatOptions = [.withFullDate]
       return f.date(from: s)!
     }

     /// Records every id passed to the metadata lookup so the suite can assert
     /// "exactly one point lookup per distinct token, then cached".
     private final class RecordingLookup: @unchecked Sendable {
       let lock = NSLock()
       private(set) var ids: [String] = []
       let table: [String: CryptoRegistration]
       init(_ table: [String: CryptoRegistration]) { self.table = table }
       func lookup(_ id: String) async throws -> CryptoRegistration? {
         lock.lock(); ids.append(id); lock.unlock()
         return table[id]
       }
       var count: Int { lock.lock(); defer { lock.unlock() }; return ids.count }
     }

     private func makeService(
       prices: [String: [String: Decimal]] = [:],
       lookup: RecordingLookup
     ) throws -> CryptoPriceService {
       CryptoPriceService(
         clients: [FixedCryptoPriceClient(prices: prices)],
         database: try ProfileIndexDatabase.openInMemory(),
         metadataLookup: { try await lookup.lookup($0) })
     }

     @Test
     func hydratesOnMissThenCachesPerToken() async throws {
       let lookup = RecordingLookup([
         "1:native": CryptoRegistration(instrument: eth, mapping: ethMapping)
       ])
       let service = try makeService(
         prices: ["1:native": ["2026-04-10": dec("1623.45")]], lookup: lookup)
       let first = try await service.price(for: eth, on: date("2026-04-10"))
       let second = try await service.price(for: eth, on: date("2026-04-10"))
       #expect(first == dec("1623.45"))
       #expect(second == dec("1623.45"))
       #expect(lookup.count == 1)  // one point lookup, then cached
     }

     @Test
     func wrappedNativePricesViaNativeRegistration() async throws {
       let lookup = RecordingLookup([
         "1:native": CryptoRegistration(instrument: eth, mapping: ethMapping)
       ])
       let service = try makeService(
         prices: ["1:native": ["2026-04-10": dec("1623.45")]], lookup: lookup)
       let price = try await service.price(for: weth, on: date("2026-04-10"))
       #expect(price == dec("1623.45"))
       #expect(lookup.ids == ["1:native"])  // resolved by native id, never the WETH contract
     }

     @Test
     func unknownIdThrowsNoProviderMapping() async throws {
       let lookup = RecordingLookup([:])
       let service = try makeService(lookup: lookup)
       await #expect(throws: ConversionError.noProviderMapping(instrumentId: eth.id)) {
         _ = try await service.price(for: eth, on: date("2026-04-10"))
       }
     }

     @Test
     func purgeEvictsMetadataCache() async throws {
       let lookup = RecordingLookup([
         "1:native": CryptoRegistration(instrument: eth, mapping: ethMapping)
       ])
       let service = try makeService(
         prices: ["1:native": ["2026-04-10": dec("1623.45")]], lookup: lookup)
       _ = try await service.price(for: eth, on: date("2026-04-10"))
       await service.purgeCache(instrumentId: eth.id)
       _ = try await service.price(for: eth, on: date("2026-04-10"))
       #expect(lookup.count == 2)  // re-resolved after eviction
     }
   }
   ```

2. Run it, expect failure (no `metadataLookup:` param / no `price(for:on:)`):
   `just test-mac CryptoPriceServiceMetadataTests 2>&1 | tee .agent-tmp/t1.txt` →
   compile error (symbol not found). That counts as the failing-test gate.

3. Minimal impl in `Shared/CryptoPriceService.swift`:
   - Add to the `// MARK: - Cross-extension internals` block: `private let metadataLookup:
     @Sendable (String) async throws -> CryptoRegistration?` and `var metadataCache: [String:
     CryptoRegistration] = [:]`.
   - Add `metadataLookup: @Sendable @escaping (String) async throws -> CryptoRegistration? = { _
     in nil }` to `init` (after `resolutionClient`); assign `self.metadataLookup = metadataLookup`.
   - Add the accessor + public price:
     ```swift
     func registration(for instrument: Instrument) async throws -> CryptoRegistration {
       if let cached = metadataCache[instrument.id] { return cached }
       let lookupId =
         WrappedNativeContracts.nativePricingInstrumentId(
           chainId: instrument.chainId, contractAddress: instrument.contractAddress)
         ?? instrument.id
       guard let registration = try await metadataLookup(lookupId) else {
         throw ConversionError.noProviderMapping(instrumentId: instrument.id)
       }
       metadataCache[instrument.id] = registration
       metadataCache[lookupId] = registration
       return registration
     }

     func price(for instrument: Instrument, on date: Date) async throws -> Decimal {
       let registration = try await registration(for: instrument)
       return try await price(
         for: registration.instrument, mapping: registration.mapping, on: date)
     }
     ```
     Place these in the `// MARK: - Single price` section, above the retained internal
     `price(for:mapping:on:)`.
   - In `purgeCache(instrumentId:)`, after `caches.removeValue(forKey: instrumentId)` add:
     ```swift
     metadataCache.removeValue(forKey: instrumentId)
     if let wrapperId = WrappedNativeContracts.canonicalWrappedInstrumentId(
       forChainId: Instrument.chainId(fromCryptoId: instrumentId))
     {
       metadataCache.removeValue(forKey: wrapperId)
     }
     ```
     If no `Instrument.chainId(fromCryptoId:)` helper exists, derive the chain id by splitting
     `instrumentId` on `":"` and taking `Int(prefix)`; inline a tiny private helper
     `chainId(fromCryptoId:)` on `CryptoPriceService` rather than adding API to `Instrument`.
     (Verify whether such a helper exists before adding one — grep `chainId(from`.)

4. Run: `just test-mac CryptoPriceServiceMetadataTests 2>&1 | tee .agent-tmp/t1.txt`; grep
   `failed|error:`; expect all 4 green. Also run the unchanged `CryptoPriceServiceTests` to prove
   the retained internal `price(for:mapping:on:)` still works:
   `just test-mac CryptoPriceServiceTests 2>&1 | tee -a .agent-tmp/t1.txt`.

5. `just build-mac` then `just format-check`. Fix any layout/lint. `rm .agent-tmp/t1.txt`.

6. Commit:
   ```
   git add -A && git commit -m "feat(crypto-price): self-resolve mapping + pricingStatus via keyed metadata cache

   CryptoPriceService gains an injected metadata-lookup closure and an
   in-memory metadata cache so price(for:on:) resolves a token's mapping
   (and wrapped-native redirection) from its id via an indexed point
   lookup instead of a registry scan. Retains the internal
   price(for:mapping:on:) plumbing.

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6"
   ```

---

## Task 2 — `PriceSource` protocol + Fiat/Stock/Crypto sources + `PriceSourceResolver`

Define the protocol and three conformers (one extension per conformance) plus the
kind-dispatched resolver. Unit-test each conformer's `nativeQuote`, `pricePerUnit`, and
`pricingStatus`.

### Files

- Create: `Shared/PriceSource.swift` (protocol only)
- Create: `Shared/FiatPriceSource.swift`
- Create: `Shared/StockPriceSource.swift`
- Create: `Shared/CryptoPriceSource.swift`
- Create: `Shared/PriceSourceResolver.swift`
- Test (new): `MoolahTests/Shared/PriceSourceTests.swift`

### Interfaces

Produces:
```swift
protocol PriceSource: Sendable {
  var nativeQuote: Instrument { get }
  func pricePerUnit(on date: Date) async throws -> Decimal
  func pricingStatus(on date: Date) async throws -> TokenPricingStatus
}

struct FiatPriceSource { let instrument: Instrument }
struct StockPriceSource { let instrument: Instrument; let stockPrices: StockPriceService }
struct CryptoPriceSource { let instrument: Instrument; let cryptoPrices: CryptoPriceService }

struct PriceSourceResolver: Sendable {
  init(stockPrices: StockPriceService, cryptoPrices: CryptoPriceService?)
  func source(for instrument: Instrument) -> any PriceSource   // throws-free; nil cryptoPrices handled in pricePerUnit
}
```

Consumes: `ExchangeRateService` (only inside `FullConversionService`'s `priceIn`, NOT inside the
sources — sources price into `nativeQuote`, the FX bridge stays in the conversion layer);
`StockPriceService.price(ticker:on:)` + `.instrument(for:)`; `CryptoPriceService.price(for:on:)`
+ `.registration(for:on:)`.

### Implementation notes

- `FiatPriceSource`: `nativeQuote = instrument`; `pricePerUnit = 1`; `pricingStatus = .priced`.
- `StockPriceSource`: `nativeQuote` is the listing currency. But `instrument(for:)` is async and
  `nativeQuote` is a sync `get`. **Resolve this**: make `nativeQuote` return the listing currency
  by having the resolver NOT precompute it — instead, the generic `factor` algorithm needs the
  native quote *with* the price. Two clean options; pick **option A** for least surprise:
  - **Option A (recommended):** Replace the `nativeQuote` property with a combined async call so
    the source returns both at once:
    ```swift
    protocol PriceSource: Sendable {
      func quote(on date: Date) async throws -> (perUnit: Decimal, nativeQuote: Instrument)
      func pricingStatus(on date: Date) async throws -> TokenPricingStatus
    }
    ```
    Fiat: `(1, instrument)`. Stock: `(price(ticker:on:), instrument(for: ticker))`. Crypto:
    `(price(for:on:), .USD)`. This keeps the `factor`/`priceIn` algorithm purely async and avoids
    a sync property that can't resolve a stock's listing currency without I/O. **Use Option A and
    update the Architecture protocol surface above accordingly when implementing.**
- `StockPriceSource.quote`: guard `instrument.ticker` else throw
  `ConversionError.unsupportedConversion(from: instrument.id, to: "fiat")` (matches the old
  `convertStockToFiat` guard); `let price = try await stockPrices.price(ticker:on:)`;
  `let listing = try await stockPrices.instrument(for: ticker)`; return `(price, listing)`.
- `CryptoPriceSource.quote`: `(try await cryptoPrices?.price(for: instrument, on: date) ?? {
  throw ConversionError.noCryptoPriceService }(), .USD)`. Hold `cryptoPrices` as optional inside
  the source; throw `.noCryptoPriceService` when nil and a price is actually demanded (matches old
  `cryptoUsdPrice`). `pricingStatus`: `(try await cryptoPrices?.registration(for: instrument))?
  .pricingStatus ?? .priced` — but a `nil` registration must surface as `.noProviderMapping` only
  when a *price* is needed, not from `pricingStatus`. Mirror current behaviour: `pricingStatus`
  for a crypto with no registration should **propagate the throw** from `registration(for:)`
  (current `convertResultDecision` only special-cases registrations it *finds*; an absent crypto
  registration falls through to `.convert` and then throws `noProviderMapping` at price time).
  So: `pricingStatus` returns `.priced` for fiat/stock; for crypto it should NOT throw on a
  missing registration — it should return `.priced` so the request proceeds to the price call,
  which throws `noProviderMapping`. Implement crypto `pricingStatus` as:
  ```swift
  func pricingStatus(on date: Date) async throws -> TokenPricingStatus {
    guard let cryptoPrices else { return .priced }
    do { return try await cryptoPrices.registration(for: instrument).pricingStatus }
    catch { return .priced }  // missing registration → proceed; price call surfaces the error
  }
  ```
  This exactly preserves: `.unpriced`/`.spam` → knownZero; missing registration → throws at
  price time, not at classification.
- `PriceSourceResolver.source(for:)`:
  ```swift
  switch instrument.kind {
  case .fiatCurrency: return FiatPriceSource(instrument: instrument)
  case .stock:        return StockPriceSource(instrument: instrument, stockPrices: stockPrices)
  case .cryptoToken:  return CryptoPriceSource(instrument: instrument, cryptoPrices: cryptoPrices)
  }
  ```

### Steps

1. Write failing `MoolahTests/Shared/PriceSourceTests.swift` covering: fiat source `(1, USD)` +
   `.priced`; stock source returns `(price, listing-currency)` from a seeded
   `StockPriceService`; crypto `.priced`/`.unpriced`/`.spam` reported via the metadata closure;
   crypto `quote.nativeQuote == .USD`. Build the `CryptoPriceService` with the Task-1
   `metadataLookup:` closure and the stock service with a `FixedStockPriceClient`. Example crypto
   status assertion:
   ```swift
   @Test func cryptoSourceReportsSpamStatus() async throws {
     let lookup: @Sendable (String) async throws -> CryptoRegistration? = { _ in
       CryptoRegistration(instrument: eth, mapping: ethMapping, pricingStatus: .spam)
     }
     let crypto = CryptoPriceService(
       clients: [FixedCryptoPriceClient(prices: [:])],
       database: try ProfileIndexDatabase.openInMemory(), metadataLookup: lookup)
     let source = CryptoPriceSource(instrument: eth, cryptoPrices: crypto)
     #expect(try await source.pricingStatus(on: date("2026-04-10")) == .spam)
     #expect(source.nativeQuoteIsUSD)  // or assert via quote(on:) once seeded
   }
   ```
   (Adjust to the final Option-A `quote(on:)` surface.)

2. Run, expect fail (types don't exist):
   `just test-mac PriceSourceTests 2>&1 | tee .agent-tmp/t2.txt`.

3. Create the five files (one extension per conformance — e.g. `FiatPriceSource.swift` declares
   `struct FiatPriceSource { … }` then `extension FiatPriceSource: PriceSource { … }`).

4. Run `just test-mac PriceSourceTests`; expect green. Confirm no other suite was perturbed:
   `just build-mac`.

5. `just format-check`; fix; `rm .agent-tmp/t2.txt`.

6. Commit:
   ```
   git commit -am "feat(conversion): add PriceSource protocol + fiat/stock/crypto sources + resolver

   Introduces the per-instrument PriceSource abstraction (quote+status)
   and a kind-dispatched PriceSourceResolver, the composition substrate
   for the generic factor algorithm.

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6"
   ```

---

## Task 3 — Generic `factor` / `priceIn` algorithm; rewrite `computeUnitFactor`; delete the old helpers

Implement the spec's common-quote algorithm in `FullConversionService`, route
`convertResultDecision` through the `PriceSource` resolver, and delete
`convertCryptoToFiat` / `cryptoUsdPrice` / `convertStockToFiat`. **This task still constructs
`FullConversionService` with `cryptoRegistrations:` — that closure is removed in Task 4.** During
Task 3, `convertResultDecision` must produce identical results whether it reads the
already-fetched `registrations` array (current) or the resolver. To keep Task 3 independently
green without churning every construction site twice, **route `convertResultDecision`'s crypto
status through the resolver but keep accepting the `registrations` param as an ignored
compatibility shim is NOT allowed** (no dead params). Instead: Task 3 changes
`convertResultDecision`'s *signature* to drop `registrations` and read status from the resolver,
and updates the two callers (`convertResult`, `convertResultBatch`) to stop fetching
`cryptoRegistrations()` for classification. The `cryptoRegistrations` stored closure becomes
unused **only** in the price path after Task 3; it is fully removed in Task 4. To avoid an
"unused stored property" error between tasks, **combine the removal of the closure with Task 3**
if the build flags it — see the ordering note at the end. Prefer: do Task 3 and Task 4 in one
branch, two commits, building only after Task 4. If you must build after Task 3 alone, retain the
`cryptoRegistrations` property but reference it in a `#if false`-free way is impossible — so
**the canonical path is: implement Task 3's code changes, then immediately Task 4's removal +
construction-site updates, then build once.** The two commits stay logically separate.

### Files

- Modify: `Shared/FullConversionService.swift`
- Modify: `Shared/FullConversionService+Batch.swift`
- Test (new): `MoolahTests/Shared/FullConversionFactorRoutingTests.swift`

### Interfaces

Produces (internal to `FullConversionService`, reachable from `+Batch`):
```swift
func computeUnitFactor(from source: Instrument, to target: Instrument, on date: Date)
  async throws -> UnitFactor                      // rewritten body, same signature

func convertResultDecision(_ amount: InstrumentAmount, to instrument: Instrument)
  async -> ConvertResultDecision                  // drops `registrations:`, now async
```

New private helpers:
```swift
private func factor(from source: Instrument, to target: Instrument, on date: Date)
  async throws -> UnitFactor
private func priceIn(_ instrument: Instrument, quotedIn common: Instrument, on date: Date)
  async throws -> Decimal
```

Consumes: `PriceSourceResolver` (new stored `private let priceSources: PriceSourceResolver`),
`ExchangeRateService.rate(from:to:on:)`, `Instrument.USD`.

### Implementation notes — the algorithm (from the spec, reproduce EXACTLY)

```swift
func computeUnitFactor(from source: Instrument, to target: Instrument, on date: Date)
  async throws -> UnitFactor
{
  // any →stock unsupported (unchanged precondition)
  guard target.kind != .stock else {
    throw ConversionError.unsupportedConversion(from: source.id, to: target.id)
  }
  if source == target { return UnitFactor(multiplier: 1, divisor: 1) }
  if source.kind == .fiatCurrency, target.kind == .fiatCurrency {
    let rate = try await exchangeRates.rate(from: source, to: target, on: date)
    return UnitFactor(multiplier: rate, divisor: 1)
  }
  let common: Instrument =
    target.kind == .fiatCurrency ? target
    : source.kind == .fiatCurrency ? source
    : .USD
  let multiplier = try await priceIn(source, quotedIn: common, on: date)
  let divisor = try await priceIn(target, quotedIn: common, on: date)
  return UnitFactor(multiplier: multiplier, divisor: divisor)
}

private func priceIn(_ instrument: Instrument, quotedIn common: Instrument, on date: Date)
  async throws -> Decimal
{
  if instrument == common { return 1 }
  if instrument.kind == .fiatCurrency {
    return try await exchangeRates.rate(from: instrument, to: common, on: date)
  }
  let quote = try await priceSources.source(for: instrument).quote(on: date)  // (perUnit, nativeQuote)
  if quote.nativeQuote == common { return quote.perUnit }
  let fx = try await exchangeRates.rate(from: quote.nativeQuote, to: common, on: date)
  return quote.perUnit * fx
}
```

**Verify against the spec's 7-case table** while implementing. The non-obvious cases:
- `fiat→crypto`: `common = source` (the fiat). `multiplier = priceIn(fiat, common=fiat) = 1`;
  `divisor = priceIn(crypto, common=fiat) = cryptoUsd · rate(USD→fiat)`. ⇒ `(1,
  cryptoUsd·rate(USD→source))` ✓ (exact-round-trip preserved — `300_000 JPY → ETH` at `1 ETH =
  300_000 JPY` ⇒ `(1, 300_000)`, and `quantity·1/300_000`).
- `crypto→fiat`: `common = target` (fiat). `multiplier = cryptoUsd · rate(USD→fiat)`; `divisor =
  priceIn(fiat, common=fiat) = 1`. ✓
- `crypto→crypto`: `common = USD`. `(cryptoUsd(s), cryptoUsd(t))` ✓.
- `stock→crypto`: `common = USD`. `multiplier = stockPrice · rate(listing→USD)`; `divisor =
  cryptoUsd(t)` ✓.
- `stock→fiat`: `common = target`. `multiplier = stockPrice · rate(listing→fiat)` (or
  `stockPrice` when `listing == fiat`); `divisor = 1` ✓.

`convertResultDecision` (now async, resolver-driven):
```swift
func convertResultDecision(_ amount: InstrumentAmount, to instrument: Instrument)
  async -> ConvertResultDecision
{
  if amount.instrument == instrument { return .value(amount) }
  if amount.instrument.kind == .cryptoToken {
    let status = (try? await priceSources.source(for: amount.instrument)
      .pricingStatus(on: Date())) ?? .priced
    if status != .priced { return .knownZero }
  }
  return .convert
}
```
NOTE: `pricingStatus(on:)` ignores the date for crypto (registration status is date-independent),
so `Date()` is fine and matches the current behaviour (status read from a fetched array, not
date-keyed). Confirm `CryptoPriceSource.pricingStatus` never performs a network call — it only
reads the metadata cache / point lookup.

`convertResult`: delete the `let registrations = try await cryptoRegistrations()` line and the
`registrations:` argument; `switch await convertResultDecision(amount, to: instrument)`.

`convertResultBatch` (`+Batch.swift`): delete `let registrations = try await
cryptoRegistrations()`; the classification loop becomes async — `convertResultDecision` is now
`async`, so the `for request in requests` loop already runs inside the async function and can
`await` it. Update the call: `let decision = await convertResultDecision(request.amount, to:
request.target)`. Everything downstream (`keyContext`, `resolveMissingKeys`, `computeUnitFactor`)
is unchanged.

Delete `convertStockToFiat`, `convertCryptoToFiat`, `cryptoUsdPrice` entirely (the `// MARK: -
Stock helpers` and `// MARK: - Crypto helpers` sections). `invalidateCache` keeps its
wrapped-native `rateCache` eviction and `cryptoPrices.purgeCache` call unchanged.

Add `private let priceSources: PriceSourceResolver` and construct it in `init` from
`stockPrices` + `cryptoPrices` (added in Task 4's init rewrite; if doing Task 3 first, add the
property and build the resolver inline in `init` now — it does not depend on the removed closure).

### Steps

1. Write failing `MoolahTests/Shared/FullConversionFactorRoutingTests.swift` — direct-vs-USD
   routing, one `@Test` per kind pair, asserting both the numeric result AND (where it matters)
   that fiat→fiat uses the direct pair (assert AUD→GBP equals the seeded direct rate, NOT a
   USD-triangulated product). Reuse the `makeService` shape from
   `InstrumentConversionServiceCryptoTests` (it injects registrations — for Task 3 still via
   `cryptoRegistrations:`; this test file is updated alongside Task 4's construction-site sweep,
   so write it against the **final** Task-4 construction shape, i.e. registrations injected into
   `CryptoPriceService` via `metadataLookup`). Cases:
   - `audToGbpUsesDirectPair` — seed `exchangeRates: ["<date>": ["GBP": dec("0.52")]]` with base
     AUD pair; expect `100 AUD → 52 GBP`; assert it does not equal a USD-bridged value.
   - `stockToFiatViaListing` — stock listing in AUD, target USD, via `rate(AUD→USD)`.
   - `cryptoToFiatViaUsd` — ETH→AUD = `cryptoUsd · rate(USD→AUD)`.
   - `cryptoToCryptoViaUsd` — ETH→BTC = `ethUsd / btcUsd` (assert exact via `dec`).
   - `fiatToCryptoExactRoundTrip` — `300_000 JPY → ETH` at `1 ETH = 300_000 JPY` ⇒ exactly `1`.
   - `stockToCryptoViaUsd` — `stockUsd / cryptoUsd`.
   Match the existing suites' numeric expectations style (`dec("…") * dec("…")`).

2. Run, expect fail: `just test-mac FullConversionFactorRoutingTests 2>&1 | tee .agent-tmp/t3.txt`.

3. Implement the algorithm + decision changes above. (Proceed straight into Task 4's removal so
   the build is clean — see the combined ordering note.)

4. Run the new suite AND every behaviour-neutrality suite, expecting all green with unchanged
   expectations:
   ```
   just test-mac FullConversionFactorRoutingTests FullConversionServiceConvertResultTests \
     FullConversionServiceBatchTests FullConversionServiceCachingTests \
     InstrumentConversionServiceCryptoTests InstrumentConversionServiceStockTests \
     WrappedNativeConversionTests FullConversionErrorPropagationTests \
     ConvertCacheInvalidationTests 2>&1 | tee .agent-tmp/t3.txt
   grep -i 'failed\|error:' .agent-tmp/t3.txt
   ```
   If any pre-existing suite's value would need editing to pass → STOP, the algorithm diverges
   from the spec; re-derive against the 7-case table.

5. `just build-mac`; `just format-check`; `rm .agent-tmp/t3.txt`.

6. Commit:
   ```
   git commit -am "refactor(conversion): replace 7-case switch with generic factor/priceIn algorithm

   computeUnitFactor now selects a common quote (target fiat, else source
   fiat, else USD) and defers division, reproducing every prior case
   exactly (verified against the spec's 7-case table). convertResultDecision
   reads pricingStatus through the PriceSource resolver. Deletes
   convertCryptoToFiat/cryptoUsdPrice/convertStockToFiat.

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6"
   ```

---

## Task 4 — Remove the `cryptoRegistrations` closure from `FullConversionService`; rewire prod + all construction sites

Drop the `cryptoRegistrations` stored property + init param. Update the prod wiring to inject the
keyed metadata plug into `CryptoPriceService`. Update the preview wiring and all 15 test
construction sites: inject registrations into `CryptoPriceService` via `metadataLookup:` instead
of into `FullConversionService` via `cryptoRegistrations:`.

### Files

- Modify: `Shared/FullConversionService.swift` (remove stored prop + init param + doc comment)
- Modify: `App/ProfileSession+CloudKitBackendBuild.swift` (move the plug onto `CryptoPriceService`)
- Modify: every test file in the construction-site table that passes `cryptoRegistrations:`
- (Check) `PreviewBackend` wiring — grep for where the preview's `CryptoPriceService` /
  `FullConversionService` is built and apply the same move if it passes `cryptoRegistrations:`.

### Interfaces

Final `FullConversionService.init`:
```swift
init(
  exchangeRates: ExchangeRateService,
  stockPrices: StockPriceService,
  cryptoPrices: CryptoPriceService? = nil,
  database: (any DatabaseWriter)? = nil
)
```
(`priceSources = PriceSourceResolver(stockPrices: stockPrices, cryptoPrices: cryptoPrices)`
built inside.)

Prod wiring change (`makeCloudKitBackend`): the `CryptoPriceService` is constructed in
`makeBackend`/`bootstrap` upstream of this method (it arrives via
`CloudKitMarketDataServices.cryptoPrices`). The keyed plug must be attached **where that
`CryptoPriceService` is constructed**, not here — locate that site (grep `CryptoPriceService(` in
`App/`) and add `metadataLookup: { id in try await registry.cryptoRegistration(byId: id) }`.
If the registry is not in scope at that construction site, thread it through (the registry is
already built in `makeCloudKitBackend`; if construction is upstream, pass a metadata closure down
via `CloudKitMarketDataServices`, or move the `CryptoPriceService` construction into
`makeCloudKitBackend` where `registry` is available). **Confirm the exact construction site
before writing the edit** — `grep -rn "CryptoPriceService(" App/`.

### Implementation notes — test construction-site rewrite pattern

For each conversion test `makeService`, replace:
```swift
let cryptoService = CryptoPriceService(clients: […], database: database)
…
let service = FullConversionService(
  exchangeRates: …, stockPrices: …, cryptoPrices: cryptoService,
  cryptoRegistrations: { registrations })
```
with:
```swift
let registrationsById = Dictionary(
  uniqueKeysWithValues: registrations.map { ($0.id, $0) })
let cryptoService = CryptoPriceService(
  clients: […], database: database,
  metadataLookup: { registrationsById[$0] })
…
let service = FullConversionService(
  exchangeRates: …, stockPrices: …, cryptoPrices: cryptoService)
```
Keep each suite's `registrations` / `providerMappings` plumbing and **every `#expect`
unchanged**. For `FullConversionErrorPropagationTests` (line 34) whose closure throws, port the
throwing behaviour into the `metadataLookup` closure so the error still surfaces:
`metadataLookup: { _ in throw … }` — verify the suite still asserts the same thrown error
propagates through `convert`/`convertResult` (it does, because `registration(for:)` rethrows the
lookup error, which surfaces at price time exactly as the old `cryptoRegistrations()` throw did).

Wrapped-native tests (`WrappedNativeConversionTests`): registrations are keyed by **native** id;
the `metadataLookup` dictionary must contain the `"<chain>:native"` entry so the WETH lookup
(redirected to native by `CryptoPriceService.registration(for:)`) resolves. Confirm the existing
fixtures already register the native id (they map `providerMappings` whose `instrumentId` is the
native id) — they do, so the dictionary keys line up.

### Steps

1. Remove the stored `cryptoRegistrations` property, its init param, and its doc comment from
   `FullConversionService.swift`. Build resolver in `init`.

2. Update `App/ProfileSession+CloudKitBackendBuild.swift` + the actual `CryptoPriceService`
   construction site (grep first) to attach `metadataLookup: { id in try await
   registry.cryptoRegistration(byId: id) }`; remove the `cryptoRegistrations:` arg from the
   `FullConversionService(` call (lines ~69–77).

3. Update every test construction site per the pattern above (15 call sites across the files in
   the table). Update `MoolahTests/Shared/FullConversionFactorRoutingTests.swift` (Task 3's new
   file) to the same final shape if not already written that way.

4. Build + run the FULL conversion + registry-contract suites:
   ```
   just test-mac FullConversionServiceConvertResultTests FullConversionServiceBatchTests \
     FullConversionServiceCachingTests InstrumentConversionServiceCryptoTests \
     InstrumentConversionServiceStockTests WrappedNativeConversionTests \
     FullConversionErrorPropagationTests ConvertCacheInvalidationTests \
     FullConversionFactorRoutingTests CryptoPriceServiceMetadataTests \
     CryptoPriceServiceTests PreListingDailyBalanceTests StockPositionDisplayTests \
     ProfileSessionTests InstrumentRegistryContractTests \
     2>&1 | tee .agent-tmp/t4.txt
   grep -i 'failed\|error:' .agent-tmp/t4.txt
   ```
   All green, no expectation edits. Then a broad `just build-mac` to catch any other caller (e.g.
   PreviewBackend) the grep missed.

5. Grep to prove the conversion path no longer references the removed closure and that
   `allCryptoRegistrations` survives only for non-conversion callers:
   `grep -rn "cryptoRegistrations" Shared/ App/` → no hits in `FullConversionService*`.
   `grep -rn "allCryptoRegistrations" Shared/ App/ Features/` → only spam/UI/preset/search/sync
   callers remain (unchanged).

6. `just format-check`; fix; `rm .agent-tmp/t4.txt`.

7. Commit:
   ```
   git commit -am "refactor(conversion): drop cryptoRegistrations closure; inject keyed metadata into CryptoPriceService

   FullConversionService no longer scans the crypto registry on the
   conversion path. Prod wiring injects cryptoRegistration(byId:) as the
   metadata plug on CryptoPriceService; preview + all test construction
   sites updated. allCryptoRegistrations() retained for spam scan / UI /
   presets / search.

   Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
   Claude-Session: https://claude.ai/code/session_01Q4LphNRBYdAZSbgHNmmCg6"
   ```

### Ordering note (Tasks 3 + 4)

Because removing the `cryptoRegistrations` stored property and rewriting `computeUnitFactor` /
`convertResultDecision` together leave the build green only when both are done, **execute Tasks 3
and 4 on the same branch and build once after Task 4**, but keep them as two separate commits
(Task 3 = algorithm + decision rewrite + new routing test; Task 4 = closure removal +
construction-site sweep). If you prefer a single commit, fold them — but do not push a commit
that does not compile. Tasks 1 and 2 are independently buildable and committable on their own.

---

## Self-Review

**Spec coverage:**
- ✅ `PriceSource` protocol + fiat/stock/crypto sources + kind-dispatched resolver — Task 2.
- ✅ Generic `factor`/`priceIn` with the exact common-quote rule (target-fiat → source-fiat →
  USD) and deferred division — Task 3; all 7 cases verified against the spec table inline.
- ✅ Crypto self-resolution via keyed metadata cache + `cryptoRegistration(byId:)` point lookup;
  wrapped-native resolution moved inside; eviction wired into `purgeCache` — Task 1.
- ✅ `CryptoPriceService.price(for:on:)` drops `mapping:` (public); internal
  `price(for:mapping:on:)` retained for FetchRange plumbing — Task 1.
- ✅ `cryptoRegistrations` closure removed from `FullConversionService` + all construction sites
  (1 prod + preview + 15 test) — Task 4; site table enumerated.
- ✅ `pricingStatus → knownZero` preserved via resolver; `.priced`/`.unpriced`/`.spam` outcomes
  unchanged; `beforeFirstTrade → knownZero` unchanged — Task 3 (`convertResultDecision` +
  `convertResult`/`Batch` retain `beforeFirstTrade` handling).
- ✅ Batch path shape unchanged (classify → distinct keys → ≤16 group → ordered map) — Task 3
  only swaps classification source.
- ✅ `invalidateCache` still evicts `rateCache` (+ wrapped-native) and purges crypto price cache,
  now also metadata cache — Tasks 1 + 3.
- ✅ `observeRates`/`observeErrors` untouched; `ConversionError.noProviderMapping` still thrown
  for an unregistered crypto — Task 1 (`registration(for:)`).
- ✅ `allCryptoRegistrations()` retained for non-conversion callers — Task 4 grep gate.
- ✅ Behaviour-neutrality suites pass with unchanged expectations — gated in Tasks 3 + 4.
- ✅ New tests additive: metadata cache (Task 1), per-source quote/status (Task 2), factor
  routing per kind pair incl. AUD→GBP direct + JPY→ETH exact-round-trip (Task 3).

**Placeholder scan:** No `TODO`/`FIXME`/`<…>`/`…` left in code blocks; every snippet uses real
type/method names (`computeUnitFactor`, `priceIn`, `PriceSourceResolver`, `registration(for:)`,
`cryptoRegistration(byId:)`, `WrappedNativeContracts.nativePricingInstrumentId`,
`ConversionError.noProviderMapping`, `CryptoPriceError.beforeFirstTrade`).

**Type consistency:** `PriceSource.quote(on:) -> (perUnit: Decimal, nativeQuote: Instrument)`
(Option A, async) is the single surface used by `priceIn`; `pricingStatus(on:) ->
TokenPricingStatus` used by `convertResultDecision`. `metadataLookup: @Sendable (String) async
throws -> CryptoRegistration?` matches `cryptoRegistration(byId:)`'s shape. `UnitFactor`,
`RateCacheKey`, `ConvertResultDecision` reused unchanged from the existing service.

**Open verification item for the implementer (do not skip):** before editing `purgeCache`'s
wrapped-native eviction and the prod `CryptoPriceService` construction site, run the two greps
named in Tasks 1 and 4 (`chainId(from`, `CryptoPriceService( App/`) to confirm the exact helper
availability and construction location, then adapt the snippet to what's actually there.
