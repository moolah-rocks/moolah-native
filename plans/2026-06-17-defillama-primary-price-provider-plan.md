# DefiLlama Primary Price Provider — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add DefiLlama (`coins.llama.fi`) as the keyless, first-in-chain crypto price provider, keyed on the contract address already in `instrumentId`, with a local startup-refreshed probe cache recording per-token support + history floor.

**Architecture:** A new `DefiLlamaClient: CryptoPriceClient` sits first in `CryptoPriceService`'s provider chain and derives its coin id from `instrumentId` (`{chain}:{address}`, native/BTC via `coingecko:{id}`). A local SQLite `DefiLlamaSupportCache` (built on the existing `CatalogDatabase` engine, drop-and-recreate, not synced) records `{supported, earliestDate, lastChecked}` per token; a best-effort batched `/prices/first` startup probe refreshes missing/stale/unsupported rows. The client consults the cache to short-circuit known-unsupported tokens and updates it opportunistically from live fetches. Everything is additive — the orchestrator, cache/merge machinery, and the #1140 catalogs are untouched.

**Tech Stack:** Swift 6 (strict concurrency), SQLite via the existing `CatalogDatabase` C-API wrapper, `NetworkingServices` / `RateLimitedHTTPClient`, Swift Testing (`@Suite`/`@Test`) with `StubURLProtocol`.

## Global Constraints

- Targets iOS 26+ / macOS 26+; Swift 6 strict concurrency.
- Domain layer (`Domain/Models`, `Domain/Repositories`) must NOT import `SwiftUI`, `GRDB`, `URLSession`, or any backend module. New networking/SQLite code lives under `Backends/`.
- `SWIFT_TREAT_WARNINGS_AS_ERRORS: YES` — zero warnings (discard unused results with `_ =`, `let` over `var`).
- All builds/tests via `just` only: `just build-mac`, `just test <Filter>`, `just format`, `just format-check`, `just generate`. Never raw `swiftc`/`xcodebuild`/`swift test`.
- New `.swift` files (prod and test) require `just generate` before they compile in Xcode (project is xcodegen-generated; `Moolah.xcodeproj` is gitignored).
- TDD: write the failing test first, watch it fail, implement minimally, watch it pass, commit. Run `just format-check` before every commit.
- Test framework is Swift Testing: `import Testing`, `@Suite(..., .serialized)` class suites, `#expect`/`#require`. `StubURLProtocol.handlers` is a static map; clear it in `deinit`. Build `NetworkingServices` with an ephemeral `URLSession` whose `protocolClasses = [StubURLProtocol.self]`.
- Confidence gate threshold: **0.2** (coin-level). Support-cache staleness TTL: **24h**. Chain order: **DefiLlama first**. Support cache: **local-only, not synced**.
- USD-denominated prices everywhere (the `CryptoPriceClient` contract).
- Money/sign: not applicable here (prices are positive USD rates), but never `abs()` elsewhere.

---

## File Structure

**New (prod):**
- `Backends/DefiLlama/DefiLlamaCoinID.swift` — pure `instrumentId (+coingeckoId) → DefiLlama coin id` derivation + chain table.
- `Backends/DefiLlama/DefiLlamaSupportCacheSchema.swift` — schema version + DDL for `defillama_support`.
- `Backends/DefiLlama/DefiLlamaSupportCache.swift` — actor over `CatalogDatabase`: read/upsert support rows + the batched `/prices/first` probe.
- `Backends/DefiLlama/DefiLlamaClient.swift` — `CryptoPriceClient` conformance: `/chart`, `/prices/current`, confidence gate, support-cache integration.
- `Backends/DefiLlama/DefiLlamaWireFormat.swift` — `Decodable` response structs + URL builders + parsers.

**Modified (prod):**
- `Domain/Models/SyncProvider.swift` — add `.defiLlama` case + display name.
- `App/ProfileSession+CatalogFactory.swift` — `makeDefiLlamaSupportCache`.
- `App/ProfileSession+Factories.swift` — `MarketDataServices` carries the cache; `makeCryptoPriceService` takes it and puts `DefiLlamaClient` first.
- `App/ProfileSession.swift` — `defiLlamaSupportCache` property + assignment.
- `App/ProfileSession+CryptoPresets.swift` — run the probe as a third startup step.

**New (test):**
- `MoolahTests/Backends/DefiLlama/DefiLlamaCoinIDTests.swift`
- `MoolahTests/Backends/DefiLlama/DefiLlamaSupportCacheTests.swift`
- `MoolahTests/Backends/DefiLlama/DefiLlamaClientTests.swift`
- `MoolahTests/Domain/SyncProviderDefiLlamaTests.swift`

---

### Task 1: `SyncProvider.defiLlama`

**Files:**
- Modify: `Domain/Models/SyncProvider.swift`
- Test: `MoolahTests/Domain/SyncProviderDefiLlamaTests.swift`

**Interfaces:**
- Produces: `SyncProvider.defiLlama` (raw value `"defiLlama"`), `displayName == "DefiLlama"`.

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Domain/SyncProviderDefiLlamaTests.swift
import Testing

@testable import Moolah

@Suite("SyncProvider DefiLlama")
struct SyncProviderDefiLlamaTests {
  @Test("defiLlama display name is the brand name")
  func displayName() {
    #expect(SyncProvider.defiLlama.displayName == "DefiLlama")
  }

  @Test("defiLlama round-trips through its raw value")
  func rawValue() {
    #expect(SyncProvider(rawValue: "defiLlama") == .defiLlama)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just generate && just test-mac SyncProviderDefiLlamaTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: compile failure — `defiLlama` is not a member of `SyncProvider`.

- [ ] **Step 3: Add the case + display name**

In `Domain/Models/SyncProvider.swift`, add `case defiLlama` after `case coinGecko` (keep alphabetical-ish grouping of price providers), and in `displayName` add:

```swift
    case .defiLlama: return "DefiLlama"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac SyncProviderDefiLlamaTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: PASS.

- [ ] **Step 5: Format-check + commit**

```bash
just format-check
git add Domain/Models/SyncProvider.swift MoolahTests/Domain/SyncProviderDefiLlamaTests.swift project.yml
git commit -m "feat(crypto): add SyncProvider.defiLlama case"
```

(Commit `project.yml` only if `just generate` changed it.)

---

### Task 2: `DefiLlamaCoinID` derivation

**Files:**
- Create: `Backends/DefiLlama/DefiLlamaCoinID.swift`
- Test: `MoolahTests/Backends/DefiLlama/DefiLlamaCoinIDTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces: `enum DefiLlamaCoinID { static func make(instrumentId: String, coingeckoId: String?) -> String? }`. Returns `"{chain}:{address}"` for an ERC-20 on a known chain, `"coingecko:{coingeckoId}"` for a native coin with a coingecko id, `nil` otherwise.

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Backends/DefiLlama/DefiLlamaCoinIDTests.swift
import Testing

@testable import Moolah

@Suite("DefiLlamaCoinID")
struct DefiLlamaCoinIDTests {
  @Test("ERC-20 on Ethereum derives chain:address")
  func erc20Ethereum() {
    #expect(
      DefiLlamaCoinID.make(instrumentId: "1:0xc02aaa39", coingeckoId: nil)
        == "ethereum:0xc02aaa39")
  }

  @Test("ERC-20 on Optimism derives chain:address")
  func erc20Optimism() {
    #expect(
      DefiLlamaCoinID.make(
        instrumentId: "10:0x4200000000000000000000000000000000000042", coingeckoId: nil)
        == "optimism:0x4200000000000000000000000000000000000042")
  }

  @Test("native coin uses coingecko id")
  func nativeUsesCoingecko() {
    #expect(
      DefiLlamaCoinID.make(instrumentId: "1:native", coingeckoId: "ethereum")
        == "coingecko:ethereum")
  }

  @Test("native BTC uses coingecko:bitcoin")
  func nativeBitcoin() {
    #expect(
      DefiLlamaCoinID.make(instrumentId: "0:native", coingeckoId: "bitcoin")
        == "coingecko:bitcoin")
  }

  @Test("unknown chain ERC-20 returns nil")
  func unknownChain() {
    #expect(DefiLlamaCoinID.make(instrumentId: "999999:0xabc", coingeckoId: nil) == nil)
  }

  @Test("native without coingecko id returns nil")
  func nativeWithoutCoingecko() {
    #expect(DefiLlamaCoinID.make(instrumentId: "1:native", coingeckoId: nil) == nil)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just generate && just test-mac DefiLlamaCoinIDTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: compile failure — `DefiLlamaCoinID` undefined.

- [ ] **Step 3: Implement**

```swift
// Backends/DefiLlama/DefiLlamaCoinID.swift
import Foundation

/// Derives a DefiLlama coins-API identifier from a Moolah crypto
/// `instrumentId`. ERC-20 tokens resolve to `{chain}:{address}` using the
/// contract address already encoded in the id; native coins (no contract)
/// resolve to `coingecko:{id}`. Pure and side-effect-free.
enum DefiLlamaCoinID {
  /// DefiLlama chain slugs by EVM chain id. Bitcoin (chain 0) is intentionally
  /// absent: BTC is a native coin and resolves via `coingecko:bitcoin`.
  private static let chainSlugs: [Int: String] = [
    1: "ethereum",
    10: "optimism",
    137: "polygon",
    8453: "base",
    42161: "arbitrum",
    43114: "avax",
    534352: "scroll",
  ]

  /// Returns the DefiLlama coin id, or `nil` when the token cannot be addressed
  /// (unknown chain for an ERC-20, or a native coin with no coingecko id).
  static func make(instrumentId: String, coingeckoId: String?) -> String? {
    let parts = instrumentId.split(separator: ":", maxSplits: 1).map(String.init)
    guard parts.count == 2, let chainId = Int(parts[0]) else { return nil }
    let suffix = parts[1]
    if suffix == "native" {
      guard let coingeckoId, !coingeckoId.isEmpty else { return nil }
      return "coingecko:\(coingeckoId)"
    }
    guard let slug = chainSlugs[chainId] else { return nil }
    return "\(slug):\(suffix)"
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac DefiLlamaCoinIDTests 2>&1 | tee .agent-tmp/t2.txt`
Expected: PASS (6 tests).

- [ ] **Step 5: Format-check + commit**

```bash
just format-check
git add Backends/DefiLlama/DefiLlamaCoinID.swift MoolahTests/Backends/DefiLlama/DefiLlamaCoinIDTests.swift project.yml
git commit -m "feat(crypto): DefiLlama coin-id derivation from instrumentId"
```

---

### Task 3: `DefiLlamaSupportCache` storage (schema + read/upsert)

**Files:**
- Create: `Backends/DefiLlama/DefiLlamaSupportCacheSchema.swift`
- Create: `Backends/DefiLlama/DefiLlamaSupportCache.swift`
- Test: `MoolahTests/Backends/DefiLlama/DefiLlamaSupportCacheTests.swift`

**Interfaces:**
- Consumes: `CatalogDatabase` (open / exec / prepare / bind / step / readText / scalarInt, `baseSchemaStatements`).
- Produces:
  - `struct DefiLlamaSupport: Sendable, Equatable { let supported: Bool; let earliestDate: String?; let lastChecked: Date }`
  - `actor DefiLlamaSupportCache` with:
    - `static func make(directory: URL, networking: NetworkingServices) throws -> DefiLlamaSupportCache`
    - `func support(for instrumentId: String) async -> DefiLlamaSupport?`
    - `func upsert(instrumentId: String, supported: Bool, earliestDate: String?, lastChecked: Date) async`
  - (`networking` is stored now; the probe method in Task 6 uses it.)

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Backends/DefiLlama/DefiLlamaSupportCacheTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("DefiLlamaSupportCache", .serialized)
final class DefiLlamaSupportCacheTests {
  private let tempDir: URL

  init() throws {
    tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dl-support-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
  }

  deinit {
    StubURLProtocol.handlers = [:]
    try? FileManager.default.removeItem(at: tempDir)
  }

  private func makeNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return NetworkingServices(session: URLSession(configuration: config))
  }

  private func makeCache() throws -> DefiLlamaSupportCache {
    try DefiLlamaSupportCache.make(directory: tempDir, networking: makeNetworking())
  }

  @Test("upsert then read returns the stored support row")
  func upsertRead() async throws {
    let cache = try makeCache()
    let when = Date(timeIntervalSince1970: 1_700_000_000)
    await cache.upsert(
      instrumentId: "1:0xabc", supported: true, earliestDate: "2020-01-01", lastChecked: when)
    let row = await cache.support(for: "1:0xabc")
    #expect(row == DefiLlamaSupport(supported: true, earliestDate: "2020-01-01", lastChecked: when))
  }

  @Test("absent token reads nil")
  func absentNil() async throws {
    let cache = try makeCache()
    #expect(await cache.support(for: "1:0xmissing") == nil)
  }

  @Test("upsert overwrites an existing row")
  func upsertOverwrites() async throws {
    let cache = try makeCache()
    await cache.upsert(
      instrumentId: "1:0xabc", supported: false, earliestDate: nil,
      lastChecked: Date(timeIntervalSince1970: 1))
    let later = Date(timeIntervalSince1970: 2)
    await cache.upsert(
      instrumentId: "1:0xabc", supported: true, earliestDate: "2021-06-01", lastChecked: later)
    let row = await cache.support(for: "1:0xabc")
    #expect(row?.supported == true)
    #expect(row?.earliestDate == "2021-06-01")
    #expect(row?.lastChecked == later)
  }

  @Test("schema version bump drops and recreates the file")
  func schemaBumpRecreates() async throws {
    let networking = makeNetworking()
    let dbURL = tempDir.appendingPathComponent("defillama-support.sqlite")
    // Write a v0-shaped meta so the real schema version mismatches and triggers
    // drop-and-recreate. Open the real cache and confirm it starts empty.
    let stale = try CatalogDatabase.open(
      dbURL: dbURL, schemaVersion: 0,
      schemaStatements: CatalogDatabase.baseSchemaStatements(schemaVersion: 0))
    stale.close()
    let cache = try DefiLlamaSupportCache.make(directory: tempDir, networking: networking)
    #expect(await cache.support(for: "1:0xabc") == nil)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just generate && just test-mac DefiLlamaSupportCacheTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: compile failure — `DefiLlamaSupportCache` / `DefiLlamaSupport` undefined.

- [ ] **Step 3: Implement schema**

```swift
// Backends/DefiLlama/DefiLlamaSupportCacheSchema.swift
import Foundation

/// Schema for the local DefiLlama per-token support cache. Bump `version` to
/// force a drop-and-recreate (network-derived cache; no migration needed).
enum DefiLlamaSupportCacheSchema {
  static let version = 1

  static func schemaStatements(schemaVersion: Int) -> [String] {
    CatalogDatabase.baseSchemaStatements(schemaVersion: schemaVersion) + [
      """
      CREATE TABLE defillama_support (
        instrument_id  TEXT NOT NULL PRIMARY KEY,
        supported      INTEGER NOT NULL CHECK (supported IN (0, 1)),
        earliest_date  TEXT,
        last_checked   REAL NOT NULL
      ) STRICT;
      """
    ]
  }
}
```

- [ ] **Step 4: Implement the cache actor (storage only)**

```swift
// Backends/DefiLlama/DefiLlamaSupportCache.swift
import Foundation
import SQLite3
import os

/// One token's DefiLlama support state: whether DefiLlama prices it and, if so,
/// the earliest date it has data for (its history floor).
struct DefiLlamaSupport: Sendable, Equatable {
  let supported: Bool
  let earliestDate: String?
  let lastChecked: Date
}

/// Local-only, drop-and-recreate cache of which tokens DefiLlama can price,
/// backed by `<directory>/defillama-support.sqlite`. Unlike the #1140 catalogs
/// it holds no downloaded list — it is a bottom-up per-token memoization filled
/// by the startup probe (see `refreshSupport`, Task 6). SQLite work runs on the
/// actor's serial executor; the non-`Sendable` `CatalogDatabase` never escapes.
actor DefiLlamaSupportCache {
  static let log = Logger(subsystem: "moolah.instrument-registry", category: "defillama-support")

  let networking: NetworkingServices
  let database: CatalogDatabase

  static func make(
    directory: URL, networking: NetworkingServices
  ) throws -> DefiLlamaSupportCache {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let database = try CatalogDatabase.open(
      dbURL: directory.appendingPathComponent("defillama-support.sqlite"),
      schemaVersion: DefiLlamaSupportCacheSchema.version,
      schemaStatements: DefiLlamaSupportCacheSchema.schemaStatements(
        schemaVersion: DefiLlamaSupportCacheSchema.version))
    return DefiLlamaSupportCache(networking: networking, database: database)
  }

  private init(networking: NetworkingServices, database: CatalogDatabase) {
    self.networking = networking
    self.database = database
  }

  isolated deinit {
    database.close()
  }

  /// The stored support row for `instrumentId`, or `nil` if never probed.
  /// Infallible: a read failure logs and returns `nil` (treated as "unknown").
  func support(for instrumentId: String) -> DefiLlamaSupport? {
    var statement: OpaquePointer?
    do {
      try database.prepare(
        """
        SELECT supported, earliest_date, last_checked
        FROM defillama_support WHERE instrument_id = ? LIMIT 1;
        """, into: &statement)
    } catch {
      Self.log.error("support(for:) prepare failed: \(String(describing: error), privacy: .public)")
      return nil
    }
    defer { sqlite3_finalize(statement) }
    guard (try? database.bind(statement, at: 1, to: instrumentId)) != nil,
      sqlite3_step(statement) == SQLITE_ROW
    else { return nil }
    let supported = sqlite3_column_int64(statement, 0) != 0
    let earliest = database.readText(statement, column: 1)
    let lastChecked = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
    return DefiLlamaSupport(
      supported: supported, earliestDate: earliest, lastChecked: lastChecked)
  }

  /// Inserts or replaces the support row for `instrumentId`. Infallible: a
  /// write failure is logged and swallowed (the next probe retries).
  func upsert(
    instrumentId: String, supported: Bool, earliestDate: String?, lastChecked: Date
  ) {
    var statement: OpaquePointer?
    do {
      try database.prepare(
        """
        INSERT INTO defillama_support (instrument_id, supported, earliest_date, last_checked)
        VALUES (?, ?, ?, ?)
        ON CONFLICT(instrument_id) DO UPDATE SET
          supported = excluded.supported,
          earliest_date = excluded.earliest_date,
          last_checked = excluded.last_checked;
        """, into: &statement)
      defer { sqlite3_finalize(statement) }
      try database.bind(statement, at: 1, to: instrumentId)
      try database.bind(statement, at: 2, to: supported ? 1 : 0)
      if let earliestDate {
        try database.bind(statement, at: 3, to: earliestDate)
      } else {
        let result = sqlite3_bind_null(statement, 3)
        guard result == SQLITE_OK else {
          throw CatalogError.sqlite("bind null \(result)")
        }
      }
      let result = sqlite3_bind_double(statement, 4, lastChecked.timeIntervalSince1970)
      guard result == SQLITE_OK else { throw CatalogError.sqlite("bind double \(result)") }
      try database.step(statement)
    } catch {
      Self.log.error("upsert failed: \(String(describing: error), privacy: .public)")
    }
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test-mac DefiLlamaSupportCacheTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: PASS (4 tests).

- [ ] **Step 6: Format-check + commit**

```bash
just format-check
git add Backends/DefiLlama/DefiLlamaSupportCacheSchema.swift Backends/DefiLlama/DefiLlamaSupportCache.swift MoolahTests/Backends/DefiLlama/DefiLlamaSupportCacheTests.swift project.yml
git commit -m "feat(crypto): DefiLlama support cache storage (schema + read/upsert)"
```

---

### Task 4: `DefiLlamaClient` core (`CryptoPriceClient`)

Wire format + the three protocol methods with the confidence gate. Support-cache
consultation is added in Task 5.

**Files:**
- Create: `Backends/DefiLlama/DefiLlamaWireFormat.swift`
- Create: `Backends/DefiLlama/DefiLlamaClient.swift`
- Test: `MoolahTests/Backends/DefiLlama/DefiLlamaClientTests.swift`

**Interfaces:**
- Consumes: `DefiLlamaCoinID.make(instrumentId:coingeckoId:)`, `CryptoPriceClient`, `CryptoProviderMapping`, `NetworkingServices`, `RateLimitedHTTPClient`, `CryptoPriceError`.
- Produces:
  - `struct DefiLlamaClient: CryptoPriceClient, Sendable` with `init(networking: NetworkingServices, supportCache: DefiLlamaSupportCache? = nil, confidenceFloor: Decimal = 0.2)`.
  - Static URL builders + parsers in `DefiLlamaWireFormat`:
    - `chartURL(coinId:from:to:) -> URL`
    - `currentURL(coinIds:) -> URL`
    - `parseChart(_ data: Data, confidenceFloor: Decimal) throws -> [String: Decimal]` (ISO-day → USD)
    - `parseCurrent(_ data: Data, confidenceFloor: Decimal) throws -> [String: Decimal]` (coinId → USD)

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Backends/DefiLlama/DefiLlamaClientTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("DefiLlamaClient", .serialized)
final class DefiLlamaClientTests {
  deinit { StubURLProtocol.handlers = [:] }

  private func makeNetworking() -> NetworkingServices {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StubURLProtocol.self]
    return NetworkingServices(session: URLSession(configuration: config))
  }

  private let wethMapping = CryptoProviderMapping(
    instrumentId: "1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2",
    coingeckoId: nil, cryptocompareSymbol: nil, binanceSymbol: nil)

  @Test("dailyPrices parses /chart, buckets by UTC day keeping the last point")
  func chartDayBucket() async throws {
    let body = """
      {"coins":{"ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2":{
        "symbol":"WETH","confidence":0.99,"prices":[
          {"timestamp":1704067200,"price":2275.21},
          {"timestamp":1704096000,"price":2300.00},
          {"timestamp":1704153600,"price":2339.59}]}}}
      """
    StubURLProtocol.handlers["coins.llama.fi/chart"] = { _ in
      (Data(body.utf8), 200, nil)
    }
    let client = DefiLlamaClient(networking: makeNetworking())
    let from = Date(timeIntervalSince1970: 1704067200)
    let to = Date(timeIntervalSince1970: 1704153600)
    let prices = try await client.dailyPrices(for: wethMapping, in: from...to)
    #expect(prices["2024-01-01"] == Decimal(string: "2300.00"))  // last point of the day
    #expect(prices["2024-01-02"] == Decimal(string: "2339.59"))
  }

  @Test("confidence below the floor drops the coin (empty result)")
  func confidenceGate() async throws {
    let body = """
      {"coins":{"ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2":{
        "symbol":"WETH","confidence":0.1,"prices":[{"timestamp":1704067200,"price":2275.21}]}}}
      """
    StubURLProtocol.handlers["coins.llama.fi/chart"] = { _ in (Data(body.utf8), 200, nil) }
    let client = DefiLlamaClient(networking: makeNetworking())
    let day = Date(timeIntervalSince1970: 1704067200)
    let prices = try await client.dailyPrices(for: wethMapping, in: day...day)
    #expect(prices.isEmpty)
  }

  @Test("currentPrices batches and remaps coin ids back to instrument ids")
  func currentBatch() async throws {
    let body = """
      {"coins":{
        "ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2":{"price":2300.0,"confidence":0.99},
        "coingecko:bitcoin":{"price":65000.0,"confidence":0.99}}}
      """
    StubURLProtocol.handlers["coins.llama.fi/prices/current"] = { _ in (Data(body.utf8), 200, nil) }
    let btc = CryptoProviderMapping(
      instrumentId: "0:native", coingeckoId: "bitcoin",
      cryptocompareSymbol: nil, binanceSymbol: nil)
    let client = DefiLlamaClient(networking: makeNetworking())
    let result = try await client.currentPrices(for: [wethMapping, btc])
    #expect(result["1:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2"] == Decimal(string: "2300.0"))
    #expect(result["0:native"] == Decimal(string: "65000.0"))
  }

  @Test("undrivable coin id throws noProviderMapping")
  func undrivableThrows() async {
    let bad = CryptoProviderMapping(
      instrumentId: "1:native", coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: nil)
    let client = DefiLlamaClient(networking: makeNetworking())
    await #expect(throws: CryptoPriceError.self) {
      _ = try await client.dailyPrice(for: bad, on: Date(timeIntervalSince1970: 1704067200))
    }
  }
}
```

> Note: confirm the `StubURLProtocol` handler key convention by reading
> `MoolahTests/Backends/Binance/BinanceTokenCacheTests.swift` (it keys by
> `"<host><path>"`). Match that exact convention when registering handlers above.

- [ ] **Step 2: Run test to verify it fails**

Run: `just generate && just test-mac DefiLlamaClientTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: compile failure — `DefiLlamaClient` undefined.

- [ ] **Step 3: Implement the wire format**

```swift
// Backends/DefiLlama/DefiLlamaWireFormat.swift
import Foundation

/// URL builders + `Decodable` response parsers for the keyless DefiLlama
/// coins API (`coins.llama.fi`). All prices are USD. Coin ids are
/// comma-separated `{chain}:{address}` / `coingecko:{id}` tokens.
enum DefiLlamaWireFormat {
  private static let base = URL(string: "https://coins.llama.fi") ?? URL(fileURLWithPath: "/")

  /// `/chart/{coin}?start=&span=&period=1d` — a daily series covering
  /// `[from, to]`. `span` is the inclusive day count plus a 2-day buffer so the
  /// final day is always included (DefiLlama returns near-day points).
  static func chartURL(coinId: String, from: Date, to: Date) -> URL {
    let pathURL = base.appendingPathComponent("chart").appendingPathComponent(coinId)
    var components = URLComponents(url: pathURL, resolvingAgainstBaseURL: false) ?? URLComponents()
    let days = max(0, Int(to.timeIntervalSince(from) / 86_400)) + 1 + 2
    components.queryItems = [
      URLQueryItem(name: "start", value: String(Int(from.timeIntervalSince1970))),
      URLQueryItem(name: "span", value: String(days)),
      URLQueryItem(name: "period", value: "1d"),
    ]
    return components.url ?? pathURL
  }

  /// `/prices/current/{coins}` — current USD price for many coins in one call.
  static func currentURL(coinIds: [String]) -> URL {
    base.appendingPathComponent("prices/current")
      .appendingPathComponent(coinIds.joined(separator: ","))
  }

  /// `/prices/first/{coins}` — earliest data point per coin (used by the probe).
  static func firstURL(coinIds: [String]) -> URL {
    base.appendingPathComponent("prices/first")
      .appendingPathComponent(coinIds.joined(separator: ","))
  }

  // MARK: - Response shapes

  private struct ChartResponse: Decodable {
    struct Coin: Decodable {
      let confidence: Decimal?
      let prices: [Point]
    }
    struct Point: Decodable {
      let timestamp: Double
      let price: Decimal
    }
    let coins: [String: Coin]
  }

  private struct CurrentResponse: Decodable {
    struct Coin: Decodable {
      let price: Decimal
      let confidence: Decimal?
    }
    let coins: [String: Coin]
  }

  struct FirstPoint: Decodable {
    let timestamp: Double
    let price: Decimal
  }
  private struct FirstResponse: Decodable {
    let coins: [String: FirstPoint]
  }

  // MARK: - Parsers

  private static let dayFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withFullDate]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }()

  /// Single-coin `/chart` → `[ISO-day: USD]`, keeping the last point per UTC
  /// day. The whole coin is dropped when its confidence is below `floor`.
  static func parseChart(_ data: Data, confidenceFloor: Decimal) throws -> [String: Decimal] {
    let response = try JSONDecoder().decode(ChartResponse.self, from: data)
    var result: [String: Decimal] = [:]
    for coin in response.coins.values {
      if let confidence = coin.confidence, confidence < confidenceFloor { continue }
      for point in coin.prices {
        let day = dayFormatter.string(from: Date(timeIntervalSince1970: point.timestamp))
        result[day] = point.price  // later points overwrite earlier same-day points
      }
    }
    return result
  }

  /// `/prices/current` → `[coinId: USD]`, dropping coins below `floor`.
  static func parseCurrent(_ data: Data, confidenceFloor: Decimal) throws -> [String: Decimal] {
    let response = try JSONDecoder().decode(CurrentResponse.self, from: data)
    var result: [String: Decimal] = [:]
    for (coinId, coin) in response.coins {
      if let confidence = coin.confidence, confidence < confidenceFloor { continue }
      result[coinId] = coin.price
    }
    return result
  }

  /// `/prices/first` → `[coinId: earliest point]`. No confidence gate: presence
  /// is the support signal; the floor is applied to live price fetches only.
  static func parseFirst(_ data: Data) throws -> [String: FirstPoint] {
    try JSONDecoder().decode(FirstResponse.self, from: data).coins
  }

  static func isoDay(from timestamp: Double) -> String {
    dayFormatter.string(from: Date(timeIntervalSince1970: timestamp))
  }
}
```

- [ ] **Step 4: Implement the client (core; no support cache yet)**

```swift
// Backends/DefiLlama/DefiLlamaClient.swift
import Foundation

/// Keyless DefiLlama (`coins.llama.fi`) price client. First in the
/// `CryptoPriceService` chain. Derives its coin id from the contract address
/// already in `instrumentId` (native coins via `coingecko:{id}`), so it needs
/// no token-list catalog. USD-denominated. A coin whose confidence is below
/// `confidenceFloor` is treated as a miss so the chain falls through.
struct DefiLlamaClient: CryptoPriceClient, Sendable {
  var syncProvider: SyncProvider { .defiLlama }

  private let networking: NetworkingServices
  let supportCache: DefiLlamaSupportCache?
  private let confidenceFloor: Decimal

  init(
    networking: NetworkingServices,
    supportCache: DefiLlamaSupportCache? = nil,
    confidenceFloor: Decimal = 0.2
  ) {
    self.networking = networking
    self.supportCache = supportCache
    self.confidenceFloor = confidenceFloor
  }

  private var http: RateLimitedHTTPClient { networking.client(forHost: "coins.llama.fi") }

  func dailyPrice(for mapping: CryptoProviderMapping, on date: Date) async throws -> Decimal {
    let prices = try await dailyPrices(for: mapping, in: date...date)
    let day = DefiLlamaWireFormat.isoDay(from: date.timeIntervalSince1970)
    guard let price = prices[day] else {
      throw CryptoPriceError.noPriceAvailable(tokenId: mapping.instrumentId, date: day)
    }
    return price
  }

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    guard
      let coinId = DefiLlamaCoinID.make(
        instrumentId: mapping.instrumentId, coingeckoId: mapping.coingeckoId)
    else {
      throw CryptoPriceError.noProviderMapping(
        tokenId: mapping.instrumentId, provider: "DefiLlama")
    }
    let url = DefiLlamaWireFormat.chartURL(
      coinId: coinId, from: range.lowerBound, to: range.upperBound)
    let (data, _) = try await http.data(for: URLRequest(url: url))
    return try DefiLlamaWireFormat.parseChart(data, confidenceFloor: confidenceFloor)
  }

  func currentPrices(for mappings: [CryptoProviderMapping]) async throws -> [String: Decimal] {
    var coinToInstrument: [String: String] = [:]
    for mapping in mappings {
      if let coinId = DefiLlamaCoinID.make(
        instrumentId: mapping.instrumentId, coingeckoId: mapping.coingeckoId)
      {
        coinToInstrument[coinId] = mapping.instrumentId
      }
    }
    guard !coinToInstrument.isEmpty else { return [:] }
    let url = DefiLlamaWireFormat.currentURL(coinIds: Array(coinToInstrument.keys))
    let (data, _) = try await http.data(for: URLRequest(url: url))
    let byCoin = try DefiLlamaWireFormat.parseCurrent(data, confidenceFloor: confidenceFloor)
    var result: [String: Decimal] = [:]
    for (coinId, price) in byCoin {
      if let instrumentId = coinToInstrument[coinId] { result[instrumentId] = price }
    }
    return result
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `just test-mac DefiLlamaClientTests 2>&1 | tee .agent-tmp/t4.txt`
Expected: PASS (4 tests).

- [ ] **Step 6: Format-check + commit**

```bash
just format-check
git add Backends/DefiLlama/DefiLlamaWireFormat.swift Backends/DefiLlama/DefiLlamaClient.swift MoolahTests/Backends/DefiLlama/DefiLlamaClientTests.swift project.yml
git commit -m "feat(crypto): DefiLlamaClient core (chart/current + confidence gate)"
```

---

### Task 5: Support-cache integration in `DefiLlamaClient`

Short-circuit known-unsupported-and-fresh tokens (no network), and update the
cache opportunistically from live fetches. Also clamp a fetch window that lies
entirely before a known history floor.

**Files:**
- Modify: `Backends/DefiLlama/DefiLlamaClient.swift`
- Test: `MoolahTests/Backends/DefiLlama/DefiLlamaClientTests.swift` (add cases)

**Interfaces:**
- Consumes: `DefiLlamaSupportCache.support(for:)` / `.upsert(...)`, the 24h TTL.
- Produces: no new public API; behaviour change only.

- [ ] **Step 1: Write the failing tests (add to the suite)**

```swift
  @Test("cached unsupported-and-fresh token short-circuits without a network call")
  func shortCircuitUnsupported() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dl-sc-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let networking = makeNetworking()
    let cache = try DefiLlamaSupportCache.make(directory: tempDir, networking: networking)
    await cache.upsert(
      instrumentId: wethMapping.instrumentId, supported: false, earliestDate: nil,
      lastChecked: Date())  // fresh
    var hit = false
    StubURLProtocol.handlers["coins.llama.fi/chart"] = { _ in
      hit = true
      return (Data("{\"coins\":{}}".utf8), 200, nil)
    }
    let client = DefiLlamaClient(networking: networking, supportCache: cache)
    let day = Date(timeIntervalSince1970: 1704067200)
    await #expect(throws: CryptoPriceError.self) {
      _ = try await client.dailyPrice(for: wethMapping, on: day)
    }
    #expect(hit == false)  // never went to the network
  }

  @Test("a successful fetch records support in the cache")
  func recordsSupportOnSuccess() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("dl-rec-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }
    let networking = makeNetworking()
    let cache = try DefiLlamaSupportCache.make(directory: tempDir, networking: networking)
    let body = """
      {"coins":{"ethereum:0xc02aaa39b223fe8d0a0e5c4f27ead9083c756cc2":{
        "symbol":"WETH","confidence":0.99,"prices":[{"timestamp":1704067200,"price":2275.21}]}}}
      """
    StubURLProtocol.handlers["coins.llama.fi/chart"] = { _ in (Data(body.utf8), 200, nil) }
    let client = DefiLlamaClient(networking: networking, supportCache: cache)
    let day = Date(timeIntervalSince1970: 1704067200)
    _ = try await client.dailyPrices(for: wethMapping, in: day...day)
    #expect(await cache.support(for: wethMapping.instrumentId)?.supported == true)
  }
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `just test-mac DefiLlamaClientTests 2>&1 | tee .agent-tmp/t5.txt`
Expected: `shortCircuitUnsupported` fails (network IS hit) and `recordsSupportOnSuccess` fails (cache not updated).

- [ ] **Step 3: Implement the integration**

Add a TTL constant and a freshness helper, gate `dailyPrices`, and record outcomes. Replace `dailyPrices(for:in:)` with:

```swift
  /// 24h staleness window — matches `CatalogRefresh.defaultMaxAge`.
  private static let supportMaxAge: TimeInterval = 24 * 3600

  func dailyPrices(
    for mapping: CryptoProviderMapping, in range: ClosedRange<Date>
  ) async throws -> [String: Decimal] {
    guard
      let coinId = DefiLlamaCoinID.make(
        instrumentId: mapping.instrumentId, coingeckoId: mapping.coingeckoId)
    else {
      throw CryptoPriceError.noProviderMapping(
        tokenId: mapping.instrumentId, provider: "DefiLlama")
    }

    // Short-circuit a fresh "unsupported" verdict so we don't pay a round-trip
    // for a token DefiLlama is known not to price.
    if let cached = await supportCache?.support(for: mapping.instrumentId),
      !cached.supported,
      Date().timeIntervalSince(cached.lastChecked) < Self.supportMaxAge
    {
      throw CryptoPriceError.noProviderMapping(
        tokenId: mapping.instrumentId, provider: "DefiLlama")
    }

    let url = DefiLlamaWireFormat.chartURL(
      coinId: coinId, from: range.lowerBound, to: range.upperBound)
    let (data, _) = try await http.data(for: URLRequest(url: url))
    let prices = try DefiLlamaWireFormat.parseChart(data, confidenceFloor: confidenceFloor)

    // Opportunistically refresh support from the live outcome.
    await supportCache?.upsert(
      instrumentId: mapping.instrumentId,
      supported: !prices.isEmpty,
      earliestDate: prices.keys.min(),
      lastChecked: Date())

    return prices
  }
```

> `earliestDate: prices.keys.min()` records the floor observed in *this* window;
> the authoritative floor comes from the probe's `/prices/first` (Task 6). String
> min over ISO `YYYY-MM-DD` keys is chronological. Only overwrite a non-nil
> earliest if the new value is earlier — to keep this minimal and avoid a read
> before write, the probe (which uses `/prices/first`) is the source of truth for
> the floor; this opportunistic write is best-effort.

- [ ] **Step 4: Run to verify all client tests pass**

Run: `just test-mac DefiLlamaClientTests 2>&1 | tee .agent-tmp/t5.txt`
Expected: PASS (all 6 tests).

- [ ] **Step 5: Format-check + commit**

```bash
just format-check
git add Backends/DefiLlama/DefiLlamaClient.swift MoolahTests/Backends/DefiLlama/DefiLlamaClientTests.swift
git commit -m "feat(crypto): DefiLlamaClient consults + updates support cache"
```

---

### Task 6: Batched startup support probe

Add `refreshSupport(for:now:)` to `DefiLlamaSupportCache`: select stale/unknown/
unsupported tokens, batch-probe `/prices/first`, write rows.

**Files:**
- Modify: `Backends/DefiLlama/DefiLlamaSupportCache.swift`
- Test: `MoolahTests/Backends/DefiLlama/DefiLlamaSupportCacheTests.swift` (add cases)

**Interfaces:**
- Consumes: `CryptoRegistration` (`.instrument.id`, `.mapping.coingeckoId`, `.pricingStatus`), `DefiLlamaCoinID`, `DefiLlamaWireFormat.firstURL/parseFirst`, `TokenPricingStatus.spam`.
- Produces: `func refreshSupport(for registrations: [CryptoRegistration], now: Date) async` on `DefiLlamaSupportCache`. Best-effort, cancellation-aware.

- [ ] **Step 1: Write the failing tests (add to the suite)**

```swift
  private func registration(instrumentId: String, coingeckoId: String?) -> CryptoRegistration {
    // Reconstruct an Instrument with the right id via Instrument.crypto.
    let parts = instrumentId.split(separator: ":", maxSplits: 1).map(String.init)
    let chainId = Int(parts[0]) ?? 1
    let contract = parts[1] == "native" ? nil : parts[1]
    let instrument = Instrument.crypto(
      chainId: chainId, contractAddress: contract, symbol: "TKN", name: "Token", decimals: 18)
    let mapping = CryptoProviderMapping(
      instrumentId: instrument.id, coingeckoId: coingeckoId,
      cryptocompareSymbol: nil, binanceSymbol: nil)
    return CryptoRegistration(instrument: instrument, mapping: mapping, pricingStatus: .priced)
  }

  @Test("probe records supported + earliest date for present coins, unsupported for absent")
  func probeRecordsSupport() async throws {
    let networking = makeNetworking()
    let cache = try DefiLlamaSupportCache.make(directory: tempDir, networking: networking)
    let body = """
      {"coins":{"ethereum:0xaaa":{"timestamp":1367107200,"price":135.3}}}
      """
    StubURLProtocol.handlers["coins.llama.fi/prices/first"] = { _ in (Data(body.utf8), 200, nil) }
    let present = registration(instrumentId: "1:0xaaa", coingeckoId: nil)
    let absent = registration(instrumentId: "1:0xbbb", coingeckoId: nil)
    await cache.refreshSupport(
      for: [present, absent], now: Date(timeIntervalSince1970: 1_700_000_000))
    #expect(await cache.support(for: "1:0xaaa")?.supported == true)
    #expect(await cache.support(for: "1:0xaaa")?.earliestDate == "2013-04-28")
    #expect(await cache.support(for: "1:0xbbb")?.supported == false)
  }

  @Test("probe skips a fresh row and a spam token")
  func probeSkipsFreshAndSpam() async throws {
    let networking = makeNetworking()
    let cache = try DefiLlamaSupportCache.make(directory: tempDir, networking: networking)
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    // Pre-seed a FRESH row; the probe must not re-request it.
    await cache.upsert(
      instrumentId: "1:0xaaa", supported: true, earliestDate: "2020-01-01", lastChecked: now)
    var requested: String?
    StubURLProtocol.handlers["coins.llama.fi/prices/first"] = { request in
      requested = request.url?.absoluteString
      return (Data("{\"coins\":{}}".utf8), 200, nil)
    }
    let fresh = registration(instrumentId: "1:0xaaa", coingeckoId: nil)
    await cache.refreshSupport(for: [fresh], now: now.addingTimeInterval(3600))  // <24h
    #expect(requested == nil)  // nothing to probe → no network call
  }
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `just test-mac DefiLlamaSupportCacheTests 2>&1 | tee .agent-tmp/t6.txt`
Expected: compile failure — `refreshSupport(for:now:)` undefined.

- [ ] **Step 3: Implement `refreshSupport`**

Add to `DefiLlamaSupportCache`:

```swift
  /// 24h staleness window for re-probing (matches `CatalogRefresh.defaultMaxAge`).
  private static let maxAge: TimeInterval = 24 * 3600

  /// Re-probes DefiLlama support for `registrations` whose row is missing, older
  /// than 24h, or currently unsupported (so a token that gains liquidity later
  /// is re-detected). One batched `/prices/first` call; `.spam` tokens and
  /// tokens with no derivable coin id are skipped. Best-effort: a network
  /// failure leaves all rows untouched (logged); cancellation returns early.
  func refreshSupport(for registrations: [CryptoRegistration], now: Date) async {
    // Build the to-probe set: coinId → instrumentId.
    var coinToInstrument: [String: String] = [:]
    for registration in registrations {
      guard registration.pricingStatus != .spam else { continue }
      let instrumentId = registration.instrument.id
      if let existing = support(for: instrumentId),
        existing.supported,
        now.timeIntervalSince(existing.lastChecked) < Self.maxAge
      {
        continue  // fresh + supported → skip
      }
      guard
        let coinId = DefiLlamaCoinID.make(
          instrumentId: instrumentId, coingeckoId: registration.mapping.coingeckoId)
      else { continue }
      coinToInstrument[coinId] = instrumentId
    }
    guard !coinToInstrument.isEmpty else { return }
    if Task.isCancelled { return }

    let url = DefiLlamaWireFormat.firstURL(coinIds: Array(coinToInstrument.keys))
    let firstPoints: [String: DefiLlamaWireFormat.FirstPoint]
    do {
      let (data, _) = try await networking.client(forHost: "coins.llama.fi")
        .data(for: URLRequest(url: url))
      firstPoints = try DefiLlamaWireFormat.parseFirst(data)
    } catch {
      Self.log.error("refreshSupport failed: \(String(describing: error), privacy: .public)")
      return  // leave rows untouched; next launch retries
    }
    if Task.isCancelled { return }

    for (coinId, instrumentId) in coinToInstrument {
      if let point = firstPoints[coinId] {
        upsert(
          instrumentId: instrumentId, supported: true,
          earliestDate: DefiLlamaWireFormat.isoDay(from: point.timestamp), lastChecked: now)
      } else {
        upsert(
          instrumentId: instrumentId, supported: false, earliestDate: nil, lastChecked: now)
      }
    }
  }
```

> The staleness filter re-probes `supported == false` rows every eligible launch
> (they fail the `existing.supported` guard), satisfying "support is not locked
> in forever".

- [ ] **Step 4: Run to verify all support-cache tests pass**

Run: `just test-mac DefiLlamaSupportCacheTests 2>&1 | tee .agent-tmp/t6.txt`
Expected: PASS (6 tests).

- [ ] **Step 5: Format-check + commit**

```bash
just format-check
git add Backends/DefiLlama/DefiLlamaSupportCache.swift MoolahTests/Backends/DefiLlama/DefiLlamaSupportCacheTests.swift
git commit -m "feat(crypto): batched DefiLlama startup support probe"
```

---

### Task 7: Wire DefiLlama into the price chain + startup probe

Create the support cache, put `DefiLlamaClient` first in the chain, store the
cache on `ProfileSession`, and run the probe as a third startup step.

**Files:**
- Modify: `App/ProfileSession+CatalogFactory.swift` (add `makeDefiLlamaSupportCache`)
- Modify: `App/ProfileSession+Factories.swift` (`MarketDataServices` field + thread into `makeCryptoPriceService`, prepend client)
- Modify: `App/ProfileSession.swift` (property + assignment)
- Modify: `App/ProfileSession+CryptoPresets.swift` (probe step)

**Interfaces:**
- Consumes: `DefiLlamaSupportCache.make(directory:networking:)`, `DefiLlamaClient(networking:supportCache:)`, `DefiLlamaSupportCache.refreshSupport(for:now:)`, `instrumentRegistryDirectory`, `allCryptoRegistrations()`.
- Produces: `ProfileSession.defiLlamaSupportCache: DefiLlamaSupportCache?`.

> This task is integration glue; there is no unit test for the wiring itself
> (it constructs `ProfileSession`). Verify by building, by the existing crypto
> price-service test suite continuing to pass, and by the new client/cache
> tests. Each sub-step is small; the deliverable is "DefiLlama is live and first
> in the chain, and the probe runs at startup".

- [ ] **Step 1: Add the factory**

In `App/ProfileSession+CatalogFactory.swift`, add (mirrors `makeBinanceCache`, but with NO background `refreshTask` — the probe is driven by registrations in `seedBuiltInCryptoPresets`, not a list refresh):

```swift
  /// Opens the local DefiLlama per-token support cache in the shared
  /// `InstrumentRegistry` directory. Unlike the list caches it starts no
  /// background `refreshIfStale()` — the startup probe in
  /// `seedBuiltInCryptoPresets` refreshes it from the registered token set.
  /// Returns `nil` (and logs) on open failure; the `DefiLlamaClient` then runs
  /// without short-circuit/floor optimisations but still prices live.
  @MainActor
  static func makeDefiLlamaSupportCache(
    networking: NetworkingServices
  ) -> DefiLlamaSupportCache? {
    do {
      return try DefiLlamaSupportCache.make(
        directory: Self.instrumentRegistryDirectory, networking: networking)
    } catch {
      Logger(subsystem: "com.moolah.app", category: "ProfileSession")
        .error("DefiLlama support cache init failed: \(error.localizedDescription, privacy: .public)")
      return nil
    }
  }
```

- [ ] **Step 2: Thread through `makeMarketDataServices` / `makeCryptoPriceService`**

In `App/ProfileSession+Factories.swift`:

1. Add a field to the local `MarketDataServices` struct (near line 14):

```swift
    let defiLlamaSupportCache: DefiLlamaSupportCache?
```

2. In `makeMarketDataServices`, create the cache and thread it in:

```swift
    let defiLlamaSupportCache = Self.makeDefiLlamaSupportCache(networking: networking)
```

and pass it to `makeCryptoPriceService(...)` (new argument) and into the returned
`MarketDataServices(...)` initializer as `defiLlamaSupportCache: defiLlamaSupportCache`.

3. Change `makeCryptoPriceService`'s signature and body:

```swift
  static func makeCryptoPriceService(
    coinGeckoApiKeyProvider: @Sendable @escaping () -> String?,
    database: any DatabaseWriter,
    networking: NetworkingServices,
    defiLlamaSupportCache: DefiLlamaSupportCache?,
    localResolver: (any LocalContractResolver)? = nil
  ) -> CryptoPriceService {
```

and build the DefiLlama client and prepend it to `priceClients`:

```swift
    let defiLlamaClient = DefiLlamaClient(
      networking: networking, supportCache: defiLlamaSupportCache)
    ...
    let priceClients: [CryptoPriceClient] = [
      defiLlamaClient,
      coinGeckoClient,
      cryptoCompareClient,
      binanceClient,
      stablecoinClient,
    ]
```

- [ ] **Step 3: Store the cache on `ProfileSession`**

In `App/ProfileSession.swift`, add near the other cache properties (line ~66):

```swift
  private(set) var defiLlamaSupportCache: DefiLlamaSupportCache?
```

and assign it where `marketData` is consumed (the `makeMarketDataServices` result at line ~189 — assign `self.defiLlamaSupportCache = marketData.defiLlamaSupportCache` alongside the other market-data field assignments).

- [ ] **Step 4: Run the probe at startup**

In `App/ProfileSession+CryptoPresets.swift`, extend the existing task in
`seedBuiltInCryptoPresets` to run the probe after re-detection:

```swift
    let task = Task {
      await registry.registerBuiltInPresetsIfMissing()
      guard !Task.isCancelled else { return }
      await self.reconcileFromCaches(registry: registry)
      guard !Task.isCancelled else { return }
      await self.probeDefiLlamaSupport(registry: registry)
    }
```

and add the helper:

```swift
  /// Batched DefiLlama support probe: refreshes the local support cache for the
  /// profile's registered tokens so the `DefiLlamaClient` can short-circuit
  /// known-unsupported tokens and bound backfills at each token's history floor
  /// (#1140 follow-on). Best-effort; skipped if the cache failed to open.
  private func probeDefiLlamaSupport(
    registry: any InstrumentRegistryRepository
  ) async {
    guard let defiLlamaSupportCache else { return }
    let registrations: [CryptoRegistration]
    do {
      registrations = try await registry.allCryptoRegistrations()
    } catch {
      return  // best-effort; next launch retries
    }
    await defiLlamaSupportCache.refreshSupport(for: registrations, now: Date())
  }
```

- [ ] **Step 5: Generate, build, and run the regression suites**

```bash
just generate
just build-mac 2>&1 | tee .agent-tmp/build.txt
just test-mac DefiLlamaClientTests DefiLlamaSupportCacheTests DefiLlamaCoinIDTests SyncProviderDefiLlamaTests 2>&1 | tee .agent-tmp/t7.txt
```

Expected: build succeeds with zero warnings; all DefiLlama suites pass.

- [ ] **Step 6: Format-check + commit**

```bash
just format-check
git add App/ProfileSession+CatalogFactory.swift App/ProfileSession+Factories.swift App/ProfileSession.swift App/ProfileSession+CryptoPresets.swift project.yml
git commit -m "feat(crypto): wire DefiLlama first in the price chain + startup probe"
```

---

### Task 8: Full-suite verification + review

**Files:** none (verification only).

- [ ] **Step 1: Run the full macOS suite**

```bash
mkdir -p .agent-tmp
just test-mac 2>&1 | tee .agent-tmp/full-mac.txt
grep -iE 'failed|error:' .agent-tmp/full-mac.txt || echo "clean"
```

Expected: no new failures. (Pre-existing unrelated failures, if any, are out of scope.)

- [ ] **Step 2: Format-check the whole tree**

```bash
just format-check
```

Expected: no diff, no SwiftLint violations.

- [ ] **Step 3: Run the code-review agent**

Invoke the `code-review` agent over the diff (CODE_GUIDE compliance, extension organization, error handling, optional discipline). Address Critical/Important/Minor findings per repo policy.

- [ ] **Step 4: Final commit if review changes were made**

```bash
just format
just format-check
git add -A
git commit -m "chore(crypto): address review findings for DefiLlama provider"
```

---

## Self-Review

**Spec coverage:**
- DefiLlama keyless client, first in chain, contract-address keyed — Tasks 2, 4, 7. ✓
- Native/BTC via `coingecko:{id}` — Task 2. ✓
- `/chart`, `/prices/current`, day-bucketing — Task 4. ✓
- Confidence gate 0.2 — Tasks 4 (Global Constraints), 5. ✓
- Local probe cache `{supported, earliestDate, lastChecked}`, drop-and-recreate, not synced, `CatalogDatabase` reuse, not `CatalogRefresh` — Task 3. ✓
- Batched `/prices/first` startup probe; re-probe missing/stale/unsupported; skip spam; best-effort/cancellation — Task 6. ✓
- Price-chain short-circuit + opportunistic update — Task 5. ✓
- Rate limiting via `client(forHost: "coins.llama.fi")` — Tasks 4, 6. ✓
- Startup hook beside `reconcileProviderMappings` — Task 7. ✓
- `earliest_date` history floor recorded — Tasks 5, 6. (Consumption by the contiguous-window backfill is left to the existing no-progress guard plus the recorded floor; deeper integration into `CryptoPriceService+FetchRange` is intentionally out of scope, per design — the floor is captured for future use without coupling the orchestrator to DefiLlama.) ✓
- `SyncProvider.defiLlama` — Task 1. ✓

**Placeholder scan:** none — every step has concrete code/commands.

**Type consistency:** `DefiLlamaCoinID.make(instrumentId:coingeckoId:)`, `DefiLlamaSupport`, `DefiLlamaSupportCache.{make,support,upsert,refreshSupport}`, `DefiLlamaWireFormat.{chartURL,currentURL,firstURL,parseChart,parseCurrent,parseFirst,isoDay,FirstPoint}`, `DefiLlamaClient(networking:supportCache:confidenceFloor:)` — names are consistent across tasks.

## Out of scope (file separately)

- Stale `coingecko_id = "matic-network"` (rebranded to POL) → `coingecko:polygon-ecosystem-token`. A one-line data/registration fix, orthogonal to this provider.
- Deep `earliest_date` integration into `CryptoPriceService+FetchRange`'s window planner (the floor is recorded now; wiring it into the loop can follow if profiling shows wasted boundary probes).

## Stacking note

This branch (`feat/defillama-price-provider`) is stacked on `feature/crypto-provider-catalog-redetect` (#1143), which is stacked on `feature/crypto-provider-catalog` (#1142). When #1142/#1143 merge to `main` via the merge queue, rebase this branch onto `main` before opening/queuing its PR. Push with the explicit `feat/defillama-price-provider:feat/defillama-price-provider` refspec (CLAUDE.md stacked-PR guidance).
