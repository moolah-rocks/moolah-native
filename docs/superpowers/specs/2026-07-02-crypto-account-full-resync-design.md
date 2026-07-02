# Full re-sync for a synced crypto account

**Date:** 2026-07-02
**Status:** Approved for implementation

## Problem

On a synced Ethereum wallet ("Trust - Ethereum" in the Real / Test profiles), a real
USDC → Coinstash transfer on 14 Aug 2025 (on-chain tx `0xa17de365…`) is missing its
ERC-20 leg — the wallet shows only the native ETH gas expense. Deleting the transaction
and pressing "Sync now" restores the ETH change but never re-imports the ERC-20 movement.

### Root cause (confirmed against production data + code)

Incremental sync computes `fromBlock = lastSyncedBlockNumber − 32`
(`WalletSyncEngine.subtractingReorgWindow`). Two facts combine:

1. **Deleting a transaction does not rewind `WalletSyncState.lastSyncedBlockNumber`.**
   There is no rewind-on-delete path. So after a delete, "Sync now" starts at
   `watermark − 32` and never revisits the deleted transaction's (older) block.

2. **The two providers honour `fromBlock` differently.** Alchemy sends `fromBlock` as a
   *server-side* filter (`AlchemyClient.fetchTransferPage`, param `fromBlock`), so it
   returns **only** transfers at block ≥ `fromBlock`. Blockscout sends **no** block
   parameter (`BlockExplorerClient.buildRequest`); `fromBlock` is only a client-side
   *stop-paginating* condition (`paginate`), so the newest page is always collected in
   full — native ETH transfers below `fromBlock` still come back.

Result: after a delete + incremental "Sync now", Blockscout re-imports the native ETH
legs (they sit on the recent first page) while Alchemy omits the ERC-20 legs below the
watermark. The single ERC-20 that *does* reappear is the wallet's most-recent transfer
(at the watermark block), which is why the watermark equals its block.

Verified block numbers for the reproduction wallet
(`0xa1eaee65e5fb8f05cca1cc2b9126550e23513511`, chain 1), watermark `23143119`,
`fromBlock 23143087`:

| Tx | Block | In Alchemy window? | Re-imported? |
|----|-------|--------------------|--------------|
| native income (Aug 14 05:55) | 23137339 | no | yes (Blockscout first-page over-fetch) |
| USDC transfer (Aug 14 06:18) | 23137458 | no | ETH gas only; ERC-20 dropped |
| spam ERC-20 (Aug 15 01:20) | 23143119 | yes | yes |

## Chosen fix

Add an explicit, user-triggered **full re-sync** for a synced account: reset that
account's watermark so the next sync fetches from genesis (`fromBlock = 0`), then run the
normal sync. Alchemy then returns all transfers; `WalletApplyEngine` dedups on
`(accountId, externalId)`, so existing rows are no-ops and only missing legs are added.
Because a single full pass fetches native (Blockscout) and ERC-20 (Alchemy) together, the
missing ERC-20 legs group into their transactions correctly (no split).

Incremental "Sync now" is left unchanged; the provider-asymmetry itself is not
"fixed" — the explicit action is the escape hatch.

Full re-sync is **non-destructive and idempotent**, so **no confirmation dialog**.

## Components

### 1. Backend — `SyncedAccountStore`

Add a `fullResync` flag to the per-account trigger:

```
func syncAccount(_ account: Account, fullResync: Bool = false) async
```

When `fullResync == true`:

- Return early if `inProgressAccountIds.contains(account.id)` — do not reset the
  watermark under an in-flight sync (its apply pass would write a head block back).
- `await walletSyncState.delete(accountId: account.id)` — awaited so the checkpoint is
  gone before the build reads it (`WalletSyncEngine.build` → `walletSyncState.load` →
  `nil` → `fromBlock = 0`).
- Then the existing `syncAccounts([account])` path runs unchanged. Its post-sync
  `updateSyncState` re-writes the head block, so state self-heals.

`WalletSyncStateRepository.delete(accountId:)` already exists and is idempotent.

### 2. macOS toolbar button — `SyncedAccountHeaderView`

Live-track the Option key with an `NSEvent.addLocalMonitorForEvents(matching: .flagsChanged)`
monitor (added on appear, removed on disappear) driving `@State private var optionHeld`.

- `optionHeld == false`: label "Sync now", action `syncAccount(account)`.
- `optionHeld == true`: label "Resync Now", action `syncAccount(account, fullResync: true)`.

macOS-only (`#if os(macOS)`); iOS keeps the plain "Sync now" button. The label/action
selection is extracted into a pure helper (input: `optionHeld`; output: title + a
`fullResync` bool) so it is unit-testable without the event monitor.

### 3. Account context menu — both platforms — `AccountSidebarRow`

Add a `.contextMenu` item **"Resync Now (Full History)"**, shown only for synced crypto
accounts, calling `syncAccount(account, fullResync: true)`. Right-click on macOS,
long-press on iOS — no extra button on either platform.

### 4. macOS menubar — `MoolahDomainCommands` `Account` menu

Add a **Sync Now / Resync Now** command that targets `selectedAccount`, disabled unless
it is a synced crypto account. Native Option-alternate single item: "Sync Now" (⌘R)
morphs to "Resync Now" (⌥⌘R) while Option is held. If SwiftUI cannot render the alternate
cleanly, fall back to two always-visible items. Mirrors the existing `.requestAccountEdit`
NotificationCenter pattern: post `.requestAccountSync` / `.requestAccountResync`, observed
by the view that owns `cryptoSyncStore`.

## Testing

- **Store:** with an in-memory `WalletSyncStateRepository` and a spy provider capturing
  `fromBlock`, assert `fullResync: true` deletes the checkpoint and drives `fromBlock = 0`,
  while the default keeps the watermark-derived value. Assert the in-flight guard: a
  `fullResync` while the account is in `inProgressAccountIds` does not delete the checkpoint.
- **Header helper:** `optionHeld → (title, fullResync)` mapping.
- **Menubar:** `.requestAccountSync` / `.requestAccountResync` posted with the selected
  account id; disabled when no synced crypto account is selected.

## Out of scope

- Rewinding the watermark automatically on transaction delete.
- Changing incremental sync semantics or the Alchemy/Blockscout `fromBlock` asymmetry.
- Exchange-account-specific re-sync semantics (the reset mechanism is generic, but the
  reported bug and this design target crypto wallets).
