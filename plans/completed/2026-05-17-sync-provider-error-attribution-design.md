# Sync-Provider Error Attribution — Design

**Date:** 2026-05-17
**Status:** Approved (design); pending implementation plan

## Problem

Crypto/exchange account sync fans out across multiple providers, but a
failed sync stores a `WalletSyncError` with no record of *which* provider
produced it. The on-chain `.crypto` path is the worst case: Alchemy (token
balances/transfers), Blockscout (native ETH via the block explorer), and
the price providers (CoinGecko → CryptoCompare → Binance) all participate
in one account's sync. When any one fails, the user sees a generic caption
such as `"Network error: …"` with no attribution. The current UI workaround
(branching on `account.type` + error case, hard-coding `"Alchemy"`, and a
post-hoc `account.exchangeProvider` lookup) only resolves credential errors
and cannot attribute a network failure to its source.

## Goal

Every sync provider's failure carries its provider identity through to the
place errors already surface — the persisted `WalletSyncState.lastError`
and its UI caption (`SyncedAccountHeaderLogic.errorCaption`). No new logging
or persistence surfaces are added.

Scope (confirmed): on-chain crypto (Alchemy, Blockscout), exchange
(Coinstash), and price providers (CoinGecko/CryptoCompare/Binance).

## Approach

Provider identity lives **inside the error value** (not bolted on at a
persist boundary), because in the wallet path the failing call site is far
from the single `persistError` boundary — only the throw-near-the-source
can know Alchemy-vs-Blockscout-vs-price. Identity is attached **once per
provider at that provider's outermost client boundary**, not at each of
the ~25 individual throw sites.

### 1. New domain type — `Domain/Models/SyncProvider.swift`

```swift
enum SyncProvider: String, Codable, Sendable, Hashable, CaseIterable {
  case alchemy
  case blockExplorer
  case coinstash
  case coinGecko
  case cryptoCompare
  case binance

  var displayName: String { … }  // Alchemy, Blockscout, Coinstash,
                                  // CoinGecko, CryptoCompare, Binance
}
```

String-backed so it round-trips as a stable token in the `lastError` JSON.
`displayName` for `.blockExplorer` is **"Blockscout"** (consistent with
the codebase already surfacing the brand name "Alchemy" in captions).

### 2. Reshape `WalletSyncError`

From a bare enum to:

```swift
struct WalletSyncError: Error, Codable, Sendable, Hashable {
  enum Kind: Codable, Sendable, Hashable {
    case missingApiKey
    case invalidApiKey
    case rateLimited(retryAfter: Date?)
    case network(underlyingDescription: String)
    case providerMalformedResponse(stage: String)
  }
  var provider: SyncProvider?
  var kind: Kind
}
```

- **Static factories** preserve every existing throw site verbatim:

  ```swift
  extension WalletSyncError {
    static var missingApiKey: WalletSyncError { .init(provider: nil, kind: .missingApiKey) }
    static var invalidApiKey: WalletSyncError { .init(provider: nil, kind: .invalidApiKey) }
    static func rateLimited(retryAfter: Date?) -> WalletSyncError { … }
    static func network(underlyingDescription: String) -> WalletSyncError { … }
    static func providerMalformedResponse(stage: String) -> WalletSyncError { … }
  }
  ```

  The ~25 `throw WalletSyncError.network(…)` / `.missingApiKey` / etc.
  sites compile unchanged, producing `provider: nil`.

- **Custom `Codable`** decodes legacy bare-enum JSON (e.g.
  `{"network":{"underlyingDescription":"…"}}`) into
  `{provider: nil, kind: .network(…)}`. New JSON adds a `provider` key.
  `WalletSyncState` is a **per-device, non-cross-device-synced** checkpoint
  (see `WalletSyncState.swift` header), so the only backward-compat concern
  is a device decoding its *own* previously-written rows — the legacy
  decoder covers it. Forward-incompat (old build reading new JSON) follows
  the project's existing one-way-migration posture.

- **`.attributed(to:)` helper** — innermost provider wins:

  ```swift
  func attributed(to provider: SyncProvider) -> WalletSyncError {
    guard self.provider == nil else { return self }
    return WalletSyncError(provider: provider, kind: kind)
  }
  ```

### 3. Boundary stamping (one point per provider)

- **`AlchemyClient`** — stamp `.alchemy` at its public method boundaries.
  Covers the engine's `account-validation` malformed-response throw
  (`WalletSyncEngine.swift:94`) and `WalletSyncSource.swift:33`
  `chain-lookup`, which are Alchemy-backed lookups.
- **`BlockExplorerClient`** — stamp `.blockExplorer` at its public surface.
- **`CoinstashSyncSource`** — set `.coinstash` directly on the errors it
  constructs (`CoinstashSyncSource.swift:52–65`).
- **`CryptoPriceService`** — the price loop tolerates per-provider failures
  and only throws when *all* providers are exhausted. On total failure,
  throw an **attributed** `WalletSyncError(provider: <last provider
  attempted>, kind: .network(underlyingDescription: …))` instead of a bare
  `CryptoPriceError`. Skipped/tolerated providers are not named (matches
  the existing last-error semantics).

A small async boundary helper may be introduced to avoid repeating the
catch/re-stamp at each provider's public methods:

```swift
func withProvider<T>(_ provider: SyncProvider,
                     _ body: () async throws -> T) async throws -> T {
  do { return try await body() }
  catch let e as WalletSyncError { throw e.attributed(to: provider) }
}
```

### 4. Catch-all boundary — unchanged

`SyncedAccountStore+Internals.swift:144` already re-throws an existing
`WalletSyncError` **verbatim** (no re-wrap), so attribution survives the
persist path. The generic `catch` (line 151) keeps mapping genuinely
unknown errors to `WalletSyncError.network(…)` with `provider: nil`.

### 5. Caption — `SyncedAccountHeaderLogic.errorCaption`

Prefer `error.provider?.displayName`:

- When `provider != nil`: prefix/interpolate the provider's `displayName`
  (replacing the hard-coded `"Alchemy"` strings and the post-hoc
  `account.exchangeProvider?.displayName` lookup).
- When `provider == nil` (legacy rows / genuinely unknown): fall back to
  **today's byte-identical strings**, branching on `account.type` exactly
  as now — preserving the existing `WalletAccountHeaderLogic` caption
  contract and its tests.

### 6. Mechanical updates (enum → struct)

Sites pattern-matching the old bare enum must move to `kind`:

- `BlockExplorerClient.swift:164` — `catch WalletSyncError.invalidApiKey`
  → `catch let e as WalletSyncError where e.kind == .invalidApiKey`.
- `SyncedAccountHeaderLogic.errorCaption` `switch` → switch on
  `error.kind`.
- Any test asserting `== WalletSyncError.network(…)` or switching on the
  bare enum — update to the struct/`kind` shape.
- The implementation plan enumerates the full list from a fresh
  `grep` of `WalletSyncError\.` / `case .network`-style matches.

### 7. DataFormatVersion check (plan task)

`DataFormatVersion.current` is currently `2`. `WalletSyncState` is a
per-device checkpoint and is **not** a cross-device sync boundary, so a
bump is not expected. The plan must explicitly verify this against
`DataFormatVersion.swift`'s "forward-incompatible synced change" criterion
and document the conclusion rather than assume it.

## Testing

- `WalletSyncError` legacy bare-enum JSON decodes to
  `{provider: nil, kind: …}`; new shape round-trips.
- `.attributed(to:)` is innermost-wins (a pre-attributed error is not
  overwritten by an outer boundary).
- Each provider boundary stamps the right `SyncProvider`:
  Alchemy / Blockscout / Coinstash, and the price path attributes the
  **last provider attempted** on total failure (and stays silent on a
  tolerated single-provider failure).
- `errorCaption` renders `provider.displayName` when present and falls
  back to the byte-identical legacy strings when `provider == nil`.
- Update existing `WalletSyncError` / `errorCaption` tests to the new
  struct shape.

## Out of Scope

- New logging or os_log surfaces.
- A second persisted column or any change to cross-device sync.
- Naming *every* price provider attempted (only the last on total
  failure).
- Unrelated refactors of the sync orchestrator.
