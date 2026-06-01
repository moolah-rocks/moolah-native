# Sync-Provider Error Attribution Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Every sync provider's failure carries its provider identity through to the persisted `WalletSyncState.lastError` and its UI caption.

**Architecture:** Add a `SyncProvider` domain enum. Reshape `WalletSyncError` from a bare enum into a struct `{ provider: SyncProvider?; kind: Kind }`, keeping static factories so the ~25 existing throw sites compile unchanged. Stamp provider identity once per provider at the *leaf* client boundary (`LiveAlchemyClient`, `LiveBlockscoutClient`, `CoinstashSyncSource`, `CryptoPriceService`) via an `.attributed(to:)` helper (innermost wins). The caption prefers `provider.displayName` and falls back to today's byte-identical strings when `provider == nil`.

**Tech Stack:** Swift 6, Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`), GRDB (JSON column for `lastError`), `just` build/test/format targets.

**Reference spec:** `plans/2026-05-17-sync-provider-error-attribution-design.md`

---

## Conventions for every task

- Tests use **Swift Testing**, not XCTest: `import Testing` / `import Foundation` / `@testable import Moolah`, `@Suite("…")`, `@Test("…")`, `#expect(...)`.
- One protocol → one extension; do not inline protocol conformances on the type declaration (project convention).
- Run a subset fast: `just test-mac <ClassOrSuite>` (the suite *type* name, e.g. `WalletSyncErrorTests`).
- Capture output: `mkdir -p .agent-tmp && just test-mac X 2>&1 | tee .agent-tmp/test-output.txt`; delete the temp file when done.
- **Per-task verification gate (all of):** `just build-mac` clean, the task's tests pass, and `just format-check` is clean. Do not proceed past a task with any of these red.
- Never edit `.swiftlint-baseline.yml`. Fix violations by changing code.
- Commit after each task with the message shown in its final step.

---

## Task 1: `SyncProvider` domain type

**Files:**
- Create: `Domain/Models/SyncProvider.swift`
- Test: `MoolahTests/Domain/Models/SyncProviderTests.swift`

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Domain/Models/SyncProviderTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("SyncProvider")
struct SyncProviderTests {
  @Test("Raw values are stable tokens")
  func rawValuesAreStable() {
    #expect(SyncProvider.alchemy.rawValue == "alchemy")
    #expect(SyncProvider.blockExplorer.rawValue == "blockExplorer")
    #expect(SyncProvider.coinstash.rawValue == "coinstash")
    #expect(SyncProvider.coinGecko.rawValue == "coinGecko")
    #expect(SyncProvider.cryptoCompare.rawValue == "cryptoCompare")
    #expect(SyncProvider.binance.rawValue == "binance")
  }

  @Test("Display names are the user-facing brand strings")
  func displayNames() {
    #expect(SyncProvider.alchemy.displayName == "Alchemy")
    #expect(SyncProvider.blockExplorer.displayName == "Blockscout")
    #expect(SyncProvider.coinstash.displayName == "Coinstash")
    #expect(SyncProvider.coinGecko.displayName == "CoinGecko")
    #expect(SyncProvider.cryptoCompare.displayName == "CryptoCompare")
    #expect(SyncProvider.binance.displayName == "Binance")
  }

  @Test("Round-trips through JSON as its raw token")
  func jsonRoundTrip() throws {
    let data = try JSONEncoder().encode(SyncProvider.blockExplorer)
    #expect(String(decoding: data, as: UTF8.self) == "\"blockExplorer\"")
    let decoded = try JSONDecoder().decode(SyncProvider.self, from: data)
    #expect(decoded == .blockExplorer)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac SyncProviderTests 2>&1 | tee .agent-tmp/t.txt`
Expected: compile failure — `cannot find 'SyncProvider' in scope`.

- [ ] **Step 3: Create the type**

```swift
// Domain/Models/SyncProvider.swift
import Foundation

/// Identifies which external data provider produced a sync failure, so
/// `WalletSyncError` can attribute the error to its source. String-backed
/// so it round-trips as a stable token inside the persisted
/// `WalletSyncState.lastError` JSON. Per-device only — not a synced
/// record, so adding a case does not touch `DataFormatVersion`.
enum SyncProvider: String, Codable, Sendable, Hashable, CaseIterable {
  case alchemy
  case blockExplorer
  case coinstash
  case coinGecko
  case cryptoCompare
  case binance

  /// User-facing brand name shown in the synced-account error caption.
  /// `.blockExplorer` is "Blockscout" — the codebase already surfaces the
  /// concrete brand "Alchemy" in captions, so this stays consistent.
  var displayName: String {
    switch self {
    case .alchemy: return "Alchemy"
    case .blockExplorer: return "Blockscout"
    case .coinstash: return "Coinstash"
    case .coinGecko: return "CoinGecko"
    case .cryptoCompare: return "CryptoCompare"
    case .binance: return "Binance"
    }
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac SyncProviderTests 2>&1 | tee .agent-tmp/t.txt`
Expected: PASS. Then `just build-mac` clean and `just format-check` clean. `rm .agent-tmp/t.txt`.

- [ ] **Step 5: Commit**

```bash
git -C . add Domain/Models/SyncProvider.swift MoolahTests/Domain/Models/SyncProviderTests.swift
git -C . commit -m "feat: add SyncProvider identity enum"
```

---

## Task 2: Reshape `WalletSyncError` to a provider-attributed struct

This is the foundational change. After it, **all ~25 existing `throw WalletSyncError.x(...)` sites must still compile unchanged** because the static factories preserve the call shape. Only enum *pattern-matching* sites break — Task 3 fixes those.

**Files:**
- Modify: `Domain/Models/WalletSyncError.swift` (full rewrite)
- Test: `MoolahTests/Domain/Models/WalletSyncErrorTests.swift` (create)

- [ ] **Step 1: Write the failing test**

```swift
// MoolahTests/Domain/Models/WalletSyncErrorTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("WalletSyncError")
struct WalletSyncErrorTests {
  @Test("Static factories produce provider-less errors")
  func factoriesAreUnattributed() {
    #expect(WalletSyncError.missingApiKey.provider == nil)
    #expect(WalletSyncError.missingApiKey.kind == .missingApiKey)
    let net = WalletSyncError.network(underlyingDescription: "boom")
    #expect(net.provider == nil)
    #expect(net.kind == .network(underlyingDescription: "boom"))
  }

  @Test("attributed(to:) stamps an unattributed error")
  func attributedStampsWhenNil() {
    let stamped = WalletSyncError.network(underlyingDescription: "x")
      .attributed(to: .alchemy)
    #expect(stamped.provider == .alchemy)
    #expect(stamped.kind == .network(underlyingDescription: "x"))
  }

  @Test("attributed(to:) is innermost-wins — does not overwrite")
  func attributedDoesNotOverwrite() {
    let inner = WalletSyncError(provider: .blockExplorer, kind: .invalidApiKey)
    let outer = inner.attributed(to: .alchemy)
    #expect(outer.provider == .blockExplorer)
  }

  @Test("New shape round-trips through JSON")
  func newShapeRoundTrips() throws {
    let original = WalletSyncError(
      provider: .coinstash, kind: .rateLimited(retryAfter: nil))
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(WalletSyncError.self, from: data)
    #expect(decoded == original)
  }

  @Test("Legacy bare-enum JSON decodes as provider: nil")
  func legacyJSONDecodes() throws {
    // Pre-attribution rows were the bare enum: a single-key object whose
    // key is the case name. This is exactly what JSONEncoder produced for
    // `enum WalletSyncError` before this change.
    let legacy = #"{"network":{"underlyingDescription":"old failure"}}"#
    let decoded = try JSONDecoder().decode(
      WalletSyncError.self, from: Data(legacy.utf8))
    #expect(decoded.provider == nil)
    #expect(decoded.kind == .network(underlyingDescription: "old failure"))
  }

  @Test("Legacy bare-enum JSON for a no-payload case decodes")
  func legacyNoPayloadCaseDecodes() throws {
    let legacy = #"{"missingApiKey":{}}"#
    let decoded = try JSONDecoder().decode(
      WalletSyncError.self, from: Data(legacy.utf8))
    #expect(decoded.provider == nil)
    #expect(decoded.kind == .missingApiKey)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac WalletSyncErrorTests 2>&1 | tee .agent-tmp/t.txt`
Expected: compile failure — `value of type 'WalletSyncError' has no member 'provider'`.

- [ ] **Step 3: Rewrite `WalletSyncError`**

Replace the entire contents of `Domain/Models/WalletSyncError.swift` with:

```swift
import Foundation

/// Structured outcome of a failed wallet/exchange/price sync. Stored in
/// `WalletSyncState.lastError` (a per-device, non-cross-device-synced
/// checkpoint) so the UI can format it without coupling the domain to
/// localised strings.
///
/// `provider` records which external provider produced the failure so the
/// caption can name it. It is `nil` when the failure is not attributable
/// to a single provider (e.g. account-data validation) or when decoding a
/// legacy row written before attribution existed.
struct WalletSyncError: Error, Codable, Sendable, Hashable {
  /// The failure category — exactly the cases the bare enum carried
  /// before attribution was added.
  enum Kind: Codable, Sendable, Hashable {
    case missingApiKey
    case invalidApiKey
    case rateLimited(retryAfter: Date?)
    case network(underlyingDescription: String)
    case providerMalformedResponse(stage: String)
  }

  var provider: SyncProvider?
  var kind: Kind

  /// Returns a copy attributed to `provider`, but only if it is not
  /// already attributed — the innermost (closest-to-source) provider
  /// wins, so an outer boundary never relabels a deeper one's error.
  func attributed(to provider: SyncProvider) -> WalletSyncError {
    guard self.provider == nil else { return self }
    return WalletSyncError(provider: provider, kind: kind)
  }
}

// MARK: - Call-site-preserving factories

// These keep every existing `throw WalletSyncError.network(…)` /
// `.missingApiKey` / etc. site compiling unchanged, producing an
// unattributed error that a leaf boundary later stamps.
extension WalletSyncError {
  static var missingApiKey: WalletSyncError {
    WalletSyncError(provider: nil, kind: .missingApiKey)
  }
  static var invalidApiKey: WalletSyncError {
    WalletSyncError(provider: nil, kind: .invalidApiKey)
  }
  static func rateLimited(retryAfter: Date?) -> WalletSyncError {
    WalletSyncError(provider: nil, kind: .rateLimited(retryAfter: retryAfter))
  }
  static func network(underlyingDescription: String) -> WalletSyncError {
    WalletSyncError(
      provider: nil, kind: .network(underlyingDescription: underlyingDescription))
  }
  static func providerMalformedResponse(stage: String) -> WalletSyncError {
    WalletSyncError(provider: nil, kind: .providerMalformedResponse(stage: stage))
  }
}

// MARK: - Codable with legacy-row migration

// Persisted shape (new): {"provider": "alchemy"|null, "kind": <Kind JSON>}.
// Legacy shape (pre-attribution): the bare enum encoding — a single-key
// object whose key is the case name, e.g. {"network":{...}} or
// {"missingApiKey":{}}. The decoder accepts both; the encoder only ever
// writes the new shape.
extension WalletSyncError {
  private enum CodingKeys: String, CodingKey { case provider, kind }

  init(from decoder: Decoder) throws {
    // New shape: keyed container that has a `kind` key.
    if let container = try? decoder.container(keyedBy: CodingKeys.self),
      container.contains(.kind)
    {
      let provider = try container.decodeIfPresent(
        SyncProvider.self, forKey: .provider)
      let kind = try container.decode(Kind.self, forKey: .kind)
      self.init(provider: provider, kind: kind)
      return
    }
    // Legacy shape: the bare `Kind`-equivalent enum JSON.
    let legacyKind = try Kind(from: decoder)
    self.init(provider: nil, kind: legacyKind)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encodeIfPresent(provider, forKey: .provider)
    try container.encode(kind, forKey: .kind)
  }
}
```

> **Why this decodes legacy rows:** before this change `WalletSyncError`
> was an `enum` with associated values; Swift's synthesized `Codable`
> encodes such an enum as a single-key object keyed by the case name.
> `Kind` has the *same* cases, so its synthesized `Codable` produces and
> consumes the identical JSON. A legacy row therefore decodes cleanly via
> `Kind(from: decoder)` with `provider = nil`.

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac WalletSyncErrorTests 2>&1 | tee .agent-tmp/t.txt`
Expected: PASS. (A full `just build-mac` will still fail until Task 3 — that is expected; do **not** run the per-task build gate for this task in isolation. Proceed directly to Task 3, which restores a clean build. Treat Tasks 2+3 as a single build-gated unit.)

- [ ] **Step 5: Commit**

```bash
git -C . add Domain/Models/WalletSyncError.swift MoolahTests/Domain/Models/WalletSyncErrorTests.swift
git -C . commit -m "feat: reshape WalletSyncError into provider-attributed struct"
```

---

## Task 3: Fix enum-pattern sites broken by the struct change

Pattern-matching `catch WalletSyncError.invalidApiKey` and `switch error { case .network … }` no longer compile against a struct. Move them to `.kind`. After this task `just build-mac` is clean again.

**Files:**
- Modify: `Shared/CryptoImport/BlockExplorerClient.swift:164`
- Modify: `Features/Sync/SyncedAccountHeaderLogic.swift:101-131`

- [ ] **Step 1: Fix the `catch` pattern in `BlockExplorerClient`**

In `Shared/CryptoImport/BlockExplorerClient.swift`, the `send(request:stage:)` method currently has:

```swift
    do {
      try AlchemyResponseValidator.validate(response: response, stage: stage, logger: logger)
    } catch WalletSyncError.invalidApiKey {
      logger.error(
        "Blockscout \(stage, privacy: .public): HTTP 401/403 (public API expects no auth)")
      throw WalletSyncError.network(underlyingDescription: "HTTP 401/403")
    }
```

Replace the `catch` clause with a typed-where catch on `kind`:

```swift
    do {
      try AlchemyResponseValidator.validate(response: response, stage: stage, logger: logger)
    } catch let error as WalletSyncError where error.kind == .invalidApiKey {
      logger.error(
        "Blockscout \(stage, privacy: .public): HTTP 401/403 (public API expects no auth)")
      throw WalletSyncError.network(underlyingDescription: "HTTP 401/403")
    }
```

- [ ] **Step 2: Fix the `switch` in `SyncedAccountHeaderLogic`**

In `Features/Sync/SyncedAccountHeaderLogic.swift`, the `errorCaption(for error: WalletSyncError, account:)` method switches on `error`. Change only the switch subject to `error.kind` for now (provider-aware captions come in Task 8 — this task is a pure compile-fix that preserves current behaviour):

Change `switch error {` to `switch error.kind {`. Leave every `case` body byte-identical.

- [ ] **Step 3: Verify the build is clean**

Run: `just build-mac 2>&1 | tee .agent-tmp/b.txt`
Expected: build succeeds. `grep -n "WalletSyncError" .agent-tmp/b.txt` shows no errors.

If the build reports any *other* enum-pattern site not listed above (a `catch WalletSyncError.<case>` or `switch` on a bare `WalletSyncError`), fix it the same way: typed-where catch on `error.kind`, or switch on `.kind`. The grep used to scope this plan found only the two above, but trust the compiler over the plan.

- [ ] **Step 4: Run the affected suites**

Run: `just test-mac SyncedAccountHeaderLogicTests LiveBlockscoutClientTests 2>&1 | tee .agent-tmp/t.txt`
Expected: PASS (behaviour unchanged). Then `just format-check` clean. `rm .agent-tmp/*.txt`.

- [ ] **Step 5: Commit**

```bash
git -C . add Shared/CryptoImport/BlockExplorerClient.swift Features/Sync/SyncedAccountHeaderLogic.swift
git -C . commit -m "refactor: move WalletSyncError pattern matches onto kind"
```

---

## Task 4: Stamp `.alchemy` at the `LiveAlchemyClient` leaf

`WalletSyncEngine` calls `alchemy` (a `protocol AlchemyClient`) for ERC-20 transfers and token metadata; `TransferEventBuilder` also calls it. Stamping inside the *live implementation*'s protocol methods attributes every Alchemy-originated `WalletSyncError` to `.alchemy` regardless of which orchestrator invoked it, without mis-attributing the builder's own non-Alchemy throws.

**Files:**
- Modify: `Shared/CryptoImport/AlchemyClient.swift` (the `extension LiveAlchemyClient: AlchemyClient` conformance — wrap each protocol method body)
- Test: `MoolahTests/Shared/CryptoImport/LiveAlchemyClientAttributionTests.swift` (create)

- [ ] **Step 1: Inspect the conformance to enumerate the methods to wrap**

Run: `grep -n "extension LiveAlchemyClient\|func .* async throws" Shared/CryptoImport/AlchemyClient.swift`
Note every protocol method on the `extension LiveAlchemyClient: AlchemyClient` conformance (from the protocol: at least `getAssetTransfers`, `getTokenMetadata`, `getTransactionReceipt` — confirm the exact set from the grep).

- [ ] **Step 2: Write the failing test**

Use the existing `LiveAlchemyClientErrorTests` as the pattern for constructing a `LiveAlchemyClient` with a stubbed `URLSession`/transport that forces a network failure (read that file first to reuse its harness). The test asserts the escaping error is attributed:

```swift
// MoolahTests/Shared/CryptoImport/LiveAlchemyClientAttributionTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveAlchemyClient provider attribution")
struct LiveAlchemyClientAttributionTests {
  @Test("A network failure from getAssetTransfers is attributed to .alchemy")
  func networkErrorIsAttributed() async throws {
    // Build the client exactly as LiveAlchemyClientErrorTests does, with a
    // session/transport stub that throws a URLError so the client maps it
    // to WalletSyncError.network(...). Reuse that file's helper verbatim.
    let client = try Self.makeFailingClient()  // mirror LiveAlchemyClientErrorTests
    await #expect(throws: WalletSyncError.self) {
      _ = try await client.getAssetTransfers(
        chain: .ethereumMainnet, walletAddress: "0xabc", fromBlock: 0)
    }
    do {
      _ = try await client.getAssetTransfers(
        chain: .ethereumMainnet, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .alchemy)
    }
  }
}
```

> If `LiveAlchemyClientErrorTests` already exercises a failing client, factor its
> setup into a shared helper rather than duplicating it (DRY). Read that file
> first; match its `ChainConfig` fixture and stub names exactly. Do **not**
> invent API — use whatever it uses.

- [ ] **Step 3: Run test to verify it fails**

Run: `just test-mac LiveAlchemyClientAttributionTests 2>&1 | tee .agent-tmp/t.txt`
Expected: FAIL — `error.provider` is `nil`, not `.alchemy`.

- [ ] **Step 4: Add the attribution helper and wrap the conformance**

At the bottom of `Shared/CryptoImport/AlchemyClient.swift`, add a file-private boundary helper:

```swift
// Attributes any WalletSyncError escaping `body` to a provider, unless it
// was already attributed by a deeper boundary (innermost wins). Non-
// WalletSyncError errors (e.g. CancellationError) pass through untouched.
private func attributingErrors<T>(
  to provider: SyncProvider,
  _ body: () async throws -> T
) async throws -> T {
  do {
    return try await body()
  } catch let error as WalletSyncError {
    throw error.attributed(to: provider)
  }
}
```

In the `extension LiveAlchemyClient: AlchemyClient` conformance, wrap **each** protocol method's body. Pattern (apply to every conformance method, e.g. `getAssetTransfers`, `getTokenMetadata`, `getTransactionReceipt`):

```swift
  func getAssetTransfers(
    chain: ChainConfig, walletAddress: String, fromBlock: UInt64
  ) async throws -> [AlchemyTransfer] {
    try await attributingErrors(to: .alchemy) {
      // ... the existing method body, unchanged ...
    }
  }
```

Do not change any logic inside the bodies — only enclose them in the `attributingErrors(to: .alchemy) { … }` closure.

- [ ] **Step 5: Run test to verify it passes**

Run: `just test-mac LiveAlchemyClientAttributionTests LiveAlchemyClientErrorTests LiveAlchemyClientReceiptTests WalletSyncEngineTests 2>&1 | tee .agent-tmp/t.txt`
Expected: PASS (attribution added; existing Alchemy behaviour unchanged). Then `just build-mac` clean, `just format-check` clean. `rm .agent-tmp/*.txt`.

- [ ] **Step 6: Commit**

```bash
git -C . add Shared/CryptoImport/AlchemyClient.swift MoolahTests/Shared/CryptoImport/LiveAlchemyClientAttributionTests.swift
git -C . commit -m "feat: attribute LiveAlchemyClient failures to .alchemy"
```

---

## Task 5: Stamp `.blockExplorer` at the `LiveBlockscoutClient` leaf

**Files:**
- Modify: `Shared/CryptoImport/BlockExplorerClient.swift` (the `extension LiveBlockscoutClient: BlockExplorerClient` conformance — `nativeTransactions`, `internalTransactions`)
- Test: `MoolahTests/Shared/CryptoImport/LiveBlockscoutClientAttributionTests.swift` (create)

- [ ] **Step 1: Write the failing test**

Read `MoolahTests/Shared/CryptoImport/LiveBlockscoutClientTests.swift` first and reuse its client-construction / failing-session harness (DRY).

```swift
// MoolahTests/Shared/CryptoImport/LiveBlockscoutClientAttributionTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("LiveBlockscoutClient provider attribution")
struct LiveBlockscoutClientAttributionTests {
  @Test("A network failure from nativeTransactions is attributed to .blockExplorer")
  func networkErrorIsAttributed() async throws {
    let client = try Self.makeFailingClient()  // mirror LiveBlockscoutClientTests
    do {
      _ = try await client.nativeTransactions(
        chain: .ethereumMainnet, walletAddress: "0xabc", fromBlock: 0)
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .blockExplorer)
    }
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac LiveBlockscoutClientAttributionTests 2>&1 | tee .agent-tmp/t.txt`
Expected: FAIL — `error.provider` is `nil`.

- [ ] **Step 3: Add the helper and wrap the conformance**

`AlchemyClient.swift` and `BlockExplorerClient.swift` are separate files; `attributingErrors` from Task 4 is `private` to its file. Add the same helper, file-private, at the bottom of `Shared/CryptoImport/BlockExplorerClient.swift`:

```swift
private func attributingErrors<T>(
  to provider: SyncProvider,
  _ body: () async throws -> T
) async throws -> T {
  do {
    return try await body()
  } catch let error as WalletSyncError {
    throw error.attributed(to: provider)
  }
}
```

> Two file-private copies is acceptable here — it's three trivial lines and
> avoids creating a new shared type for a one-liner. Do **not** hoist it into
> a shared utility unless a third call site appears (YAGNI).

Wrap each method in `extension LiveBlockscoutClient: BlockExplorerClient` (`nativeTransactions`, `internalTransactions`) in `try await attributingErrors(to: .blockExplorer) { … existing body … }`, logic unchanged.

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac LiveBlockscoutClientAttributionTests LiveBlockscoutClientTests WalletSyncEngineTests 2>&1 | tee .agent-tmp/t.txt`
Expected: PASS. Then `just build-mac` clean, `just format-check` clean. `rm .agent-tmp/*.txt`.

- [ ] **Step 5: Commit**

```bash
git -C . add Shared/CryptoImport/BlockExplorerClient.swift MoolahTests/Shared/CryptoImport/LiveBlockscoutClientAttributionTests.swift
git -C . commit -m "feat: attribute LiveBlockscoutClient failures to .blockExplorer"
```

---

## Task 6: Stamp `.coinstash` in `CoinstashSyncSource`

`CoinstashSyncSource.build(account:)` constructs every `WalletSyncError` it
emits at four sites (lines 52–53, 56, 63, 65). Attribute them directly —
no helper needed since they're all in one method.

**Files:**
- Modify: `Shared/Exchange/CoinstashSyncSource.swift:38-67`
- Test: `MoolahTests/Shared/Exchange/CoinstashSyncSourceTests.swift` (extend)

- [ ] **Step 1: Add failing tests to the existing suite**

Read `MoolahTests/Shared/Exchange/CoinstashSyncSourceTests.swift` to match its harness (stub `ExchangeClient` / `ExchangeTokenStore`). Add tests asserting attribution for the unauthorized and generic-network paths:

```swift
  @Test("Unauthorized maps to invalidApiKey attributed to .coinstash")
  func unauthorizedIsAttributed() async throws {
    let source = Self.makeSource(clientResult: .failure(ExchangeClientError.unauthorized))
    do {
      _ = try await source.build(account: Self.exchangeAccount)
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .coinstash)
      #expect(error.kind == .invalidApiKey)
    }
  }

  @Test("A generic ExchangeClientError maps to network attributed to .coinstash")
  func genericErrorIsAttributed() async throws {
    let source = Self.makeSource(
      clientResult: .failure(ExchangeClientError.someTransport))  // use a real case
    do {
      _ = try await source.build(account: Self.exchangeAccount)
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .coinstash)
    }
  }
```

> Match `makeSource` / account fixtures / `ExchangeClientError` cases to whatever
> the existing suite already defines. If the suite has no factory, follow its
> existing per-test construction style instead of inventing `makeSource`.

- [ ] **Step 2: Run to verify failure**

Run: `just test-mac CoinstashSyncSourceTests 2>&1 | tee .agent-tmp/t.txt`
Expected: FAIL — `error.provider` is `nil`.

- [ ] **Step 3: Attribute the four throw sites**

In `Shared/Exchange/CoinstashSyncSource.swift`, change the four `throw WalletSyncError…` sites in `build(account:)` to attributed forms:

```swift
    // keychain read failure
      throw WalletSyncError(
        provider: .coinstash,
        kind: .network(underlyingDescription: "Keychain read failed: \(error)"))
    }
    guard let token, !token.isEmpty else {
      throw WalletSyncError(provider: .coinstash, kind: .missingApiKey)
    }
    do {
      let imported = try await client.fetchTransactions(token: token)
      let metadata = metadataResolverFactory(token)
      return try await engine.build(account: account, imported: imported, metadata: metadata)
    } catch ExchangeClientError.unauthorized {
      throw WalletSyncError(provider: .coinstash, kind: .invalidApiKey)
    } catch let error as ExchangeClientError {
      throw WalletSyncError(
        provider: .coinstash,
        kind: .network(underlyingDescription: String(describing: error)))
    }
```

> `engine.build(...)` may itself throw a `WalletSyncError`; that path is the
> exchange engine's, not the network client's, and is acceptable to leave
> unattributed (it falls back to the account-neutral caption). Do not wrap it.

- [ ] **Step 4: Run to verify pass**

Run: `just test-mac CoinstashSyncSourceTests 2>&1 | tee .agent-tmp/t.txt`
Expected: PASS. Then `just build-mac` clean, `just format-check` clean. `rm .agent-tmp/*.txt`.

- [ ] **Step 5: Commit**

```bash
git -C . add Shared/Exchange/CoinstashSyncSource.swift MoolahTests/Shared/Exchange/CoinstashSyncSourceTests.swift
git -C . commit -m "feat: attribute CoinstashSyncSource failures to .coinstash"
```

---

## Task 7: Attribute the last price provider tried on total price failure

`CryptoPriceService` iterates `clients: [CryptoPriceClient]` (CoinGecko →
CryptoCompare → Binance), tolerating per-provider failures and only
throwing when **all** are exhausted. The thrown error is currently a bare
`CryptoPriceError` that the catch-all flattens to an unattributed
`.network`. Surface the **last provider attempted** by giving
`CryptoPriceClient` a `syncProvider` and throwing an attributed
`WalletSyncError` on total failure.

**Files:**
- Modify: the `CryptoPriceClient` protocol (find it: `grep -rn "protocol CryptoPriceClient" Shared`)
- Modify: each concrete `CryptoPriceClient` (CoinGecko / CryptoCompare / Binance impls — find with `grep -rln ": CryptoPriceClient" Shared`)
- Modify: `Shared/CryptoPriceService.swift` (the two provider loops at ~line 145 and ~line 373; the total-failure `throw` at the end of the historical-price loop)
- Test: `MoolahTests/Shared/CryptoPriceServiceAttributionTests.swift` (create)

- [ ] **Step 1: Locate the protocol and conformers**

Run:
```
grep -rn "protocol CryptoPriceClient" Shared
grep -rln ": CryptoPriceClient" Shared
grep -n "var lastError\|for client in clients\|throw lastError\|CryptoPriceError.noPriceAvailable" Shared/CryptoPriceService.swift
```
Record the protocol file, the concrete conformers, and the exact total-failure throw lines (the design references `throw lastError ?? CryptoPriceError.noPriceAvailable(...)`).

- [ ] **Step 2: Write the failing test**

```swift
// MoolahTests/Shared/CryptoPriceServiceAttributionTests.swift
import Foundation
import Testing

@testable import Moolah

@Suite("CryptoPriceService provider attribution")
struct CryptoPriceServiceAttributionTests {
  @Test("When all price providers fail, the error names the last attempted")
  func totalFailureNamesLastProvider() async throws {
    // Construct CryptoPriceService with stub clients that ALL throw, in
    // order [coinGecko, cryptoCompare, binance]. Reuse any existing
    // CryptoPriceService test harness in MoolahTests/Shared if present.
    let service = try Self.makeServiceWhereAllProvidersFail()
    do {
      _ = try await service.priceForTestEntryPoint()  // use the real exhausting API
      Issue.record("expected throw")
    } catch let error as WalletSyncError {
      #expect(error.provider == .binance)  // last in the fallback chain
    }
  }
}
```

> First `grep -rln "CryptoPriceService" MoolahTests` and reuse any existing
> harness/stub-client. Use the real public method that runs the exhausting
> provider loop (the one containing `throw lastError ?? …`); do not invent a
> `priceForTestEntryPoint`. Order the stub `clients` array so Binance is last.

- [ ] **Step 3: Run to verify failure**

Run: `just test-mac CryptoPriceServiceAttributionTests 2>&1 | tee .agent-tmp/t.txt`
Expected: FAIL — either compile error (`syncProvider` missing) or `provider == nil`.

- [ ] **Step 4: Add `syncProvider` to the protocol and conformers**

In the `CryptoPriceClient` protocol, add:

```swift
  /// Which provider this client represents, used to attribute a
  /// total-price-failure error to the last provider attempted.
  var syncProvider: SyncProvider { get }
```

In each concrete conformer add the matching constant (one per conformer):
`var syncProvider: SyncProvider { .coinGecko }` / `.cryptoCompare` /
`.binance` respectively. (Map each concrete client to its provider by the
type's name — confirm against the conformer list from Step 1.)

- [ ] **Step 5: Track the last provider and throw attributed**

In `Shared/CryptoPriceService.swift`, in the provider loop that ends with
`throw lastError ?? CryptoPriceError.noPriceAvailable(...)`, track the last
provider attempted and wrap the terminal throw. Change:

```swift
    var lastError: (any Error)?
    for client in clients {
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: fetchInterval)
        // ... unchanged ...
      } catch {
        lastError = error
        continue
      }
    }

    if let fallback = fallbackPrice(tokenId: tokenId, dateString: dateString) {
      return fallback
    }

    throw lastError ?? CryptoPriceError.noPriceAvailable(tokenId: tokenId, date: dateString)
```

to:

```swift
    var lastError: (any Error)?
    var lastProvider: SyncProvider?
    for client in clients {
      lastProvider = client.syncProvider
      do {
        let fetched = try await client.dailyPrices(for: mapping, in: fetchInterval)
        // ... unchanged ...
      } catch {
        lastError = error
        continue
      }
    }

    if let fallback = fallbackPrice(tokenId: tokenId, dateString: dateString) {
      return fallback
    }

    let description = (lastError.map { String(describing: $0) })
      ?? "No price available for \(tokenId) at \(dateString)"
    throw WalletSyncError(
      provider: lastProvider,
      kind: .network(underlyingDescription: description))
```

Apply the same `lastProvider` tracking + attributed terminal throw to the
second provider loop (~line 373) if it has the same exhaust-then-throw
shape. If that second loop rethrows via a different terminal (e.g.
`if let error = lastError { throw error }`), wrap that terminal the same
way: `throw WalletSyncError(provider: lastProvider, kind: .network(underlyingDescription: String(describing: error)))`.

> `WalletSyncError(provider: nil, …)` is the correct result if `clients`
> is empty (no provider was attempted) — `lastProvider` stays `nil`.

- [ ] **Step 6: Run to verify pass**

Run: `just test-mac CryptoPriceServiceAttributionTests 2>&1 | tee .agent-tmp/t.txt`
Expected: PASS. Then `just build-mac` clean, `just format-check` clean.

Also run the existing price suite to catch regressions:
Run: `grep -rln "CryptoPriceService" MoolahTests` then `just test-mac <those suites> 2>&1 | tee .agent-tmp/t2.txt` — expect PASS. `rm .agent-tmp/*.txt`.

- [ ] **Step 7: Commit**

```bash
git -C . add Shared/CryptoPriceService.swift MoolahTests/Shared/CryptoPriceServiceAttributionTests.swift
# plus the protocol file and concrete conformer files identified in Step 1
git -C . commit -m "feat: attribute total price-fetch failure to the last provider tried"
```

---

## Task 8: Provider-aware error caption

`SyncedAccountHeaderLogic.errorCaption(for:account:)` must prefer
`error.provider?.displayName`. When `provider == nil` (legacy rows /
unattributable errors) it falls back to **today's byte-identical strings**,
preserving the `WalletAccountHeaderLogic` caption contract and the existing
characterisation tests.

**Files:**
- Modify: `Features/Sync/SyncedAccountHeaderLogic.swift:101-131`
- Test: `MoolahTests/Features/Sync/SyncedAccountHeaderLogicTests.swift` (extend)

- [ ] **Step 1: Add failing tests**

Append to `SyncedAccountHeaderLogicTests`:

```swift
  // MARK: - Provider-attributed captions

  @Test("Attributed invalidApiKey names the provider")
  func attributedInvalidApiKeyNamesProvider() {
    let error = WalletSyncError(provider: .coinstash, kind: .invalidApiKey)
    let caption = SyncedAccountHeaderLogic.errorCaption(
      for: error, account: exchangeAccount)
    #expect(caption == "Coinstash rejected the API token.")
  }

  @Test("Attributed network error is prefixed with the provider")
  func attributedNetworkNamesProvider() {
    let error = WalletSyncError(
      provider: .blockExplorer, kind: .network(underlyingDescription: "timeout"))
    let caption = SyncedAccountHeaderLogic.errorCaption(
      for: error, account: cryptoAccount)
    #expect(caption == "Blockscout network error: timeout")
  }

  @Test("Unattributed network error keeps the legacy byte-identical string")
  func unattributedNetworkIsByteIdentical() {
    let error = WalletSyncError(
      provider: nil, kind: .network(underlyingDescription: "timeout"))
    let caption = SyncedAccountHeaderLogic.errorCaption(
      for: error, account: cryptoAccount)
    #expect(caption == "Network error: timeout")
  }

  @Test("Unattributed crypto invalidApiKey keeps the legacy Alchemy string")
  func unattributedCryptoInvalidApiKeyIsLegacy() {
    let error = WalletSyncError(provider: nil, kind: .invalidApiKey)
    let caption = SyncedAccountHeaderLogic.errorCaption(
      for: error, account: cryptoAccount)
    #expect(caption == "Alchemy rejected the API key.")
  }
```

> Confirm the existing pre-change caption tests still construct errors via
> `WalletSyncError.network(...)` etc. — those factories yield `provider: nil`,
> so the existing assertions must remain unchanged and still pass. If any
> existing test constructed the bare enum directly (e.g. `.network(...)` as a
> value of `WalletSyncError`), it still compiles via the static factory.

- [ ] **Step 2: Run to verify failure**

Run: `just test-mac SyncedAccountHeaderLogicTests 2>&1 | tee .agent-tmp/t.txt`
Expected: the new attributed-provider tests FAIL (no provider in caption); legacy tests PASS.

- [ ] **Step 3: Make the caption provider-aware**

Rewrite `errorCaption(for error: WalletSyncError, account:)` so a present
`provider` drives the wording and `nil` falls back to the existing
account-type branches verbatim:

```swift
  static func errorCaption(for error: WalletSyncError, account: Account) -> String {
    switch error.kind {
    case .missingApiKey:
      switch account.type {
      case .exchange:
        return "Add your read-only API token to sync."
      case .crypto, .bank, .creditCard, .asset, .investment:
        return "Add an Alchemy API key to enable sync."
      }
    case .invalidApiKey:
      if let provider = error.provider {
        return "\(provider.displayName) rejected the API token."
      }
      switch account.type {
      case .exchange:
        let provider = account.exchangeProvider?.displayName ?? "The exchange"
        return "\(provider) rejected the API token."
      case .crypto, .bank, .creditCard, .asset, .investment:
        return "Alchemy rejected the API key."
      }
    case .rateLimited(let retryAfter):
      let prefix = error.provider.map { "\($0.displayName) rate-limited" }
        ?? "Rate-limited"
      if let retryAfter {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return
          "\(prefix). Retry \(formatter.localizedString(for: retryAfter, relativeTo: Date()))."
      }
      return "\(prefix). Retry shortly."
    case .network(let underlying):
      if let provider = error.provider {
        return "\(provider.displayName) network error: \(underlying)"
      }
      return "Network error: \(underlying)"
    case .providerMalformedResponse(let stage):
      if let provider = error.provider {
        return "\(provider.displayName) returned a malformed response (\(stage))."
      }
      return "Provider returned a malformed response (\(stage))."
    }
  }
```

> Note on `.missingApiKey`: it stays account-type-driven even when attributed —
> "Add an Alchemy API key…" / "Add your read-only API token…" are the
> actionable instructions the design's credential UX depends on; a provider
> prefix there would not improve them. This is intentional, not an omission.

Update the doc-comment above the method to state the new rule (provider
prefix when attributed; byte-identical legacy fallback when `nil`).

- [ ] **Step 4: Run to verify pass**

Run: `just test-mac SyncedAccountHeaderLogicTests 2>&1 | tee .agent-tmp/t.txt`
Expected: PASS (new + legacy). Then `just build-mac` clean, `just format-check` clean. `rm .agent-tmp/t.txt`.

- [ ] **Step 5: Commit**

```bash
git -C . add Features/Sync/SyncedAccountHeaderLogic.swift MoolahTests/Features/Sync/SyncedAccountHeaderLogicTests.swift
git -C . commit -m "feat: name the failing provider in the sync error caption"
```

---

## Task 9: Repair existing tests broken by the struct shape, full-suite gate, DataFormatVersion note

Tests across the codebase construct or compare `WalletSyncError`. Constructors via the static factories still compile. **Equality assertions break** where a now-attributed error is compared to a `provider: nil` literal (e.g. asserting an Alchemy network failure `== WalletSyncError.network(...)` — it is now `provider: .alchemy`). Fix by comparing `.kind` (or by including the expected provider).

**Files (test-only + a doc note):**
- Modify: any failing test under `MoolahTests` that compares whole `WalletSyncError` values (candidates from grep below)
- Modify: `Domain/Models/DataFormatVersion.swift` (doc-comment history note only — no `current` bump)

- [ ] **Step 1: Find whole-value comparison/switch sites in tests**

Run:
```
grep -rn "== WalletSyncError\|WalletSyncError(\|switch .*error\|case .network\|case .invalidApiKey\|case .missingApiKey\|case .rateLimited\|case .providerMalformedResponse" --include="*.swift" MoolahTests
```
Review each hit in: `SyncedAccountStoreTests`, `SyncedAccountStoreGlobalErrorTests`, `WalletSyncEngineTests`, `LiveAlchemyClientErrorTests`, `LiveBlockscoutClientTests`, `CoinstashSyncSourceTests`, and any other file listed.

- [ ] **Step 2: Run the full macOS suite to get the real failure set**

Run: `just test-mac 2>&1 | tee .agent-tmp/full.txt`
Then: `grep -nE "error:|failed|Test.*recorded an issue" .agent-tmp/full.txt`
This is the authoritative list of what actually broke — fix exactly those.

- [ ] **Step 3: Fix each broken assertion**

For an assertion that an error from an attributed provider equals an unattributed literal, compare `kind`:

```swift
// Before:
#expect(thrown == WalletSyncError.network(underlyingDescription: "boom"))
// After (provider is now stamped by the leaf boundary):
#expect(thrown.kind == .network(underlyingDescription: "boom"))
// And, where the test's intent includes attribution, also assert it:
#expect(thrown.provider == .alchemy)
```

For a `switch error { case .network … }` in a test, switch on `error.kind`.
Do not weaken assertions beyond what the shape change requires — keep every
behavioural check; only adjust the value/shape being compared.

- [ ] **Step 4: Add the DataFormatVersion history note (no bump)**

`WalletSyncState` is a **per-device, non-cross-device-synced** checkpoint
and `WalletSyncError` is **not** a `// SyncBoundary —` enum, so none of the
forward-incompatible rubric items (1–6 in `DataFormatVersion.swift`) apply.
`current` stays `2`. Add a one-line note to the `History` block documenting
the deliberate non-bump:

```swift
/// - (no bump) 2026-05-17: `WalletSyncError` gained a `provider` field /
///   struct shape. `WalletSyncState` is per-device and never synced
///   cross-device; legacy rows decode via a bare-enum compatibility
///   path. No rubric item applies — recorded here so the absence of a
///   bump is a documented decision, not an oversight.
```

- [ ] **Step 5: Full gate**

Run: `just test-mac 2>&1 | tee .agent-tmp/full.txt` → all pass.
Run: `just build-mac` → clean (no warnings; project treats warnings as errors).
Run: `just format-check` → clean.
Run: `just test-ios 2>&1 | tee .agent-tmp/ios.txt` → all pass (the change is platform-neutral but the iOS target compiles the same sources). `rm .agent-tmp/*.txt`.

- [ ] **Step 6: Commit**

```bash
git -C . add MoolahTests Domain/Models/DataFormatVersion.swift
git -C . commit -m "test: update WalletSyncError assertions for attributed struct shape"
```

---

## Task 10: Review gate

- [ ] **Step 1: Code review**

Invoke the `code-review` agent over the diff (CODE_GUIDE.md, naming, optional discipline, one-extension-per-protocol, thin-view discipline). Address Critical/Important/Minor per the project rule (all get fixed; ask before deferring).

- [ ] **Step 2: Concurrency review**

Invoke the `concurrency-review` agent — the change touches client/source/service async code (`attributingErrors` is an `async` rethrow helper; confirm no actor-isolation or `Sendable` regressions; `SyncProvider` is `Sendable`).

- [ ] **Step 3: Final verification & open the PR**

Re-run the full gate from Task 9 Step 5 if any review fix landed. Then push the branch and open a PR with `gh pr create` (summary + test plan). Add the PR to the merge queue via the `merge-queue` skill per project policy — do not merge manually.

---

## Self-Review (plan vs. spec)

- **Spec §1 SyncProvider** → Task 1. ✔
- **Spec §2 WalletSyncError struct + factories + legacy Codable + attributed** → Task 2. ✔
- **Spec §3 boundary stamping** → Alchemy Task 4, Blockscout Task 5, Coinstash Task 6, price Task 7. ✔ (Design said "stamp at leaf"; the spec's `WalletSyncEngine` account-validation note is resolved here as **intentionally unattributed** — it is an account-data error, not a provider fault — and Task 8 renders it via the `nil` fallback. This refines the spec; design intent—"name the failing provider"—is preserved since no provider failed.)
- **Spec §4 catch-all unchanged** → no task modifies `SyncedAccountStore+Internals.swift:144/151`; Task 3 only touches the two enum-pattern sites. ✔
- **Spec §5 provider-aware caption with byte-identical nil fallback** → Task 8. ✔
- **Spec §6 mechanical enum→struct updates** → Task 3 (prod) + Task 9 (tests), compiler-driven. ✔
- **Spec §7 DataFormatVersion check** → Task 9 Step 4, resolved as documented no-bump. ✔
- **Spec Testing bullets** → legacy-JSON (T2), attributed innermost-wins (T2), per-provider stamping incl. price-last-tried (T4–T7), caption displayName + nil fallback (T8), existing-test fixups (T9). ✔
- **Placeholder scan:** test harness references (`makeFailingClient`, `makeSource`, the price entry point) are explicitly flagged "reuse the existing suite's harness; do not invent" with the grep to find it — this is a deliberate instruction to match real existing API, not a placeholder. No `TBD`/`implement later`.
- **Type consistency:** `SyncProvider`, `WalletSyncError.Kind`, `.provider`, `.kind`, `.attributed(to:)`, `attributingErrors(to:_:)`, `CryptoPriceClient.syncProvider` are used consistently across tasks.

---

## Notes / risks

- **Build is intentionally red between Task 2 and Task 3.** They are a single build-gated unit; the plan says so explicitly. A subagent must not "fix" Task 2 by reverting — proceed to Task 3.
- **Test harness reuse.** Tasks 4–7 deliberately defer to existing test files' client/stub construction. The implementer must read those files first; inventing parallel harnesses violates DRY and risks drift.
- **`attributingErrors` duplicated file-private in two files** is an accepted, deliberate call (3 trivial lines, 2 sites). Promote to a shared helper only if a third site appears.
- **Equality-assertion fallout** (Task 9) is the largest unknown — the full-suite run in Task 9 Step 2 is the source of truth, not the plan's file guesses.
