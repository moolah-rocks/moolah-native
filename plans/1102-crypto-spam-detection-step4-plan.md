# #1102 crypto spam detection — Step 4 implementation plan

Decisions locked with the owner (2026-06-13). Builds on PR #1103 (name/URL +
keyword heuristics, already shipped). Research: see
`1102-crypto-spam-detection-research.md`.

## Locked decisions

1. **Alchemy `isSpam` is dead code** — confirmed firsthand that
   `alchemy_getTokenMetadata` *and* the Portfolio `tokens/by-address` endpoint
   return only `name/symbol/decimals/logo`; Alchemy's spam classification is
   NFT-only. There is no ERC-20 spam flag at any tier. → **Remove the dead
   path.**
2. **No third-party spam API.** GoPlus's licence requires written permission
   for commercial use + "Powered by Go+ Security" attribution → **skip.**
   Moralis needs a server proxy → **skip** (no backend wanted). Etherscan's
   SPAM/SUSPICIOUS reputation is **website-only** (the only API field is Pro
   Plus $899/mo, undocumented) → **not usable.** Note Etherscan's SPAM
   definition ("name/symbol contains url/scripts/refCodes") is already
   replicated by PR #1103's local heuristic.
3. **Impersonation detection** via a bundled, chain-scoped canonical token
   registry. **Flag outright** — a token whose symbol matches a protected
   token on its chain at a non-canonical address is spam regardless of
   price/balance.

## Slice A — remove the dead Alchemy `isSpam` path

`getTokenMetadata` is called *only* by `CryptoTokenDiscoveryService.fetchSpamFlag`,
which reads the always-`false` `isSpam`. Remove:

- `CryptoTokenDiscoveryService`: the `fetchSpamFlag` helper, the Alchemy
  round-trip in `performResolution`, and the `isSpam` precedence branch. New
  precedence: impersonation (Slice B) → priced → name heuristic → unpriced.
- `AlchemyClient.getTokenMetadata` (protocol + `LiveAlchemyClient`) and the
  `AlchemyTokenMetadata` struct + its custom decoder.
- Test doubles that conform `getTokenMetadata`: `CountingAlchemyClientStub`,
  `WalletSyncTestDoubles`, `CryptoSyncBenchmarkSupport`; and the discovery
  tests that script Alchemy spam (`spamWinsOverResolution`, the
  native-skips-spam assertions) — rewrite to the new precedence.

Acceptance: build + full `just test-mac`/`-ios` green; no reference to
`getTokenMetadata` / `AlchemyTokenMetadata` / `isSpam` remains; `just
format-check` clean. Adversarial note: confirm no sync/benchmark path depended
on the metadata call for anything but spam.

## Slice B — bundled canonical registry + impersonation detection

### Data: protected-symbol canonical registry

A curated set of **high-value symbols** (stablecoins + blue-chips +
governance) pinned to their canonical `(chainId, lowercased-address)`
deployments across our four chains (1, 10, 8453, 137). Curated — NOT the whole
multi-thousand-token universe — because treating every listed ticker as
protected would flag every coincidental ticker collision (huge false-positive
surface). The issue scopes this exactly: "canonical address for popular
tokens, especially stablecoins."

For each protected symbol, store **all** legitimate deployments per chain
(e.g. native USDC *and* bridged USDC.e on Polygon/Optimism) so "flag outright"
never hits a real multi-deployment token.

Initial protected set (resolve exact addresses via the vendoring script):
USDC, USDT, DAI, USDC.e, FRAX, TUSD, WETH, WBTC, OP, UNI, ARB, LINK, AAVE,
LDO, ENS, MATIC/POL, cbETH, rETH. (Tune during implementation.)

### Vendoring script

`scripts/vendor-token-registry.<sh|swift>` — fetches the authoritative lists
(Uniswap default token list; Optimism/Base bridge lists; Trust Wallet assets)
for the protected symbols on our chains, emits a checked-in resource
(`Shared/CryptoImport/Resources/CanonicalTokenRegistry.json`) keyed by
`chainId → symbol → [addresses]`. Re-runnable to refresh; the bundled JSON is
the source of truth at runtime (offline-safe, deterministic for tests). Log
which symbols/addresses were dropped so coverage gaps are visible (no silent
truncation).

### Logic: `CanonicalTokenRegistry` + impersonation check

- `CanonicalTokenRegistry` (pure, `Sendable`): loads the bundled JSON once;
  `isImpersonation(chainId:contractAddress:symbol:) -> Bool` →
  `true` when `symbol` (case-insensitive) is protected on `chainId` and
  `contractAddress` (lowercased) is not among that symbol's canonical
  addresses. Native tokens (nil address) → never impersonation.
- Wire into `CryptoTokenDiscoveryService.performResolution` **first** in the
  precedence (wins over a provider price, per "flag outright"):
  1. impersonation → `.spam`
  2. provider mapping resolved → `.priced`
  3. `CryptoSpamHeuristics` name/URL/keyword → `.spam`
  4. else → `.unpriced`

Acceptance / tests (TDD):
- Registry unit tests: OP at `0x4200…0042` on chain 10 = canonical (not
  impersonation); OP at any other address on chain 10 = impersonation; a fake
  USDC address on chain 1 = impersonation; the real USDC + bridged variants =
  not; an unprotected symbol ("OBSCURE") = never impersonation; native (nil
  address) = never.
- Discovery integration: a non-canonical "USDC" → `.spam` even when the
  resolver is scripted to return a price (proves "flag outright" precedence);
  the canonical USDC address → `.priced`.
- `just format-check` clean; full suite green.

## Sequencing

Both slices touch `performResolution`, which PR #1103 also edits. Land #1103
first, then branch Slice A off fresh `main`, then Slice B off Slice A (or
sequentially off main once A lands). Ship each as its own PR via the
merge queue.

## Out of scope / future

- Honeypot / transfer-tax / unverified-contract signals (needs GoPlus/Blockaid
  or simulation — declined on cost/ToS/infra grounds).
- The "0-value" qualifier from the issue: superseded by "flag outright"
  impersonation (no balance needed). Dust-airdrop value filtering can be a
  later refinement if false positives appear.
- Runtime list refresh (we bundle + re-vendor manually).
