# Crypto Provider Catalog + Re-detection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Pre-ship provider mappings (Binance/CoinGecko/CryptoCompare) for known crypto tokens and auto-upgrade already-registered instruments when richer mappings ship — so months stop rendering "—" for tokens that only had a `coingecko_id` (issue #1140).

**Architecture:** A bundled, generated `CryptoProviderCatalog` (curated Swift literal now, behind a protocol so a resource-backed "complete list" can drop in later) is consulted at session startup by a merge-only `reconcileProviderMappings` pass that fills missing provider columns on registered crypto instruments. A transient-safe vendoring script downloads each provider's full catalog once and regenerates the table; a weekly CI job opens a PR when it produces a clean diff.

**Tech Stack:** Swift 6 (Swift Testing, GRDB, `@MainActor` repositories), bash + `jq` for vendoring, GitHub Actions for the weekly job. Build/test/format via `just`.

---

## Context for the implementer

- **`instrumentId`** is `"{chainId}:{lowercased_address}"` for ERC-20s and `"{chainId}:native"` for native gas tokens (see `Instrument.crypto` in `Domain/Models/Instrument.swift:191`). It fully identifies a token; it is the catalog key.
- **`CryptoProviderMapping`** (`Domain/Models/CryptoProviderMapping.swift`) holds `instrumentId` + three optional provider ids (`coingeckoId`, `cryptocompareSymbol`, `binanceSymbol`). It is `Hashable`/`Equatable`.
- **Merge-only upsert already exists** at the DB layer: `GRDBInstrumentRegistryRepository+Upsert.swift` `mergeResolvedFields` fills nil provider columns and never downgrades a populated one. The reconciliation pass relies on this, and additionally skips the write entirely when nothing would change (no sync churn).
- **`allCryptoRegistrations()`** (`Domain/Repositories/InstrumentRegistryRepository.swift:22`) returns crypto rows that have **≥1** provider field set. All-nil stubs are out of scope for reconciliation (discovery resolves those).
- **Preset seeding** runs at session startup via `ProfileSession.seedBuiltInCryptoPresets` (`App/ProfileSession.swift:282`), which awaits `registerBuiltInPresetsIfMissing()` inside a task tracked in `crossStoreUpdateTasks`. Reconciliation is wired alongside it.
- **Lint:** `Shared/CryptoImport/` is NOT in `.swiftlint.yml`'s `excluded:` list, so generated Swift there IS linted (`file_length` warning 400 / error 1000). The curated catalog stays well under. `scripts/` IS excluded.
- **Tests** use Swift Testing (`@Test`/`@Suite`/`#expect`/`#require`), NOT XCTest. Run with `just test-mac <Filter>` (capture to `.agent-tmp/`). Contract tests build an in-memory `GRDBInstrumentRegistryRepository` via the `makeSubject()` pattern in `MoolahTests/Domain/InstrumentRegistryContractTests.swift`.
- **`CRYPTOCOMPARE_API_KEY`** is in `.env` (worktree + main checkout). It is a free-tier key (~100 calls/month) and was over its limit at planning time — the script needs exactly one bulk CC call, and merge-only safety means a CC-unavailable run still ships the keyless Binance/CoinGecko upgrades.

## File structure

| File | Responsibility | Action |
|---|---|---|
| `Domain/Models/CryptoProviderMapping.swift` | add merge-only `merging(_:)` | Modify |
| `Domain/Models/CryptoProviderCatalog.swift` | `CryptoProviderCatalog` protocol | Create |
| `Domain/Repositories/InstrumentRegistryRepository+Reconcile.swift` | `reconcileProviderMappings(using:)` | Create |
| `Shared/CryptoImport/BundledCryptoProviderCatalog.swift` | conformer reading generated entries | Create |
| `Shared/CryptoImport/BundledCryptoProviderCatalog+Generated.swift` | generated `static let entries` | Create (generated) |
| `scripts/crypto-provider-catalog.json` | committed merge anchor (canonical data) | Create (generated) |
| `scripts/vendor-token-registry.sh` | extend with provider-catalog pass | Modify |
| `scripts/test-vendor-provider-catalog.sh` | offline fixture self-test | Create |
| `App/ProfileSession.swift` | wire reconciliation at startup | Modify |
| `.github/workflows/vendor-token-registry.yml` | weekly auto-PR | Create |
| `MoolahTests/Domain/CryptoProviderMappingTests.swift` | `merging` unit tests | Create |
| `MoolahTests/Domain/InstrumentRegistryReconcileTests.swift` | reconciliation contract tests | Create |
| `MoolahTests/Shared/CryptoImport/BundledCryptoProviderCatalogTests.swift` | catalog data sanity tests | Create |

---

## Task 1: Merge-only `CryptoProviderMapping.merging(_:)`

**Files:**
- Modify: `Domain/Models/CryptoProviderMapping.swift`
- Test: `MoolahTests/Domain/CryptoProviderMappingTests.swift`

- [ ] **Step 1: Write the failing test**

Create `MoolahTests/Domain/CryptoProviderMappingTests.swift`:

```swift
import Testing

@testable import Moolah

@Suite("CryptoProviderMapping.merging")
struct CryptoProviderMappingTests {
  @Test("fills nil columns from other, never downgrades populated columns")
  func mergeFillsNilsOnly() {
    let stored = CryptoProviderMapping(
      instrumentId: "1:0xrpl", coingeckoId: "rocket-pool",
      cryptocompareSymbol: nil, binanceSymbol: nil)
    let catalog = CryptoProviderMapping(
      instrumentId: "1:0xrpl", coingeckoId: "WRONG",
      cryptocompareSymbol: "RPL", binanceSymbol: "RPLUSDT")

    let merged = stored.merging(catalog)

    #expect(merged.instrumentId == "1:0xrpl")
    #expect(merged.coingeckoId == "rocket-pool")  // populated column preserved
    #expect(merged.cryptocompareSymbol == "RPL")  // nil column filled
    #expect(merged.binanceSymbol == "RPLUSDT")  // nil column filled
  }

  @Test("no-op when nothing to fill returns an equal value")
  func mergeNoOpEqualsSelf() {
    let full = CryptoProviderMapping(
      instrumentId: "1:0xrpl", coingeckoId: "rocket-pool",
      cryptocompareSymbol: "RPL", binanceSymbol: "RPLUSDT")
    #expect(full.merging(.init(
      instrumentId: "1:0xrpl", coingeckoId: nil,
      cryptocompareSymbol: nil, binanceSymbol: nil)) == full)
  }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `just test-mac CryptoProviderMappingTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: FAIL — `value of type 'CryptoProviderMapping' has no member 'merging'`.

- [ ] **Step 3: Add the method**

In `Domain/Models/CryptoProviderMapping.swift`, before the closing brace of `struct CryptoProviderMapping`, add:

```swift
  /// Merge-only fill: returns a copy where each nil provider id is taken from
  /// `other`. A populated column is never overwritten; `instrumentId` is kept.
  /// Used by the startup reconciliation pass to upgrade a registered token's
  /// mapping from the bundled catalog without downgrading anything (#1140).
  func merging(_ other: CryptoProviderMapping) -> CryptoProviderMapping {
    CryptoProviderMapping(
      instrumentId: instrumentId,
      coingeckoId: coingeckoId ?? other.coingeckoId,
      cryptocompareSymbol: cryptocompareSymbol ?? other.cryptocompareSymbol,
      binanceSymbol: binanceSymbol ?? other.binanceSymbol)
  }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `just test-mac CryptoProviderMappingTests 2>&1 | tee .agent-tmp/t1.txt`
Expected: PASS (2 tests).

- [ ] **Step 5: Format + commit**

```bash
just format
git add Domain/Models/CryptoProviderMapping.swift MoolahTests/Domain/CryptoProviderMappingTests.swift
git commit -m "feat(crypto): add merge-only CryptoProviderMapping.merging (#1140)"
```

---

## Task 2: `CryptoProviderCatalog` protocol

**Files:**
- Create: `Domain/Models/CryptoProviderCatalog.swift`

No standalone test (a bare protocol). It is exercised by Task 3's stub and Task 4's data tests.

- [ ] **Step 1: Create the protocol**

Create `Domain/Models/CryptoProviderCatalog.swift`:

```swift
import Foundation

/// A pre-known, bundled lookup from instrument id to provider mapping. Lets
/// the app upgrade a registered token's price-provider mapping without a
/// network call when the token is one we vendored ahead of time (#1140).
///
/// The protocol is the seam that lets the storage strategy change without
/// touching consumers: today a curated in-memory Swift literal
/// (`BundledCryptoProviderCatalog`); later, if the curated set outgrows a
/// source literal, a resource-backed catalog parsing a bundled JSON of the
/// complete supported-token list, loaded lazily and released after use.
protocol CryptoProviderCatalog: Sendable {
  /// The pre-known mapping for `instrumentId` (`"{chainId}:{address}"` /
  /// `"{chainId}:native"`), or `nil` when the token is not in the catalog.
  func mapping(for instrumentId: String) -> CryptoProviderMapping?
}
```

- [ ] **Step 2: Verify it compiles**

Run: `just build-mac 2>&1 | tail -5`
Expected: build succeeds.

- [ ] **Step 3: Commit**

```bash
git add Domain/Models/CryptoProviderCatalog.swift
git commit -m "feat(crypto): add CryptoProviderCatalog protocol seam (#1140)"
```

---

## Task 3: `reconcileProviderMappings(using:)` startup pass

**Files:**
- Create: `Domain/Repositories/InstrumentRegistryRepository+Reconcile.swift`
- Test: `MoolahTests/Domain/InstrumentRegistryReconcileTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `MoolahTests/Domain/InstrumentRegistryReconcileTests.swift`:

```swift
import Foundation
import GRDB
import Testing

@testable import Moolah

@Suite("InstrumentRegistryRepository — reconcileProviderMappings")
@MainActor
struct InstrumentRegistryReconcileTests {
  /// In-memory test catalog returning fixed mappings by id.
  struct StubCatalog: CryptoProviderCatalog {
    let entries: [String: CryptoProviderMapping]
    func mapping(for instrumentId: String) -> CryptoProviderMapping? {
      entries[instrumentId]
    }
  }

  @MainActor
  func makeRepo() throws -> GRDBInstrumentRegistryRepository {
    let database = try ProfileIndexDatabase.openInMemory()
    return GRDBInstrumentRegistryRepository(
      database: database, onRecordChanged: { _ in }, onRecordDeleted: { _ in })
  }

  func rplInstrument() -> Instrument {
    .crypto(
      chainId: 1, contractAddress: "0xd33526068d116ce69f19a9ee46f0bd304f21a51f",
      symbol: "RPL", name: "Rocket Pool", decimals: 18)
  }

  @Test("fills missing binance/cc columns on a coingecko-only registration")
  func upgradesPartialMapping() async throws {
    let repo = try makeRepo()
    let rpl = rplInstrument()
    try await repo.registerCrypto(
      rpl,
      mapping: CryptoProviderMapping(
        instrumentId: rpl.id, coingeckoId: "rocket-pool",
        cryptocompareSymbol: nil, binanceSymbol: nil))

    let catalog = StubCatalog(entries: [
      rpl.id: CryptoProviderMapping(
        instrumentId: rpl.id, coingeckoId: "rocket-pool",
        cryptocompareSymbol: "RPL", binanceSymbol: "RPLUSDT")
    ])
    await repo.reconcileProviderMappings(using: catalog)

    let reg = try #require(
      try await repo.allCryptoRegistrations().first { $0.id == rpl.id })
    #expect(reg.mapping.coingeckoId == "rocket-pool")
    #expect(reg.mapping.cryptocompareSymbol == "RPL")
    #expect(reg.mapping.binanceSymbol == "RPLUSDT")
  }

  @Test("never downgrades a fuller stored mapping than the catalog")
  func neverDowngrades() async throws {
    let repo = try makeRepo()
    let rpl = rplInstrument()
    try await repo.registerCrypto(
      rpl,
      mapping: CryptoProviderMapping(
        instrumentId: rpl.id, coingeckoId: "rocket-pool",
        cryptocompareSymbol: "RPL", binanceSymbol: "RPLUSDT"))

    let catalog = StubCatalog(entries: [
      rpl.id: CryptoProviderMapping(
        instrumentId: rpl.id, coingeckoId: "WRONG",
        cryptocompareSymbol: nil, binanceSymbol: nil)
    ])
    await repo.reconcileProviderMappings(using: catalog)

    let reg = try #require(
      try await repo.allCryptoRegistrations().first { $0.id == rpl.id })
    #expect(reg.mapping.coingeckoId == "rocket-pool")  // not overwritten
    #expect(reg.mapping.binanceSymbol == "RPLUSDT")
  }

  @Test("no write (no onRecordChanged) when nothing changes")
  func noChurnWhenAlreadyCovered() async throws {
    let database = try ProfileIndexDatabase.openInMemory()
    final class Box { var ids: [String] = [] }
    let box = Box()
    let repo = GRDBInstrumentRegistryRepository(
      database: database,
      onRecordChanged: { id in box.ids.append(id) },
      onRecordDeleted: { _ in })
    let rpl = rplInstrument()
    let full = CryptoProviderMapping(
      instrumentId: rpl.id, coingeckoId: "rocket-pool",
      cryptocompareSymbol: "RPL", binanceSymbol: "RPLUSDT")
    try await repo.registerCrypto(rpl, mapping: full)
    box.ids.removeAll()

    await repo.reconcileProviderMappings(using: StubCatalog(entries: [rpl.id: full]))

    #expect(box.ids.isEmpty)  // already covered → no re-write, no sync churn
  }

  @Test("ignores tokens absent from the catalog")
  func ignoresUnknownTokens() async throws {
    let repo = try makeRepo()
    let rpl = rplInstrument()
    let stored = CryptoProviderMapping(
      instrumentId: rpl.id, coingeckoId: "rocket-pool",
      cryptocompareSymbol: nil, binanceSymbol: nil)
    try await repo.registerCrypto(rpl, mapping: stored)

    await repo.reconcileProviderMappings(using: StubCatalog(entries: [:]))

    let reg = try #require(
      try await repo.allCryptoRegistrations().first { $0.id == rpl.id })
    #expect(reg.mapping == stored)
  }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `just test-mac InstrumentRegistryReconcileTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: FAIL — `value of type '...Repository' has no member 'reconcileProviderMappings'`.

- [ ] **Step 3: Implement the reconciliation pass**

Create `Domain/Repositories/InstrumentRegistryRepository+Reconcile.swift`:

```swift
import Foundation
import OSLog

extension InstrumentRegistryRepository {
  /// Upgrade already-registered crypto instruments' provider mappings from
  /// `catalog`, merge-only. A catalog provider id fills a nil stored column;
  /// a populated stored column is never downgraded (see
  /// `CryptoProviderMapping.merging`). A token whose merge produces no change
  /// is skipped — no write, no sync fan-out.
  ///
  /// Complements `registerBuiltInPresetsIfMissing` (fresh-profile seeding):
  /// this is the *re-detection* path, so a profile that registered a token
  /// when only one provider listed it picks up a newly-shipped
  /// Binance/CryptoCompare mapping on the next launch (issue #1140).
  ///
  /// Operates over `allCryptoRegistrations()` (rows with ≥1 mapping field).
  /// Best-effort: per-token failures are logged and skipped. Cancellation
  /// returns immediately.
  func reconcileProviderMappings(using catalog: any CryptoProviderCatalog) async {
    let logger = Logger(
      subsystem: "com.moolah.app", category: "InstrumentRegistryReconcile")
    let registrations: [CryptoRegistration]
    do {
      registrations = try await allCryptoRegistrations()
    } catch is CancellationError {
      return
    } catch {
      logger.warning(
        "reconcileProviderMappings load failed: \(error.localizedDescription, privacy: .public)")
      return
    }
    for registration in registrations {
      do {
        try Task.checkCancellation()
        guard let preknown = catalog.mapping(for: registration.instrument.id) else { continue }
        let merged = registration.mapping.merging(preknown)
        guard merged != registration.mapping else { continue }
        try await registerCrypto(registration.instrument, mapping: merged)
      } catch is CancellationError {
        return
      } catch {
        logger.warning(
          """
          reconcileProviderMappings \(registration.instrument.id, privacy: .public): \
          \(error.localizedDescription, privacy: .public)
          """
        )
      }
    }
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `just test-mac InstrumentRegistryReconcileTests 2>&1 | tee .agent-tmp/t3.txt`
Expected: PASS (4 tests).

- [ ] **Step 5: Format + commit**

```bash
just format
git add Domain/Repositories/InstrumentRegistryRepository+Reconcile.swift MoolahTests/Domain/InstrumentRegistryReconcileTests.swift
git commit -m "feat(crypto): merge-only reconcileProviderMappings startup pass (#1140)"
```

---

## Task 4: Vendoring script + generated catalog + conformer

**Files:**
- Modify: `scripts/vendor-token-registry.sh`
- Create: `scripts/crypto-provider-catalog.json` (generated merge anchor)
- Create: `Shared/CryptoImport/BundledCryptoProviderCatalog+Generated.swift` (generated)
- Create: `Shared/CryptoImport/BundledCryptoProviderCatalog.swift` (conformer)
- Create: `scripts/test-vendor-provider-catalog.sh` (offline self-test)
- Test: `MoolahTests/Shared/CryptoImport/BundledCryptoProviderCatalogTests.swift`

### 4a — extend the vendor script

- [ ] **Step 1: Add gap tokens to `PROTECTED`**

In `scripts/vendor-token-registry.sh`, extend the `PROTECTED=(...)` array (around line 34) by appending the gap symbols on a new line inside the array:

```bash
  MATIC POL ARB
  RPL ILV IMX STRK HEX
```

(AVAIL is intentionally absent — it is not in the token lists; it is resolved via `EXTRA_COINGECKO_IDS` below.)

- [ ] **Step 2: Append the provider-catalog generation pass**

At the END of `scripts/vendor-token-registry.sh` (after the existing `echo "Wrote $OUT"` line), append the block below. It downloads the three provider catalogs (honouring fixture env vars for offline testing), resolves the curated universe, merges additively against the committed anchor, and emits both the anchor JSON and the Swift file.

```bash
# ---------------------------------------------------------------------------
# Provider-mapping catalog (issue #1140)
# ---------------------------------------------------------------------------
# Resolves each curated token to its Binance / CoinGecko / CryptoCompare ids
# by intersecting with each provider's FULL catalog (one bulk download each —
# never per-token). Merge-only against the committed anchor: a provider that
# is unavailable (rate-limit / network / non-200) contributes nothing, so no
# committed column is ever dropped. Writes the merged superset regardless, then
# exits non-zero if any provider was unavailable so CI declines to open a PR.

ANCHOR="scripts/crypto-provider-catalog.json"
CATALOG_SWIFT="Shared/CryptoImport/BundledCryptoProviderCatalog+Generated.swift"

# CoinGecko ids whose tokens are NOT in the impersonation token lists but that
# we still want priced (e.g. AVAIL). Addresses come from CoinGecko's platform
# map; never hand-typed.
EXTRA_COINGECKO_IDS=(avail)

# CoinGecko platform key per supported chain id.
declare -A CG_PLATFORM=( [1]=ethereum [10]=optimistic-ethereum [137]=polygon-pos [8453]=base )

require_key() {
  if [[ -z "${CRYPTOCOMPARE_API_KEY:-}" ]]; then
    echo "ERROR: CRYPTOCOMPARE_API_KEY is required (cannot confirm CryptoCompare availability without it)." >&2
    exit 2
  fi
}

# Download a provider catalog into $2, or copy from a fixture env var if set.
# Echoes "available" / "unavailable" on stdout; never aborts the script.
fetch_provider() {
  local name="$1" out="$2" url="$3" fixture_var="$4" header="$5"
  local fixture="${!fixture_var:-}"
  if [[ -n "$fixture" ]]; then
    cp "$fixture" "$out" && { echo available; return; }
    echo "  ! $name fixture $fixture unreadable" >&2; echo unavailable; return
  fi
  local code
  code=$(curl -sS --max-time 90 -o "$out" -w '%{http_code}' ${header:+-H "$header"} "$url" || echo 000)
  if [[ "$code" != "200" ]]; then
    echo "  ! $name download failed (HTTP $code)" >&2; echo unavailable; return
  fi
  # CryptoCompare returns HTTP 200 with {"Response":"Error"} on rate-limit.
  if jq -e '.Response? == "Error"' "$out" >/dev/null 2>&1; then
    echo "  ! $name returned Response:Error ($(jq -r '.Message // ""' "$out"))" >&2
    echo unavailable; return
  fi
  echo available
}

require_key

echo "Downloading provider catalogs…" >&2
bn="$tmp/binance.json"; cg="$tmp/coingecko.json"; cc="$tmp/cryptocompare.json"
bn_state=$(fetch_provider Binance "$bn" "https://api.binance.com/api/v3/exchangeInfo" MOOLAH_BINANCE_JSON "")
cg_state=$(fetch_provider CoinGecko "$cg" "https://api.coingecko.com/api/v3/coins/list?include_platform=true" MOOLAH_COINGECKO_JSON "")
cc_state=$(fetch_provider CryptoCompare "$cc" "https://min-api.cryptocompare.com/data/all/coinlist" MOOLAH_CRYPTOCOMPARE_JSON "authorization: Apikey ${CRYPTOCOMPARE_API_KEY}")
echo "  Binance=$bn_state CoinGecko=$cg_state CryptoCompare=$cc_state" >&2

# Empty stand-ins so jq can run even when a provider is unavailable.
[[ "$bn_state" == available ]] || echo '{"symbols":[]}' >"$bn"
[[ "$cg_state" == available ]] || echo '[]' >"$cg"
[[ "$cc_state" == available ]] || echo '{"Data":{}}' >"$cc"

# Curated (chain, SYMBOL, address) triples: the address registry we just built
# ($nested) PLUS the EXTRA ids resolved from CoinGecko's platform map.
cg_platform_json=$(for k in "${!CG_PLATFORM[@]}"; do echo "{\"$k\":\"${CG_PLATFORM[$k]}\"}"; done | jq -s 'add')
extra_ids_json=$(printf '%s\n' "${EXTRA_COINGECKO_IDS[@]}" | jq -R '.' | jq -s '.')

extra_triples=$(
  jq -n --argjson cgPlatform "$cg_platform_json" --argjson extraIds "$extra_ids_json" --slurpfile cg "$cg" '
    ($cgPlatform | with_entries({key: .value, value: .key})) as $byName  # platformName -> chainId
    | [ $cg[0][] | . as $c | $extraIds[] as $id | select($c.id == $id)
        | ($c.platforms // {}) | to_entries[]
        | select($byName[.key] != null and (.value | type == "string") and (.value | length) > 0)
        | {chain: $byName[.key], sym: ($c.symbol | ascii_upcase), addr: (.value | ascii_downcase)} ]'
)
registry_triples=$(
  jq -n --argjson nested "$nested" '
    [ $nested | to_entries[] | .key as $chain | .value | to_entries[]
        | .key as $sym | .value[] | {chain: $chain, sym: $sym, addr: (. | ascii_downcase)} ]'
)
all_triples=$(jq -n --argjson a "$registry_triples" --argjson b "$extra_triples" '($a + $b) | unique')

# Resolve each triple to {instrumentId, coingeckoId, cryptocompareSymbol, binanceSymbol}.
# coingeckoId: CoinGecko coin whose platform address on that chain == addr (clone-safe).
# binanceSymbol: SYM+"USDT" present & TRADING. cryptocompareSymbol: SYM listed in CC.
fresh=$(
  jq -n \
    --argjson triples "$all_triples" \
    --argjson cgPlatform "$cg_platform_json" \
    --slurpfile cg "$cg" --slurpfile bn "$bn" --slurpfile cc "$cc" '
      ($cg[0]) as $coins | ($bn[0].symbols) as $bnSyms | ($cc[0].Data) as $ccData
      | ( [ $coins[] | . as $c | ($c.platforms // {}) | to_entries[]
              | {key: (.value | ascii_downcase), value: $c.id} ] | from_entries ) as $cgByAddr
      | ( [ $bnSyms[] | select(.status == "TRADING") | {key: .symbol, value: true} ] | from_entries ) as $bnSet
      | reduce $triples[] as $t ({};
          ( $t.chain + ":" + $t.addr ) as $iid
          | .[$iid] = {
              instrumentId: $iid,
              coingeckoId: ($cgByAddr[$t.addr] // null),
              cryptocompareSymbol: (if ($ccData[$t.sym] != null) then $t.sym else null end),
              binanceSymbol: (if ($bnSet[$t.sym + "USDT"] == true) then ($t.sym + "USDT") else null end)
            } )'
)

# Merge-only against the committed anchor (union-fill; never clears a column).
[[ -f "$ANCHOR" ]] || echo '{}' >"$ANCHOR"
merged=$(
  jq -n --slurpfile old "$ANCHOR" --argjson fresh "$fresh" '
    ($old[0] // {}) as $o
    | ($o + $fresh) | keys_unsorted as $_  # ensure object
    | reduce ((($o|keys) + ($fresh|keys)) | unique)[] as $k ({};
        ($o[$k] // {}) as $a | ($fresh[$k] // {}) as $b
        | .[$k] = {
            instrumentId: $k,
            coingeckoId: ($a.coingeckoId // $b.coingeckoId),
            cryptocompareSymbol: ($a.cryptocompareSymbol // $b.cryptocompareSymbol),
            binanceSymbol: ($a.binanceSymbol // $b.binanceSymbol)
          })'
)

# Drop entries with no provider id at all (nothing to seed).
merged=$(jq 'with_entries(select(.value.coingeckoId or .value.cryptocompareSymbol or .value.binanceSymbol))' <<<"$merged")

# Write the anchor (sorted keys → idempotent).
jq -S '.' <<<"$merged" >"$ANCHOR"
echo "Wrote $ANCHOR ($(jq 'length' <<<"$merged") tokens)" >&2

# Emit the Swift file from the anchor.
entries=$(
  jq -r 'to_entries | sort_by(.key) | map(
    "    \"\(.key)\": CryptoProviderMapping(\n" +
    "      instrumentId: \"\(.key)\",\n" +
    "      coingeckoId: \(.value.coingeckoId | if . then "\"\(.)\"" else "nil" end),\n" +
    "      cryptocompareSymbol: \(.value.cryptocompareSymbol | if . then "\"\(.)\"" else "nil" end),\n" +
    "      binanceSymbol: \(.value.binanceSymbol | if . then "\"\(.)\"" else "nil" end))"
  ) | join(",\n")' <<<"$merged"
)
cat >"$CATALOG_SWIFT" <<EOF2
// Generated by scripts/vendor-token-registry.sh — DO NOT EDIT BY HAND.
// Source of truth: scripts/crypto-provider-catalog.json
// Regenerate: \`scripts/vendor-token-registry.sh\` (then \`just format\`).
//
// Pre-known price-provider mappings for a curated set of tokens, keyed by
// instrument id ("chainId:address" / "chainId:native"). Consumed by
// \`BundledCryptoProviderCatalog\` and the startup reconciliation pass (#1140).

extension BundledCryptoProviderCatalog {
  static let entries: [String: CryptoProviderMapping] = [
$entries
  ]
}
EOF2
echo "Wrote $CATALOG_SWIFT" >&2

# Fail loudly (but non-destructively) if any provider was unavailable.
if [[ "$bn_state" != available || "$cg_state" != available || "$cc_state" != available ]]; then
  echo "WARNING: incomplete run (Binance=$bn_state CoinGecko=$cg_state CryptoCompare=$cc_state); committed mappings preserved, no symbols dropped." >&2
  exit 1
fi
```

> Implementer note: verify the final script parses with `bash -n scripts/vendor-token-registry.sh` before running it. The resolution uses three jq passes — `registry_triples` (from the address registry), `extra_triples` (EXTRA ids via CoinGecko platforms), and `all_triples` (their union) — feeding the `fresh`/`merged` passes.

- [ ] **Step 3: Generate with the live keyless providers**

Run (CC will be unavailable while rate-limited — that's expected and safe):

```bash
set -a; source .env; set +a
scripts/vendor-token-registry.sh; echo "exit=$?"
```

Expected: writes `scripts/crypto-provider-catalog.json` and `Shared/CryptoImport/BundledCryptoProviderCatalog+Generated.swift`. Exit 1 if CC is rate-limited (Binance/CoinGecko upgrades still written); exit 0 if all three succeeded.

- [ ] **Step 4: Sanity-check the generated data**

Run:

```bash
jq '."1:0xd33526068d116ce69f19a9ee46f0bd304f21a51f"' scripts/crypto-provider-catalog.json
```

Expected: `coingeckoId: "rocket-pool"`, `binanceSymbol: "RPLUSDT"` (cryptocompareSymbol may be null if CC was rate-limited). Spot-check ILV/IMX/STRK have their `…USDT` symbols and AVAIL (`1:0xeeb4d8400aeefafc1b2953e0094134a887c76bd8`) has `coingeckoId: "avail"`, `binanceSymbol: null`.

### 4b — conformer + data tests

- [ ] **Step 5: Create the conformer**

Create `Shared/CryptoImport/BundledCryptoProviderCatalog.swift`:

```swift
import Foundation

/// Bundled provider-mapping catalog for a curated set of known tokens. The
/// data lives in the generated `BundledCryptoProviderCatalog+Generated.swift`
/// (produced by `scripts/vendor-token-registry.sh`); this is a lazily-init,
/// in-memory dictionary lookup. The `CryptoProviderCatalog` protocol seam lets
/// a future resource-backed "complete list" catalog drop in here unchanged
/// (#1140).
struct BundledCryptoProviderCatalog: CryptoProviderCatalog {
  func mapping(for instrumentId: String) -> CryptoProviderMapping? {
    Self.entries[instrumentId]
  }
}
```

- [ ] **Step 6: Write the data sanity test**

Create `MoolahTests/Shared/CryptoImport/BundledCryptoProviderCatalogTests.swift`:

```swift
import Testing

@testable import Moolah

@Suite("BundledCryptoProviderCatalog")
struct BundledCryptoProviderCatalogTests {
  let catalog = BundledCryptoProviderCatalog()

  @Test("RPL resolves to its Binance pair for keyless deep history")
  func rplHasBinance() {
    let m = catalog.mapping(for: "1:0xd33526068d116ce69f19a9ee46f0bd304f21a51f")
    #expect(m?.coingeckoId == "rocket-pool")
    #expect(m?.binanceSymbol == "RPLUSDT")
  }

  @Test("every entry's key matches its instrumentId and has ≥1 provider id")
  func entriesAreWellFormed() {
    for (key, mapping) in BundledCryptoProviderCatalog.entries {
      #expect(mapping.instrumentId == key)
      #expect(mapping.hasProviderMapping)
    }
  }

  @Test("unknown id returns nil")
  func unknownIsNil() {
    #expect(catalog.mapping(for: "1:0xnope") == nil)
  }
}
```

- [ ] **Step 7: Regenerate the Xcode project (new files) + format + build + test**

```bash
just generate
just format
just build-mac 2>&1 | tail -5
just test-mac BundledCryptoProviderCatalogTests 2>&1 | tee .agent-tmp/t4.txt
```

Expected: build succeeds; tests PASS.

### 4c — offline self-test for transient safety

- [ ] **Step 8: Create fixtures + self-test script**

Create `scripts/test-vendor-provider-catalog.sh`:

```bash
#!/usr/bin/env bash
# Offline self-test for the provider-catalog merge-only / transient-safety
# behaviour. Feeds fixtures via MOOLAH_*_JSON and asserts: (1) confirmed ids
# are written, (2) an unavailable provider never drops a committed column and
# the script exits non-zero, (3) re-running is a no-op.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
export CRYPTOCOMPARE_API_KEY=test-key

cat >"$tmp/binance.json" <<'J'
{"symbols":[{"symbol":"RPLUSDT","status":"TRADING"}]}
J
cat >"$tmp/coingecko.json" <<'J'
[{"id":"rocket-pool","symbol":"rpl","platforms":{"ethereum":"0xd33526068d116ce69f19a9ee46f0bd304f21a51f"}}]
J
cat >"$tmp/cc_ok.json" <<'J'
{"Data":{"RPL":{"Symbol":"RPL"}}}
J
cat >"$tmp/cc_ratelimited.json" <<'J'
{"Response":"Error","Message":"over your rate limit","Type":99,"Data":{}}
J

run() { MOOLAH_BINANCE_JSON="$tmp/binance.json" MOOLAH_COINGECKO_JSON="$tmp/coingecko.json" MOOLAH_CRYPTOCOMPARE_JSON="$1" scripts/vendor-token-registry.sh >"$tmp/log" 2>&1; echo $?; }

# Use a throwaway anchor + outputs so the test never touches committed files.
ANCHOR_BAK=$(mktemp); cp scripts/crypto-provider-catalog.json "$ANCHOR_BAK" 2>/dev/null || true
SWIFT_BAK=$(mktemp); cp Shared/CryptoImport/BundledCryptoProviderCatalog+Generated.swift "$SWIFT_BAK" 2>/dev/null || true
restore() { cp "$ANCHOR_BAK" scripts/crypto-provider-catalog.json 2>/dev/null || true; cp "$SWIFT_BAK" Shared/CryptoImport/BundledCryptoProviderCatalog+Generated.swift 2>/dev/null || true; }
trap 'restore; rm -rf "$tmp" "$ANCHOR_BAK" "$SWIFT_BAK"' EXIT

echo '{}' >scripts/crypto-provider-catalog.json

echo "1) clean run records confirmed CC symbol, exit 0"
[[ "$(run "$tmp/cc_ok.json")" == 0 ]] || { echo "FAIL: expected exit 0"; cat "$tmp/log"; exit 1; }
[[ "$(jq -r '."1:0xd33526068d116ce69f19a9ee46f0bd304f21a51f".cryptocompareSymbol' scripts/crypto-provider-catalog.json)" == "RPL" ]] || { echo "FAIL: CC symbol not recorded"; exit 1; }

echo "2) rate-limited CC preserves committed CC symbol + exits non-zero"
ec="$(run "$tmp/cc_ratelimited.json")"
[[ "$ec" != 0 ]] || { echo "FAIL: expected non-zero on unavailable provider"; exit 1; }
[[ "$(jq -r '."1:0xd33526068d116ce69f19a9ee46f0bd304f21a51f".cryptocompareSymbol' scripts/crypto-provider-catalog.json)" == "RPL" ]] || { echo "FAIL: rate-limit dropped committed CC symbol"; exit 1; }

echo "3) idempotent: a second clean run produces no diff"
run "$tmp/cc_ok.json" >/dev/null
cp scripts/crypto-provider-catalog.json "$tmp/first.json"
run "$tmp/cc_ok.json" >/dev/null
diff <(jq -S . "$tmp/first.json") <(jq -S . scripts/crypto-provider-catalog.json) || { echo "FAIL: not idempotent"; exit 1; }

echo "ALL PASS"
```

- [ ] **Step 9: Run the self-test**

```bash
chmod +x scripts/test-vendor-provider-catalog.sh
scripts/test-vendor-provider-catalog.sh
```

Expected: prints `ALL PASS`. (It restores the committed anchor/Swift afterwards.)

- [ ] **Step 10: Re-generate against the real providers to restore committed data, then commit**

```bash
set -a; source .env; set +a
scripts/vendor-token-registry.sh || true   # exit 1 if CC rate-limited is fine
just generate && just format
git add scripts/vendor-token-registry.sh scripts/crypto-provider-catalog.json \
  scripts/test-vendor-provider-catalog.sh \
  Shared/CryptoImport/BundledCryptoProviderCatalog.swift \
  Shared/CryptoImport/BundledCryptoProviderCatalog+Generated.swift \
  MoolahTests/Shared/CryptoImport/BundledCryptoProviderCatalogTests.swift
git commit -m "feat(crypto): vendor + bundle provider-mapping catalog (#1140)"
```

---

## Task 5: Wire reconciliation into session startup

**Files:**
- Modify: `App/ProfileSession.swift`

- [ ] **Step 1: Extend the seed method to also reconcile**

In `App/ProfileSession.swift`, replace the body of `seedBuiltInCryptoPresets(registry:)` (around line 295) so the same task seeds presets **and** reconciles from the bundled catalog (one task, tracked for cancellation):

```swift
  private func seedBuiltInCryptoPresets(
    registry: (any InstrumentRegistryRepository)?
  ) {
    guard let registry else { return }
    let task = Task {
      await registry.registerBuiltInPresetsIfMissing()
      // Re-detection: upgrade already-registered tokens (e.g. coingecko-only
      // RPL/ILV/IMX) with newly-shipped Binance/CryptoCompare mappings so deep
      // history resolves and months stop rendering "—" (issue #1140).
      await registry.reconcileProviderMappings(using: BundledCryptoProviderCatalog())
    }
    crossStoreUpdateTasks.append(task)
  }
```

- [ ] **Step 2: Update the doc comment**

Immediately above the method, extend the existing doc comment's first sentence to mention reconciliation, e.g. append after the `issue #791.` sentence:

```swift
  /// Then runs `reconcileProviderMappings` so tokens registered before a
  /// provider listed them pick up the newly-bundled mapping (issue #1140).
```

- [ ] **Step 3: Build + run the crypto/session tests**

```bash
just build-mac 2>&1 | tail -5
just test-mac InstrumentRegistryReconcileTests 2>&1 | tee .agent-tmp/t5.txt
```

Expected: build succeeds; tests PASS.

- [ ] **Step 4: Commit**

```bash
just format
git add App/ProfileSession.swift
git commit -m "feat(crypto): reconcile provider mappings at session startup (#1140)"
```

---

## Task 6: Weekly CI auto-PR workflow

**Files:**
- Create: `.github/workflows/vendor-token-registry.yml`

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/vendor-token-registry.yml`:

```yaml
name: Vendor token registry

on:
  schedule:
    - cron: "17 6 * * 1" # Mondays 06:17 UTC
  workflow_dispatch: {}

permissions:
  contents: write
  pull-requests: write

jobs:
  vendor:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Regenerate token registry + provider catalog
        id: gen
        env:
          CRYPTOCOMPARE_API_KEY: ${{ secrets.CRYPTOCOMPARE_API_KEY }}
        run: |
          if [ -z "$CRYPTOCOMPARE_API_KEY" ]; then
            echo "::error::CRYPTOCOMPARE_API_KEY secret is not set"; exit 1
          fi
          scripts/vendor-token-registry.sh
      - name: Open PR on a clean diff
        if: steps.gen.outcome == 'success'
        env:
          GH_TOKEN: ${{ github.token }}
        run: |
          if git diff --quiet; then
            echo "No changes — nothing to PR."; exit 0
          fi
          branch="chore/vendor-token-registry-$(date -u +%Y%m%d)"
          git config user.name "github-actions[bot]"
          git config user.email "github-actions[bot]@users.noreply.github.com"
          git checkout -b "$branch"
          git add scripts/crypto-provider-catalog.json \
            Shared/CryptoImport/CanonicalTokenRegistry+Bundled.swift \
            Shared/CryptoImport/BundledCryptoProviderCatalog+Generated.swift
          git commit -m "chore(crypto): refresh vendored token registry + provider catalog"
          git push origin "$branch"
          gh pr create --fill \
            --title "chore(crypto): refresh vendored token registry + provider catalog" \
            --body "Automated weekly refresh. Merge-only: a rate-limited provider this run preserved committed mappings (the job exits non-zero and skips the PR if any provider was unavailable, so this PR ran with all providers available)."
```

> The `if: steps.gen.outcome == 'success'` guard means a non-zero script exit (any provider unavailable) skips PR creation — incomplete runs never land unattended.

- [ ] **Step 2: Lint the workflow YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/vendor-token-registry.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/vendor-token-registry.yml
git commit -m "ci(crypto): weekly vendored-catalog refresh + auto-PR (#1140)"
```

> Manual setup (note in the PR description): add the `CRYPTOCOMPARE_API_KEY` repo secret. A dedicated CI key is advisable given the free-tier monthly cap.

---

## Task 7: Final verification + PR

- [ ] **Step 1: Full format-check (CI parity)**

Run: `just format-check 2>&1 | tail -20`
Expected: no diffs, no SwiftLint violations. Fix any inline (do NOT add a baseline).

- [ ] **Step 2: Run the affected test suites**

Run:

```bash
just test-mac CryptoProviderMappingTests InstrumentRegistryReconcileTests \
  BundledCryptoProviderCatalogTests InstrumentRegistryContractTests 2>&1 | tee .agent-tmp/final.txt
grep -i 'failed\|error:' .agent-tmp/final.txt || echo "no failures"
```

Expected: all PASS, "no failures".

- [ ] **Step 3: Re-run the script self-test**

Run: `scripts/test-vendor-provider-catalog.sh`
Expected: `ALL PASS`.

- [ ] **Step 4: Clean up temp files**

Run: `rm -f .agent-tmp/t1.txt .agent-tmp/t3.txt .agent-tmp/t4.txt .agent-tmp/t5.txt .agent-tmp/final.txt`

- [ ] **Step 5: Push + open the PR**

```bash
git push origin feature/crypto-provider-catalog:feature/crypto-provider-catalog
gh pr create --fill --title "feat(crypto): pre-ship provider mappings + re-detection (#1140)" \
  --body "$(cat <<'BODY'
Closes #1140.

- Generated `BundledCryptoProviderCatalog` (curated Swift literal, behind a `CryptoProviderCatalog` protocol so a resource-backed complete list can drop in later).
- Merge-only `reconcileProviderMappings` startup pass upgrades already-registered tokens (RPL/ILV/IMX gain `binance_symbol` → keyless deep history → months stop rendering "—").
- Transient-safe vendoring: one bulk download per provider, additive merge, non-zero exit if any provider is unavailable.
- Weekly CI auto-PR (needs `CRYPTOCOMPARE_API_KEY` repo secret).

HEX is included in the curated universe for probing; not reclassified.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

> Landing: use the `landing-prs` skill (auto-queue) once CI is green — per project default.

---

## Self-review notes

- **Spec coverage:** pre-shipped mappings (Task 4) ✓; re-detection / upgrade pass (Tasks 3, 5) ✓; transient-safe vendoring with the issue's hard requirements (Task 4a + self-test 4c) ✓; weekly CI auto-PR (Task 6) ✓; `CryptoProviderCatalog` protocol for Option-B drop-in (Task 2) ✓; HEX included-not-reclassified (Task 4a `PROTECTED`) ✓; AVAIL via `EXTRA_COINGECKO_IDS` ✓.
- **Type consistency:** `merging(_:)`, `mapping(for:)`, `reconcileProviderMappings(using:)`, `BundledCryptoProviderCatalog.entries` are referenced identically across tasks.
- **Verify before relying:** the implementer must `bash -n` the script and confirm `registry_triples`/`extra_triples`/`all_triples` resolve against the real catalogs before trusting the output. If CoinGecko's `optimistic-ethereum`/`polygon-pos`/`base` platform keys change, update `CG_PLATFORM`.
