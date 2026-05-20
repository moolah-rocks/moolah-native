---
name: automate-app
description: Use when driving the running Moolah macOS app from the terminal — verifying a UI change end-to-end, inspecting account/transaction/earmark state, creating or tearing down a test profile's data, or opening the app to a specific view. Also use when a task mentions AppleScript (`osascript`).
---

# Automating the Moolah App

Drive the running Moolah macOS app via AppleScript (`osascript`). Data operations and navigation both go through the AppleScript dictionary.

## CRITICAL: Profile Safety

**Before taking ANY automation action, you MUST confirm with the user which profile to use.** Never assume a profile. Never default to the first profile. Ask explicitly, every time, even if there's only one profile open. This is real financial data — testing operations must not be performed on important profiles.

**Recommended first step for testing:** Suggest creating a dedicated test profile via the app's UI or AppleScript.

## Prerequisites

The app must be built and running in **this worktree**. Use `just run-mac` to build and launch, or `just run-mac-with-logs` to also capture logs.

### Why the wrapper

Do **not** use raw `osascript -e 'tell application "Moolah" to …'` for Moolah automation. `osascript` resolves "Moolah" through LaunchServices, which picks `/Applications/Moolah.app` (the installed release build) over the worktree's debug build. Your automation will silently read from and write to the wrong app.

**All automation goes through the wrapper.** It accepts a body and (optionally) an `--app` path; in return you get the right bundle targeted, a stderr line showing the resolved path, and a duplicate-instance check that refuses to start a second Moolah against the same CloudKit container.

- `.claude/skills/automate-app/scripts/moolah-tell` — AppleScript runner; auto-wraps the body in `tell application "<abs-path>" … end tell`.

#### Picking the bundle

The wrapper resolves the target Moolah.app two ways. Pick whichever fits your environment:

1. **CWD-resolved (default).** With no `--app` flag, the wrapper takes `git rev-parse --show-toplevel` of CWD and appends `.build/Build/Products/Debug/Moolah.app`. Use this when your shell's working directory is already inside the worktree — typical interactive use.

   ```bash
   cd /path/to/<worktree>
   .claude/skills/automate-app/scripts/moolah-tell 'get name of every profile'
   ```

2. **Explicit path (`--app`).** Pass the absolute bundle path as the first argument when you can't `cd` (some agent harnesses) or when you want to target a bundle that isn't in the current worktree's `.build/`. The path is used verbatim — no git lookup, no CWD dependency.

   ```bash
   .claude/skills/automate-app/scripts/moolah-tell \
     --app /abs/path/to/<worktree>/.build/Build/Products/Debug/Moolah.app \
     'get name of every profile'
   ```

Either way, the wrapper:

- prints `moolah-tell → <resolved-app>` on stderr so a wrong path is visible at the call site;
- fails fast with `error: Moolah.app not found at <path>` if the bundle is missing (and, in CWD-resolved mode, suggests `just run-mac`);
- refuses to launch when a different Moolah is already running, with the conflicting bundle path printed.

The wrapper never builds on your behalf — run `just run-mac` yourself first.

#### CWD pitfall (no `--app`)

Without `--app`, the bundle is derived from CWD. Calling the wrapper from a sibling checkout (e.g. `cd main && .worktrees/foo/.../moolah-tell …`) targets the **CWD's checkout, not the script's**. AppleScript resolves the path it's given; LaunchServices then launches a *second* instance from that path while the worktree's app is already up. Two Moolahs sharing the same CloudKit container is a recipe for a corrupted profile. The duplicate-instance check now catches this and refuses, but the cleaner answer is to either `cd` first or pass `--app` with the absolute bundle path.

Add the scripts dir to `$PATH` for the session if you'll call the wrapper repeatedly:

```bash
cd /path/to/<worktree>
export PATH="$PWD/.claude/skills/automate-app/scripts:$PATH"
moolah-tell 'get name of every profile'
```

## AppleScript Reference

Each example uses `moolah-tell` (full path: `.claude/skills/automate-app/scripts/moolah-tell`). The wrapper adds the outer `tell application` frame.

### Profile Operations

```bash
# List all open profiles
moolah-tell 'get name of every profile'

# Get profile currency
moolah-tell 'get currency of profile "Test"'

# Count profiles
moolah-tell 'count profiles'
```

### Account Operations

```bash
# List all accounts
moolah-tell 'get name of every account of profile "Test"'

# Get account balance
moolah-tell 'get balance of account "Savings" of profile "Test"'

# Get all account names and balances
moolah-tell 'get {name, balance} of every account of profile "Test"'

# Get per-instrument holdings (multi-instrument crypto/exchange accounts).
# `balance` only reflects the account's primary instrument; `positions`
# returns a list of "SYMBOL=quantity" strings for every held instrument.
# Instruments that net to zero are omitted (matches the positions view).
moolah-tell 'get positions of account "Trust - Coinstash" of profile "Test"'
# → OP=12.5, USDC=0.0, BTC=0.00032433, AUD=14.20

# Get net worth
moolah-tell 'net worth of profile "Test"'

# Create account
moolah-tell 'tell profile "Test" to create account name "New Account" type "bank"'
# Types: bank, cc, asset, investment

# Delete account
moolah-tell 'delete account "New Account" of profile "Test"'
```

### Transaction Operations

```bash
# Create a simple expense
moolah-tell 'tell profile "Test" to create txn with payee "Woolworths" amount -42.50 account "Everyday" category "Groceries"'

# Create with date and notes
moolah-tell 'tell profile "Test" to create txn with payee "Rent" amount -2000.00 account "Everyday" date (date "2026-04-01") notes "April rent"'

# Create income
moolah-tell 'tell profile "Test" to create txn with payee "Employer" amount 5000.00 account "Everyday" category "Salary"'

# List txns (payee and amount)
moolah-tell 'get {payee, amount} of every txn of profile "Test"'

# Get txn details
moolah-tell 'get {payee, date, amount, transaction type} of every txn of profile "Test"'

# Delete a txn
moolah-tell 'delete txn id "UUID-HERE" of profile "Test"'

# Pay a scheduled txn
moolah-tell 'pay txn id "UUID-HERE" of profile "Test"'
```

> **The transaction class is named `txn` in AppleScript.** The word
> "transaction" is reserved in AppleScript itself (System Events ships
> `begin transaction`/`end transaction`/`abort transaction` in its
> `misc` suite), so the bare class term cannot resolve as a class name
> in `every transaction`/`transaction id "…"`/`whose` contexts —
> the parser tokenises it as a keyword. Use `txn` instead:
> `every txn of profile "…" whose id is "…"`,
> `delete txn id "…" of profile "…"`,
> `count txns of profile "…"`,
> `create txn in profile "…" with payee "…" amount …`. The four-char
> code `'Txn '` is unchanged, so compiled `.scpt` files keep working.
> Fixed in [#923](https://github.com/ajsutton/moolah-native/issues/923).

### Earmark Operations

```bash
# List earmarks
moolah-tell 'get {name, balance} of every earmark of profile "Test"'

# Create earmark with target
moolah-tell 'tell profile "Test" to create earmark name "Holiday" target 5000.00'

# Create earmark without target
moolah-tell 'tell profile "Test" to create earmark name "Emergency Fund"'

# Get earmark balance
moolah-tell 'get balance of earmark "Holiday" of profile "Test"'
```

### Category Operations

```bash
# List categories
moolah-tell 'get name of every category of profile "Test"'

# Create category
moolah-tell 'tell profile "Test" to create category name "Groceries"'

# Create subcategory
moolah-tell 'tell profile "Test" to create category name "Fruit" parent "Groceries"'
```

### Refresh and Navigation

```bash
# Refresh data from backend
moolah-tell 'refresh profile "Test"'

# Navigate to a specific account (selects it in the sidebar and shows its
# detail pane — equivalent to clicking the row)
moolah-tell 'navigate to account "Savings" of profile "Test"'

# Navigate to a specific earmark (same: selects in sidebar, shows detail)
moolah-tell 'navigate to earmark "Holiday" of profile "Test"'
```

### Synced account testing (crypto / exchange)

For verifying a crypto/exchange import change end-to-end against a test
profile:

```bash
# Force a sync of every synced account (crypto AND exchange) now,
# bypassing the hourly staleness timer. Returns immediately; the sync
# runs in the background — watch logs for completion.
moolah-tell 'synchronize profile "Test"'

# Clear every transaction on a synced account so the next `synchronize`
# re-imports it from scratch (per-leg dedup is keyed on
# (accountId, externalId); with the legs gone the rebuild is clean).
# Keeps the account and its saved API token.
moolah-tell 'reset import of account "Trust - Coinstash" of profile "Test"'
```

Typical clean-resync verification loop (use the `run-mac-app-with-logs`
skill so the sync is captured):

```bash
moolah-tell 'reset import of account "Trust - Coinstash" of profile "Test"'
moolah-tell 'synchronize profile "Test"'
# wait for the sync to land, e.g.:
#   until grep -q "ExchangeSyncEngine.*Built .* candidates" .agent-tmp/app-logs.txt; do sleep 2; done
moolah-tell 'get positions of account "Trust - Coinstash" of profile "Test"'
```

### Screenshot

```bash
# Capture the profile window's content view to a PNG.
# Returns the path inside the container's temp dir.
moolah-tell 'capture screenshot of profile "Test"'
# → /Users/aj/Library/Containers/rocks.moolah.app/Data/tmp/moolah-screenshot-2026-05-14-074321-456.png
```

Renders the window's `contentView` in-process via AppKit
(`cacheDisplay(in:to:)`), so it does **not** require Screen Recording or
Accessibility permission — useful on agent / CI hosts where a TCC dialog
would block you. The PNG is at the display's native scale (2x on Retina).

The app picks the output path (a timestamped filename inside its
sandbox's temp dir) and returns it. To get the screenshot somewhere
else, copy it after the fact:

```bash
PATH_OUT=$(moolah-tell 'capture screenshot of profile "Test"')
cp "$PATH_OUT" ~/Desktop/moolah.png
open ~/Desktop/moolah.png
```

The path is chosen by the app rather than the caller because the
sandbox only grants `com.apple.security.files.user-selected.read-write`,
so AppleScript-supplied paths outside the container would be rejected.
Routing through the container temp sidesteps that entirely.

Caveats:

- The profile must already be open in a window. If unsure, send
  `navigate to profile "Test"` first.
- The capture is the `contentView` only — titlebar / traffic-light
  chrome is not included.
- Layer-backed content using a hardware-accelerated surface
  (`AVPlayerLayer`, raw Metal) may render black; the regular SwiftUI
  surface in Moolah captures fine.
- Old screenshots accumulate in the container temp dir; the app does
  not clean them up. `rm ~/Library/Containers/rocks.moolah.app/Data/tmp/moolah-screenshot-*.png`
  when you want to tidy up.

### Multi-line scripts

Pipe the body in on stdin (use `-` or omit the arg):

```bash
moolah-tell - <<'EOF'
tell profile "Test"
  set accts to {name, balance} of every account
  set cats to name of every category
  return {accts, cats}
end tell
EOF
```

## Navigation

`navigate to` is part of the AppleScript dictionary — use `moolah-tell`:

```bash
# Open / focus a profile window (opens it if not already visible)
moolah-tell 'navigate to profile "Test"'

# Switch the profile window's sidebar to a list view
moolah-tell 'navigate to every account of profile "Test"'
moolah-tell 'navigate to every earmark of profile "Test"'
moolah-tell 'navigate to every category of profile "Test"'

# Open a specific account or earmark's detail pane (matches sidebar click)
moolah-tell 'navigate to account "Crypto" of profile "Test"'
moolah-tell 'navigate to earmark "Holiday" of profile "Test"'
```

**Profile resolution:** Matches by name (case-insensitive), then by UUID. If the profile isn't open, a window opens for it.

## Common Test Workflows

### Verify account balance updates after transaction

```bash
# 1. Check initial balance
moolah-tell 'get balance of account "Everyday" of profile "Test"'

# 2. Create a txn
moolah-tell 'tell profile "Test" to create txn with payee "Test Purchase" amount -25.00 account "Everyday"'

# 3. Verify balance changed
moolah-tell 'get balance of account "Everyday" of profile "Test"'
```

### Verify UI navigation

```bash
# Focus the profile window
moolah-tell 'navigate to profile "Test"'

# Switch the sidebar to the accounts list
moolah-tell 'navigate to every account of profile "Test"'
```

### Create a full test environment

```bash
moolah-tell - <<'EOF'
tell profile "AI Test"
  create account name "Checking" type "bank"
  create account name "Savings" type "bank"
  create account name "Credit Card" type "cc"
  create category name "Food"
  create category name "Transport"
  create category name "Salary"
  create earmark name "Emergency Fund" target 10000.00
  create txn with payee "Employer" amount 5000.00 account "Checking" category "Salary"
  create txn with payee "Groceries" amount -150.00 account "Checking" category "Food"
  create txn with payee "Gas" amount -60.00 account "Credit Card" category "Transport"
end tell
EOF
```

### Verify data integrity after code changes

```bash
moolah-tell - <<'EOF'
tell profile "AI Test"
  set accts to {name, balance} of every account
  set cats to name of every category
  set earmarks to {name, balance} of every earmark
  return {accts, cats, earmarks}
end tell
EOF
```

## Error Handling

Put `try` / `on error` **inside** the body — `moolah-tell` supplies the outer `tell application`:

```bash
moolah-tell 'try
  get balance of account "Nonexistent" of profile "Test"
on error errMsg
  return "ERROR: " & errMsg
end try'
```

Common errors:
- **"Profile not found"** — profile isn't open or name is misspelled
- **"Account not found"** — account name doesn't match (matching is case-insensitive)
- **"Operation failed"** — backend error, check app logs with `run-mac-app-with-logs` skill
- **`error: Moolah.app not built at <path>`** followed by **`run 'just run-mac' in this worktree first`** (two stderr lines) — emitted by `moolah-tell` itself when the worktree's debug build is missing; run `just run-mac` and retry.
- **`error: moolah-tell must be run from inside a Moolah worktree`** — you're invoking the wrapper from outside any git repo; `cd` into the worktree first.

## Tips

- **Always use `moolah-tell`** — raw `osascript` targets `/Applications/Moolah.app`, not your worktree build.
- **Use AppleScript for both data operations and navigation** — `moolah-tell 'navigate to …'` focuses the profile window and switches the sidebar.
- **Always verify state after mutations** — read back the value you just changed.
- **Use the `run-mac-app-with-logs` skill** to capture app logs while running automation for debugging.
- **Amounts are Decimal** — expenses are negative, income is positive. Don't use `abs()`.
- **Profile must be open** — the profile needs to be open in a window for AppleScript data queries to work. `navigate to profile "X"` will open it if necessary.
