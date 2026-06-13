# Crypto spam detection — research & roadmap (issue #1102)

Deep research into how production wallets, explorers, and trackers detect spam
ERC-20 tokens, mapped onto our Alchemy + CoinGecko/CryptoCompare/Binance Swift
stack. Sources are cited inline. Verified 2026-06-13.

## TL;DR

Industry uses a **layered** stack, not one signal:

1. **Curated, chain-scoped allowlists** keyed by exact `(chainId, EIP-55 address)`
   — the foundation for both whitelisting and impersonation detection.
2. **Third-party scoring/security APIs** (GoPlus, Moralis, Blockaid, Etherscan
   reputation, CoinGecko trust signals).
3. **On-chain / metadata heuristics** (name-contains-URL, honeypot/tax via
   simulation, unverified contract, dust airdrops, holder distribution).

All of the rules in #1102 align with documented industry practice.

## Findings

### 1. Trusted token lists are the canonical foundation

- **Uniswap Token Lists** — a standard JSON schema (`chainId`, `address`,
  `symbol`, `name`, `decimals`, `logoURI`, `tags`, `extensions`) for ERC-20
  metadata. <https://github.com/Uniswap/token-lists>,
  <https://uniswap.org/tokenlist.schema.json>
- **Trust Wallet assets** — community/PR-curated, several thousand tokens,
  organised as `blockchains/<chain>/assets/<EIP-55-checksummed-address>/` with
  `info.json` + `logo.png`. Each `info.json` carries an explicit `status`
  (`active` / `spam` / `abandoned`) — a per-token spam label a client can read
  directly. <https://github.com/trustwallet/assets>,
  <https://developer.trustwallet.com/developer/listing-new-assets/repository_details>
- Because every entry is pinned to **one canonical EIP-55 address per chain**,
  a token with a matching symbol/name at a *different* address is a distinct
  entry — which is exactly the mechanism for **impersonation detection** of
  stablecoins (USDC/USDT/DAI) and governance tokens (OP/UNI).
- Trust Wallet explicitly **rejects** brand-new / low-circulation tokens and
  removes "scam, high risk, stablecoin-mimicking, or fraudulent" assets.
- **Caveat:** list versioning is *not* a security mechanism, and lists are
  curated/incomplete — a client cannot rely on lists *alone*.

### 2. Third-party scoring / security APIs

- **GoPlus Token Security API** — the most directly **client-usable** dedicated
  security API: free, self-serve, 30+ detection items across contract security
  (`is_open_source`, `is_proxy`, `is_mintable`, `can_take_back_ownership`,
  `hidden_owner`, malicious code) and trading security (`buy_tax`, `sell_tax`,
  `slippage_modifiable`, `is_honeypot`, `is_blacklisted`, `transfer_pausable`).
  Covers our chains. <https://gopluslabs.io/en/token-security-api>
- **Moralis** `possible_spam` boolean + `exclude_spam` query param — but
  **server-side** (`X-API-Key`), so client use needs a proxy.
  <https://docs.moralis.com/data-api/evm/wallet/token-balances>
- **Blockaid** — detects impersonation tokens, malicious airdrops, honeypots
  across ETH/Base/Optimism/Polygon; integrated by MetaMask/Coinbase/Phantom.
  **Enterprise/B2B, no self-serve client API** → not practical for us.
  <https://www.blockaid.io/token-scanning>
- **Etherscan token reputation** — six states: `UNKNOWN`, `NEUTRAL`, `OK`,
  `SUSPICIOUS`, `UNSAFE`, `SPAM`. **`SPAM` is assigned specifically when the
  name/symbol contains a URL / scripts / referral codes** — directly validating
  our name heuristic. Mirrored on Optimistic Etherscan / Basescan / Polygonscan.
  Etherscan disclaims accuracy; not a clean programmatic API.
  <https://info.etherscan.com/etherscan-token-reputation/>
- **CoinGecko** by-contract token-info returns trust indicators (GT Score, GT
  Verified, `is_honeypot`, holder count/distribution) — partial per-chain
  coverage via GeckoTerminal.
  <https://docs.coingecko.com/reference/token-info-contract-address>

### 3. Heuristics, ranked by precision (qualitative — no source quantifies FPR)

| Heuristic | Precision | False-positive risk |
|---|---|---|
| Canonical-list address match (impersonation) | High | Low |
| Name/symbol contains URL/domain/refcode/script | High | Low |
| Honeypot / transfer-tax (needs **simulation** or a precomputed flag) | High | Low–med |
| Unverified contract | Med | Med |
| Airdrop/voucher/"invitation" phrasing | Med–high | Low–med |
| Dust / zero-value airdrop | Med | Med |
| Low holder count / token age / no liquidity | Low | **High** (legit new tokens trip it) |

Honeypot/tax detection is done by **transaction simulation** (Coinbase) — a
client should consume a precomputed flag (GoPlus/CoinGecko), not simulate.
<https://www.coinbase.com/blog/detecting-the-undetectable-coinbase-erc-20-scam-token-detection-system>

### 4. The #1102 rules vs industry practice

| #1102 rule | Verdict |
|---|---|
| URL/domain in name = spam | ✅ Matches Etherscan's published `SPAM` definition. **Shipped** in PR #1103. |
| "invitation token" = spam | ✅ Keyword/metadata matching is standard (Moralis). **Shipped** in PR #1103. |
| Canonical address for popular/stablecoin tokens; others spam | ✅ This is the trusted-list mechanism. Needs a bundled/fetched list. |
| OP only on Optimism at `0x…42`, else spam | ✅ Special case of impersonation detection via canonical list. |
| 0-value + same name as priced token, different address = spam | ✅ Impersonation + dust. Needs balance at classification time. |
| explorer-suspicious + no price = spam | ✅ "no price + suspicious" layering is industry-standard. |

## Correction to our current implementation

**`alchemy_getTokenMetadata` does NOT return `isSpam`** — only `name`, `symbol`,
`decimals`, `logo`. <https://www.alchemy.com/docs/reference/alchemy-gettokenmetadata>
Our `AlchemyTokenMetadata.isSpam` (`Shared/CryptoImport/AlchemyClient.swift`)
decodes that field with a `?? false` default, so **it has always been `false`
in production** — the Alchemy spam path is dead. Alchemy's real ERC-20
`isSpam` flag lives on the **Portfolio/Data API** (`getTokensByAddress`), a
different endpoint.

## Prioritized recommendations (value-per-cost)

1. **Bundle chain-scoped trusted lists** (Uniswap default + Trust Wallet
   assets, keyed by `(chain, EIP-55 address)`):
   - whitelist known-good tokens;
   - **impersonation detection** — flag a token whose symbol/name matches a
     listed token but whose address is non-canonical → spam. Covers the OP,
     stablecoin, and same-name-different-address rules at once.
2. **Local name/symbol heuristic** (URL/domain + scam phrasing). ✅ **Shipped**
   (PR #1103). Near-zero cost, high precision.
3. **GoPlus Token Security** for honeypot/tax/mint/unverified — the one
   dedicated security API that is free + client-self-serve. Highest added value
   for least cost; ahead of Blockaid (enterprise) and Moralis (needs proxy).
4. **Fix the Alchemy source** — either wire `isSpam` from the Portfolio API, or
   remove the dead JSON-RPC path.

## Open questions (need owner input — see issue thread / PR)

- Fix Alchemy `isSpam` via Portfolio API, or remove the dead path?
- Trusted lists: bundle static (vendored) vs fetch at runtime vs small
  hand-curated in-code set?
- Add GoPlus as a new dependency (and proxy/privacy posture), or stay
  self-contained with bundled lists + heuristics for now?
- The 0-value rule needs balance at classification time — incorporate balance,
  or is list-based impersonation enough to cover its intent?

## Caveats

Vendor capability claims (Blockaid, Moralis methodology, GoPlus list, Coinbase
architecture) are self-reported feature scope, not independently benchmarked
efficacy. No source quantifies precision/FPR, so thresholds remain empirical.
Several originally-cited vendor doc URLs 404 after restructures; canonical
pages carry equivalent content. Moralis/Blockaid are server-side/enterprise;
only GoPlus + bundled static lists are cleanly client-side.
