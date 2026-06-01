# Moolah Help — Table of Contents

Date: 2026-05-23
Source: .agent-tmp/help-content/research.md
Output: Help/TOC.json

## Editorial principles

- **Write the product that ships.** Investments, trades, crypto wallet auto-import, and exchange (Coinstash) auto-import all ship and get help articles. The brand-guide §10 line "no investment tracking" is out of date; reconciling it is a separate task for the brand-guide owner and is not in scope here.
- **No phantom features.** Cleared/reconciled state, "Sign in with Google", explicit Sign Out, bulk multi-select edit, separate stock-tracking task, tip jar / IAP, multi-step tutorial, and auto-pay of scheduled transactions are all out of scope because the app does not implement them. Where a user might *expect* one (auto-pay, undo delete), it surfaces as a troubleshooting topic that sets the expectation correctly.
- **Sample-profile trial is a behaviour, not a feature.** The "Try Moolah without committing real data" article covers spinning up a throwaway profile and deleting it later; the app has no built-in sample data.
- **Single import-detection article.** No bank-specific parser enumeration. One reference-style article explains what import detects automatically and what doesn't.
- **en-AU spelling throughout.** Organise, customise, behaviour, recognise — per HELP_GUIDE.md §9.
- **Earn the slot.** When two tasks share more than ~70% of their steps, they collapse into one article with sub-sections (e.g. "Add or edit a transaction" rather than two). Section landings are listed so the help nav has scannable groupings even when there's no separate concept article.

## Top-level structure

Thirteen top-level sections plus Welcome. Roughly: getting started, then the data model from the outside in (profiles → accounts → transactions → scheduled → earmarks → categories), then the consumption views (reports/analysis, investments/crypto), then ingress (importing), then platform layers (sync/privacy, reference), then troubleshooting.

Choices worth flagging:

- **Investments and crypto are one section, not two.** They share the "synced account" header pattern, the trade transaction shape, and the registered-tokens story. Splitting them would force duplicate concept material.
- **Earmarks and budgets are one section.** A budget is a property of an earmark in this product; separating them creates a category with only one article on each side.
- **Sync and privacy are one section.** The privacy story is mostly a sync story (what leaves the device, where it goes). Two articles cover the practical questions; the concept lives in the section landing.
- **Reference is small.** Only three reference articles earn slots: the keyboard-shortcuts table, the crypto-chains-and-providers table, and (implicitly) the data-providers list folded in. Account types and exchange list don't need standalone reference; they're covered inline.
- **Troubleshooting is symptom-titled and independent.** Each article stands alone; users arrive via search, not browse.

Article count: **57** (within the 40–55 target band, slightly over to give troubleshooting room).

## Articles

### `welcome` — Welcome to Moolah

- **Type:** concept
- **Parent:** top-level
- **Length target:** 150–400 words (concept)
- **One-line scope:** Orient a brand-new user to what Moolah is and what they'll find in this help.
- **Key points / steps to cover:**
  - One-line product definition (personal finance for iPhone, iPad, Mac; manual entry; local-first; optional iCloud sync).
  - Where to start (link to Getting started).
  - What's covered in this help (brief tour of the top-level sections).
- **Vocabulary watch:** Do not use marketing taglines from BRAND_GUIDE.md §11 — HELP_GUIDE.md §2 explicitly bars them inside help.
- **Cross-links:** `getting-started`, `sync-and-privacy`, `accounts`

### `getting-started` — Getting started

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 150–400 words
- **One-line scope:** Set the floor: what a Moolah session looks like on day one.
- **Key points / steps to cover:**
  - Install → launch → Welcome screen → create a profile (no sign-up, no account).
  - iCloud is optional and detected automatically.
  - Brief mention of what to do next (add accounts, then transactions).
- **Vocabulary watch:** "Profile", "iCloud sync" (never "cloud sync" or "back up").
- **Cross-links:** `create-your-first-profile`, `add-an-account`, `turn-on-icloud-sync`

### `create-your-first-profile` — Create your first profile

- **Type:** task
- **Parent:** `getting-started`
- **Length target:** 200–600 words
- **One-line scope:** Get from a fresh install to a usable empty profile.
- **Key points / steps to cover:**
  - Welcome screen states (checking iCloud / iCloud off / no profiles / profiles waiting).
  - Tap Get started; name the profile; optionally adjust currency and financial-year start.
  - Result: empty profile loads.
- **Vocabulary watch:** "Currency" (not "instrument"); "financial year starts" (matches UI label).
- **Cross-links:** `pick-up-a-profile-on-another-device`, `add-an-account`, `manage-your-profiles`, `icloud-says-its-off`

### `try-moolah-without-committing-real-data` — Try Moolah without committing real data

- **Type:** task
- **Parent:** `getting-started`
- **Length target:** 200–300 words
- **One-line scope:** Show a curious user how to kick the tyres without contaminating their real data.
- **Key points / steps to cover:**
  - Create a second profile named e.g. "Sandbox".
  - Add a couple of fake accounts and transactions; explore.
  - When done, switch back to the real profile, then delete the sandbox.
  - Note: Moolah doesn't ship sample data; you make your own.
- **Vocabulary watch:** Don't call this "demo mode" or "trial" — it's just a throwaway profile.
- **Cross-links:** `manage-your-profiles`, `create-your-first-profile`

### `profiles` — Profiles

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 150–400 words
- **One-line scope:** Explain what a profile is and why someone might have more than one.
- **Key points / steps to cover:**
  - A profile is a self-contained set of accounts, earmarks, categories, transactions.
  - Each profile has its own default currency and financial-year start month.
  - On Mac, multiple profile windows can be open at once.
  - iCloud sync moves whole profiles between devices.
- **Vocabulary watch:** "Profile" (not "workspace", "vault").
- **Cross-links:** `manage-your-profiles`, `pick-up-a-profile-on-another-device`, `sync-and-privacy`

### `manage-your-profiles` — Add, switch, edit, or delete a profile

- **Type:** task
- **Parent:** `profiles`
- **Length target:** 300–600 words
- **One-line scope:** One article covering the four lifecycle actions on a profile.
- **Key points / steps to cover:**
  - Add: Settings > Profiles → +.
  - Switch: File > Open Profile (Mac) / profile chip (iOS).
  - Edit name, currency, financial-year start in Settings > Profiles → detail.
  - Delete: Settings > Profiles → − (or swipe iOS). Warn: irreversible, all data inside the profile is removed.
- **Vocabulary watch:** "Delete" (not "remove"); warn body must match HELP_GUIDE.md §13 destructive pattern.
- **Cross-links:** `export-or-import-a-profile`, `create-your-first-profile`, `sync-and-privacy`

### `export-or-import-a-profile` — Export or import a profile as a file

- **Type:** task
- **Parent:** `profiles`
- **Length target:** 200–500 words
- **One-line scope:** Walk through JSON export and import, for backups and device-to-device moves outside iCloud.
- **Key points / steps to cover:**
  - File > Export Profile… (Mac, ⇧⌘E); swipe export on profile row (iOS).
  - File > Import Profile… (Mac) / Settings > Add Profile → Import (iOS).
  - The format is plain JSON; the user owns it.
- **Vocabulary watch:** "JSON" is fine in this article; don't invent a brand name for the format.
- **Cross-links:** `manage-your-profiles`, `pick-up-a-profile-on-another-device`, `what-syncs-and-what-stays-on-device`

### `pick-up-a-profile-on-another-device` — Pick up a profile on another device

- **Type:** task
- **Parent:** `profiles`
- **Length target:** 200–500 words
- **One-line scope:** Use iCloud sync to make a profile show up on a second Apple device.
- **Key points / steps to cover:**
  - Same Apple ID; iCloud signed in on both devices.
  - Welcome screen "We found N profiles" banner.
  - First sync can take a moment.
- **Vocabulary watch:** "iCloud sync" (not "cloud", not "online sync").
- **Cross-links:** `turn-on-icloud-sync`, `icloud-says-its-off`, `manage-your-profiles`

### `accounts` — Accounts

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 200–500 words
- **One-line scope:** Define accounts and the six sub-types; introduce current vs investment groupings.
- **Key points / steps to cover:**
  - An account is a real-world place you keep money or assets.
  - Six sub-types: Bank Account, Credit Card, Asset, Investment, Crypto Wallet, Exchange.
  - "Current accounts" (bank/credit/asset) vs investment-like (investment/crypto/exchange).
  - Each account has a denominating currency.
- **Vocabulary watch:** "Currency" for fiat accounts. The Crypto Wallet's denominating instrument is a currency picker too; just say "currency".
- **Cross-links:** `add-an-account`, `sidebar-totals`, `investments-and-crypto`

### `add-an-account` — Add an account

- **Type:** task
- **Parent:** `accounts`
- **Length target:** 400–600 words
- **One-line scope:** Walk through the Add Account flow, with per-type notes.
- **Key points / steps to cover:**
  - Open New Account (sidebar +; ⌃⌘N on Mac).
  - Pick type; common fields (name, currency, opening balance, opening date).
  - Type-specific notes:
    - Credit Card: enter the balance owed as negative.
    - Asset: optional, for things like a car or house.
    - Investment: see `add-an-investment-account` for valuation mode.
    - Crypto Wallet: paste 0x address, pick chain. ENS isn't supported.
    - Exchange (Coinstash): paste read-only API token.
- **Vocabulary watch:** Sign convention — credit card debt is negative; refunds reverse the usual sign. Match CLAUDE.md.
- **Cross-links:** `edit-hide-reorder-or-delete-an-account`, `add-an-investment-account`, `add-a-crypto-wallet`, `add-an-exchange-account`, `sidebar-totals`

### `edit-hide-reorder-or-delete-an-account` — Edit, hide, reorder, or delete an account

- **Type:** task
- **Parent:** `accounts`
- **Length target:** 300–500 words
- **One-line scope:** Cover the lifecycle actions on an existing account in one article.
- **Key points / steps to cover:**
  - Edit: context menu → Edit Account.
  - Hide: Edit Account → Hidden toggle (only allowed at zero balance). Show via View > Show Hidden Accounts (⇧⌘H) on Mac or sidebar toggle on iOS.
  - Reorder: drag on Mac; Edit mode on iOS.
  - Delete: hide first, then delete from Edit Account when balance is zero. Irreversible; transactions go with it.
- **Vocabulary watch:** "Hidden", not "archived".
- **Cross-links:** `add-an-account`, `i-deleted-a-transaction-by-accident`

### `sidebar-totals` — Sidebar totals

- **Type:** reference
- **Parent:** `accounts`
- **Length target:** 200–400 words
- **One-line scope:** Define each total the user sees at the foot of the sidebar.
- **Key points / steps to cover:**
  - Current Total = sum across bank/credit/asset accounts.
  - Investment Total = sum across investment/crypto/exchange accounts.
  - Earmarked Total = sum across earmark balances.
  - Available Funds = Current Total − Earmarked Total (shown when earmarks > 0).
  - Net Worth = Current Total + Investment Total.
  - All in the profile's currency; conversion failures mark the total unavailable rather than fudging.
- **Vocabulary watch:** Use the on-screen labels verbatim. Don't say "asset value" for Investment Total.
- **Cross-links:** `accounts`, `earmarks-and-budgets`, `balance-looks-wrong`

### `transactions` — Transactions

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 200–500 words
- **One-line scope:** Define what a transaction is and the five user-facing types.
- **Key points / steps to cover:**
  - A transaction is a single recorded entry: date, payee, amount, type.
  - Types: Income, Expense, Transfer, Trade, Custom. (Opening Balance is system-generated, not user-pickable.)
  - Each transaction holds one or more legs; most users only see one.
  - Brief sign convention note: expenses negative, refunds positive, transfer/trade legs preserve user signs.
- **Vocabulary watch:** "Transaction" — never "entry", "record", "line item". "Note" — never "memo", "description".
- **Cross-links:** `add-or-edit-a-transaction`, `record-a-transfer`, `split-a-transaction`, `record-a-trade`

### `add-or-edit-a-transaction` — Add or edit a transaction

- **Type:** task
- **Parent:** `transactions`
- **Length target:** 400–600 words
- **One-line scope:** The everyday flow — create a new transaction or change an existing one.
- **Key points / steps to cover:**
  - Add: ⌘N on Mac / + on iOS / File > New Transaction.
  - Pick the account, type, date, amount, payee (with autocomplete), category, optional note, optional earmark.
  - Edit: select row → inspector (Mac) / sheet (iOS); ⏎ to open.
  - Delete: trash button, swipe, or ⌫. No undo — confirmation dialog warns.
  - Keyboard: ⌥⌘1–⌥⌘5 changes type.
- **Vocabulary watch:** "Payee" matches UI; "Notes" plural label, singular noun "note" in body.
- **Cross-links:** `split-a-transaction`, `set-up-a-recurring-transaction`, `i-deleted-a-transaction-by-accident`, `filter-and-search-transactions`

### `record-a-transfer` — Record a transfer between accounts

- **Type:** task
- **Parent:** `transactions`
- **Length target:** 400–600 words
- **One-line scope:** Move money between two of your own accounts; covers same-currency, cross-currency, and the "merge as transfer" alternative path.
- **Key points / steps to cover:**
  - Add a transaction, set Type = Transfer, pick source and destination.
  - When the two accounts have different currencies, a second amount field appears for the received amount; explain why both numbers matter.
  - Alternative: from two existing single-account transactions, select both → Transaction > Merge as Transfer (Mac) or accept the suggestion banner.
  - Undo a merge: Transaction > Split Back into Separate Transactions.
- **Vocabulary watch:** "Transfer" — never "move money", "shift", "internal transfer". Cross-currency uses "received amount" / "sent amount".
- **Cross-links:** `add-or-edit-a-transaction`, `transactions`, `balance-looks-wrong`

### `split-a-transaction` — Split a transaction across categories

- **Type:** task
- **Parent:** `transactions`
- **Length target:** 300–500 words
- **One-line scope:** Use Custom mode to break one transaction into multiple categorised legs against one account.
- **Key points / steps to cover:**
  - Open the transaction; change Type to Custom.
  - Add legs; each leg has its own category and optional earmark.
  - Legs must sum to the intended total; the form shows the running sum.
- **Vocabulary watch:** "Split" — never "multi-category transaction".
- **Cross-links:** `add-or-edit-a-transaction`, `categories`, `assign-a-transaction-to-an-earmark`

### `filter-and-search-transactions` — Filter and search transactions

- **Type:** task
- **Parent:** `transactions`
- **Length target:** 200–400 words
- **One-line scope:** Narrow down the transaction list by text, account, earmark, category, payee, date.
- **Key points / steps to cover:**
  - Search: ⌘F on Mac, search field on iOS.
  - Filter sheet: account, earmark, categories, payee, schedule status, date range.
  - Filters and search compose.
- **Vocabulary watch:** "Filter" is a verb in instructions, a noun for the sheet.
- **Cross-links:** `transactions`, `view-income-and-expense-by-category`

### `scheduled-transactions` — Scheduled transactions

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 200–500 words
- **One-line scope:** Define scheduled transactions and explicitly call out that Moolah does **not** auto-post them.
- **Key points / steps to cover:**
  - A scheduled transaction is future-dated; it may or may not also recur.
  - Scheduled-only (recur = Once) vs recurring (Day/Week/Month/Year with an "every N").
  - **Moolah does not post scheduled transactions automatically.** You pay them when they're due using Pay Now.
  - The Upcoming/Scheduled views list them.
- **Vocabulary watch:** "Scheduled transaction" is the noun. "Recurring" is an adjective for the sub-case. Do not use "auto-pay", "automatically post" except to deny it.
- **Cross-links:** `set-up-a-recurring-transaction`, `pay-a-scheduled-transaction`, `scheduled-transaction-didnt-post`

### `set-up-a-recurring-transaction` — Set up a recurring transaction

- **Type:** task
- **Parent:** `scheduled-transactions`
- **Length target:** 200–400 words
- **One-line scope:** Configure a transaction to repeat on a cadence.
- **Key points / steps to cover:**
  - Open the transaction; set a future date.
  - In the Recurrence section, choose Day/Week/Month/Year and the "every N" multiplier.
  - The cadence appears in plain English (e.g. "Every 2 weeks").
- **Vocabulary watch:** "Cadence" is fine internally — prefer "how often it repeats" in body.
- **Cross-links:** `scheduled-transactions`, `pay-a-scheduled-transaction`

### `pay-a-scheduled-transaction` — Pay a scheduled transaction

- **Type:** task
- **Parent:** `scheduled-transactions`
- **Length target:** 200–400 words
- **One-line scope:** Mark a scheduled transaction as done; advance the next occurrence.
- **Key points / steps to cover:**
  - Pay Now on the detail view; row action on the list; Transaction > Pay Scheduled Transaction.
  - Recurring: paying advances to the next date.
  - One-off (recur = Once): paying removes it from Scheduled.
  - You can change the date and amount during Pay if reality differed.
- **Vocabulary watch:** "Pay" matches UI button.
- **Cross-links:** `scheduled-transactions`, `set-up-a-recurring-transaction`, `scheduled-transaction-didnt-post`

### `earmarks-and-budgets` — Earmarks and budgets

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 200–500 words
- **One-line scope:** Define earmarks (the load-bearing product term) and how budgets relate.
- **Key points / steps to cover:**
  - An earmark is a user-named bucket of money set aside inside your accounts.
  - Earmarks aren't accounts; they overlay your account balances.
  - Available Funds = Current Total − Earmarked Total.
  - Earmarks can have a savings goal (target amount + optional date range).
  - Earmarks can have a budget (per-category planned spend).
- **Vocabulary watch:** "Earmark" — never "envelope", "goal", "savings goal" (savings goal is a property of an earmark).
- **Cross-links:** `create-an-earmark`, `set-a-budget-for-an-earmark`, `assign-a-transaction-to-an-earmark`, `sidebar-totals`

### `create-an-earmark` — Create an earmark

- **Type:** task
- **Parent:** `earmarks-and-budgets`
- **Length target:** 300–500 words
- **One-line scope:** Make a new earmark, optionally with a savings goal.
- **Key points / steps to cover:**
  - Sidebar Earmarks + (Mac toolbar / iOS section); ⇧⌘N.
  - Name, optional starting balance allocation.
  - Optional savings goal: target amount, optional start/end dates.
  - Hidden flag.
- **Vocabulary watch:** "Savings goal" is a property, not a separate object.
- **Cross-links:** `earmarks-and-budgets`, `set-a-budget-for-an-earmark`, `assign-a-transaction-to-an-earmark`

### `assign-a-transaction-to-an-earmark` — Assign a transaction to an earmark

- **Type:** task
- **Parent:** `earmarks-and-budgets`
- **Length target:** 200–400 words
- **One-line scope:** Tag a transaction so it counts against an earmark.
- **Key points / steps to cover:**
  - In transaction detail, pick from the Earmark field.
  - For splits, each leg can target a different earmark.
  - The earmark's spent/saved tally updates immediately.
- **Vocabulary watch:** "Assign" matches the brand voice; avoid "tag" (that's categories' word in other tools).
- **Cross-links:** `earmarks-and-budgets`, `split-a-transaction`, `create-an-earmark`

### `set-a-budget-for-an-earmark` — Set a budget for an earmark

- **Type:** task
- **Parent:** `earmarks-and-budgets`
- **Length target:** 300–500 words
- **One-line scope:** Allocate planned spending per category inside an earmark.
- **Key points / steps to cover:**
  - Open the earmark; go to the Budget tab.
  - Add line items: category + amount.
  - Edit by tapping a row; remove by swipe or context menu.
  - The tab shows planned vs actual per category.
- **Vocabulary watch:** "Budget line item" matches UI; "category" matches UI.
- **Cross-links:** `earmarks-and-budgets`, `categories`, `create-an-earmark`

### `categories` — Categories

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 150–400 words
- **One-line scope:** Explain categories and the parent/child tree.
- **Key points / steps to cover:**
  - A category is a user-defined classification for a transaction.
  - Categories form a tree (parent/child) — useful for grouping (e.g. Groceries > Supermarket / Markets).
  - Used in reports and analysis.
- **Vocabulary watch:** "Category" — never "tag", "label".
- **Cross-links:** `create-and-organise-categories`, `view-income-and-expense-by-category`, `set-a-budget-for-an-earmark`

### `create-and-organise-categories` — Create and organise categories

- **Type:** task
- **Parent:** `categories`
- **Length target:** 300–500 words
- **One-line scope:** Create, edit, nest, and delete categories — including the delete-with-reassignment flow.
- **Key points / steps to cover:**
  - Sidebar Categories → + (Mac) / ⌥⌘N.
  - Set a Parent in the picker to nest.
  - Edit name, icon, parent in the inspector/sheet.
  - Delete: optionally reassign existing transactions to another category in the same step.
- **Vocabulary watch:** "Nested category" is fine in body; UI calls it Parent.
- **Cross-links:** `categories`, `split-a-transaction`, `view-income-and-expense-by-category`

### `reports-and-analysis` — Reports and analysis

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 200–500 words
- **One-line scope:** Distinguish the Reports view from the Analysis view; orient the user.
- **Key points / steps to cover:**
  - Reports: income and expense by category for a date range. Drill into a category for the underlying transactions.
  - Analysis: net worth graph, upcoming card, income/expense table, expense breakdown, categories-over-time. History and forecast controls.
  - Both honour Earmark/account/category filters where applicable.
- **Vocabulary watch:** "Reports" and "Analysis" are distinct nouns; don't merge.
- **Cross-links:** `view-income-and-expense-by-category`, `analyse-net-worth-and-forecast`

### `view-income-and-expense-by-category` — View income and expense by category

- **Type:** task
- **Parent:** `reports-and-analysis`
- **Length target:** 250–500 words
- **One-line scope:** Use Reports to see where money came in and went out across a period.
- **Key points / steps to cover:**
  - Sidebar > Reports (⌘4).
  - Date range picker; Custom reveals From/To.
  - Click a row to drill into the filtered transaction list.
  - Income vs expense are separate views in the same screen.
- **Vocabulary watch:** "Date range" matches UI; spell out "This Financial Year", "Last 12 months" verbatim.
- **Cross-links:** `reports-and-analysis`, `filter-and-search-transactions`, `categories`

### `analyse-net-worth-and-forecast` — Analyse net worth and forecast upcoming months

- **Type:** task
- **Parent:** `reports-and-analysis`
- **Length target:** 300–500 words
- **One-line scope:** Read the Analysis view; control history and forecast windows.
- **Key points / steps to cover:**
  - Sidebar > Analysis (⌘5).
  - Net worth graph; expense breakdown.
  - History pickers (how far back) and Forecast pickers (None / 1 / 3 / 6 months).
  - Forecasts come from scheduled transactions — if you don't have any scheduled, the forecast is flat.
  - + on the toolbar creates a monthly scheduled placeholder.
- **Vocabulary watch:** "Forecast" matches UI; don't say "projection".
- **Cross-links:** `reports-and-analysis`, `scheduled-transactions`, `sidebar-totals`

### `investments-and-crypto` — Investments and crypto

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 300–500 words
- **One-line scope:** Cover the three relevant account flavours and the two valuation models for investment accounts.
- **Key points / steps to cover:**
  - Investment, Crypto Wallet, and Exchange are all account types.
  - Investment accounts have two valuation modes: Recorded value (manual snapshots) and Calculated from trades (positions + trade transactions).
  - Crypto wallets auto-import on-chain transactions via Alchemy (with Blockscout fallback). User-supplied Alchemy key.
  - Exchange (Coinstash) auto-imports trades via a read-only API token.
  - All three feed the Investment Total.
- **Vocabulary watch:** "Asset" for stocks in body copy when picking instruments. "Currency" for fiat. Never "instrument" user-facing.
- **Cross-links:** `add-an-investment-account`, `add-a-crypto-wallet`, `add-an-exchange-account`, `manage-crypto-tokens`, `sidebar-totals`

### `add-an-investment-account` — Add an investment account

- **Type:** task
- **Parent:** `investments-and-crypto`
- **Length target:** 300–500 words
- **One-line scope:** Create a non-synced investment account; choose how its value is tracked.
- **Key points / steps to cover:**
  - New Account → Investment.
  - Pick a valuation mode (Recorded value vs Calculated from trades).
  - Recorded value: you record balance snapshots.
  - Calculated from trades: enter trades, Moolah computes positions and current value at market prices.
  - You can switch modes later from Edit Account if you change your mind.
- **Vocabulary watch:** "Valuation mode" matches UI.
- **Cross-links:** `record-an-investment-snapshot`, `record-a-trade`, `investments-and-crypto`

### `record-an-investment-snapshot` — Record an investment value snapshot

- **Type:** task
- **Parent:** `investments-and-crypto`
- **Length target:** 200–300 words
- **One-line scope:** Record a manual balance reading on a Recorded-value investment account.
- **Key points / steps to cover:**
  - Open the investment account; tap + or Record Value.
  - Enter date and value.
  - Snapshots feed the net worth graph between recordings.
  - Delete a snapshot by swipe / context menu.
- **Vocabulary watch:** "Snapshot" is fine; UI uses "Record value".
- **Cross-links:** `add-an-investment-account`, `analyse-net-worth-and-forecast`

### `record-a-trade` — Record a trade

- **Type:** task
- **Parent:** `investments-and-crypto`
- **Length target:** 300–600 words
- **One-line scope:** Enter a buy, sell, or swap — including stock trades, since stocks live inside trade legs.
- **Key points / steps to cover:**
  - New Transaction → Type Trade. ⌥⌘4 on Mac.
  - Choose the investment account.
  - Paid leg (what left): currency or asset and amount.
  - Received leg (what arrived): the other currency or asset and amount.
  - Optional fee legs.
  - Sign convention: legs preserve user-entered signs; don't flip them.
  - This is also how you record a stock trade — the asset picker handles tickers (BHP.AX, NASDAQ:AAPL).
- **Vocabulary watch:** "Asset" for stocks; "currency" for fiat. Never "instrument".
- **Cross-links:** `add-an-investment-account`, `investments-and-crypto`

### `add-a-crypto-wallet` — Add a crypto wallet account

- **Type:** task
- **Parent:** `investments-and-crypto`
- **Length target:** 300–500 words
- **One-line scope:** Set up an auto-syncing crypto wallet account.
- **Key points / steps to cover:**
  - New Account → Crypto Wallet.
  - Pick a chain: Ethereum, OP Mainnet, or Base.
  - Paste a 0x address. ENS resolution is not supported — paste the 0x address.
  - Before sync runs, add an Alchemy API key in Settings > Crypto Tokens.
  - First sync may take a moment; the synced header shows status.
  - Each wallet transaction shows a block-explorer link and counterparty addresses. They're read-only and copy-only — explain that briefly so users know what those fields are.
- **Vocabulary watch:** "Crypto wallet" or "wallet" — never "Web3 account".
- **Cross-links:** `manage-crypto-tokens`, `wallet-or-exchange-isnt-syncing`, `supported-crypto-chains-and-providers`

### `add-an-exchange-account` — Add an exchange account

- **Type:** task
- **Parent:** `investments-and-crypto`
- **Length target:** 250–500 words
- **One-line scope:** Connect a Coinstash account using a read-only API token.
- **Key points / steps to cover:**
  - New Account → Exchange → Coinstash.
  - Create a **read-only** API token in your Coinstash account (link to their docs in body).
  - Paste the token. Stored in iCloud Keychain.
  - Sync starts automatically.
  - Replace the token later from Edit Account.
- **Vocabulary watch:** "Read-only API token" (not "API key" — Coinstash calls it a token).
- **Cross-links:** `wallet-or-exchange-isnt-syncing`, `investments-and-crypto`

### `manage-crypto-tokens` — Manage crypto tokens, discovered tokens, and spam

- **Type:** task
- **Parent:** `investments-and-crypto`
- **Length target:** 400–600 words
- **One-line scope:** Configure pricing for tokens, review the Discovered inbox, and mark spam.
- **Key points / steps to cover:**
  - Settings > Crypto Tokens.
  - Add Alchemy API key (required for wallet sync) and optional CoinGecko key (higher-priority pricing).
  - Registered Tokens: priced tokens; remove via ellipsis.
  - Discovered Tokens inbox: tokens seen on-chain but not priced; approve or mark spam.
  - Spam Tokens: hidden from balances and lists.
- **Vocabulary watch:** "Token" matches UI. "Discovered" and "Spam" match UI labels.
- **Authoring watch:** this article covers three closely-related Settings tasks (pricing, Discovered inbox, spam). If at draft it reads as three disconnected procedures, split it.
- **Cross-links:** `add-a-crypto-wallet`, `supported-crypto-chains-and-providers`, `wallet-or-exchange-isnt-syncing`

### `importing-data` — Importing data

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 200–500 words
- **One-line scope:** Frame the import story: CSV in, no bank-feed API, manual review encouraged.
- **Key points / steps to cover:**
  - Moolah imports CSV files. There is no bank-feed API.
  - Ways in: File menu, drag-and-drop, paste, watched folder.
  - Recently Added inbox surfaces what arrived since you last looked.
  - Rules can auto-categorise and auto-assign accounts.
- **Vocabulary watch:** "Import" — never "sync from bank" or "connect".
- **Cross-links:** `import-a-csv-file`, `review-recently-imported-transactions`, `create-and-manage-import-rules`, `how-import-detects-your-file`

### `import-a-csv-file` — Import a CSV file

- **Type:** task
- **Parent:** `importing-data`
- **Length target:** 300–500 words
- **One-line scope:** Get a CSV into Moolah by any of the available routes.
- **Key points / steps to cover:**
  - Mac: File > Import CSV (⇧⌘I); drag onto window or onto a sidebar account; File > Paste CSV (⌥⇧⌘V).
  - iOS: share-sheet from Files; drop onto the app.
  - First time for a new shape, Moolah may ask you to set it up (Recently Added → Needs Setup).
- **Vocabulary watch:** "CSV" — uppercase.
- **Cross-links:** `set-up-a-watched-folder`, `review-recently-imported-transactions`, `csv-import-needs-setup`, `how-import-detects-your-file`

### `set-up-a-watched-folder` — Set up a watched folder for imports

- **Type:** task
- **Parent:** `importing-data`
- **Length target:** 250–500 words
- **One-line scope:** Configure a folder Moolah scans for new CSVs.
- **Key points / steps to cover:**
  - Settings > Import > Pick folder.
  - Mac: live FS watch. iOS: scans at app launch.
  - Optional Delete CSVs after import toggle.
  - Stop watching from the same screen.
- **Vocabulary watch:** "Watched folder" / "folder watch" matches UI.
- **Cross-links:** `import-a-csv-file`, `review-recently-imported-transactions`

### `review-recently-imported-transactions` — Review recently imported transactions

- **Type:** task
- **Parent:** `importing-data`
- **Length target:** 300–500 words
- **One-line scope:** Confirm or correct what just landed.
- **Key points / steps to cover:**
  - Sidebar > Recently Added (badge shows unreviewed count).
  - Edit a row inline or in detail.
  - Per-row action: Create Rule from Transaction.
  - From a search, the toolbar offers "Create rule matching this search".
- **Vocabulary watch:** "Recently Added" matches UI.
- **Cross-links:** `create-and-manage-import-rules`, `import-a-csv-file`

### `create-and-manage-import-rules` — Create and manage import rules

- **Type:** task
- **Parent:** `importing-data`
- **Length target:** 400–600 words
- **One-line scope:** Author rules that auto-categorise or auto-assign imported transactions.
- **Key points / steps to cover:**
  - Where: Settings > Rules (Mac) / Settings > Import Rules (iOS).
  - Each rule has a name, scope (all accounts or one), conditions (any/all), actions (set category, set earmark, set account).
  - Conditions can match description, payee, amount range.
  - Live preview shows how many existing transactions would match.
- **Vocabulary watch:** "Rule" matches UI; "condition" and "action" are sub-terms.
- **Cross-links:** `review-recently-imported-transactions`, `categories`, `assign-a-transaction-to-an-earmark`

### `how-import-detects-your-file` — How CSV import works

- **Type:** concept
- **Parent:** `importing-data`
- **Length target:** 200–400 words
- **One-line scope:** Explain at a high level what auto-detection does and what triggers the manual mapper.
- **Key points / steps to cover:**
  - Moolah recognises common CSV shapes (header signatures, delimiters, date formats) and learns yours after the first set-up.
  - Files that don't match a known shape land in Needs Setup; you map columns once and Moolah remembers.
  - No bank-specific parser is named here — the detection is structural.
  - How to remove a learned file shape: go to **Settings > Import**, swipe the profile row, select **Delete**.
- **Vocabulary watch:** Don't list bank names. Don't promise detection of specific banks.
- **Cross-links:** `import-a-csv-file`, `csv-import-needs-setup`

### `sync-and-privacy` — Sync and privacy

- **Type:** concept (section landing)
- **Parent:** top-level
- **Length target:** 250–500 words
- **One-line scope:** State the privacy floor and explain what sync does and doesn't move.
- **Key points / steps to cover:**
  - Data lives on your device. Optional iCloud sync uses your own iCloud — there are no Moolah servers.
  - Sync is end-to-end encrypted by iCloud.
  - Crypto and exchange syncs talk to third-party providers (Alchemy, Blockscout, Coinstash, CoinGecko, etc.) directly from your device; the API keys are yours, not Moolah's.
  - Exchange API tokens live in iCloud Keychain; data lives in CloudKit.
- **Vocabulary watch:** Use approved phrasings from BRAND_GUIDE §11; HELP_GUIDE §14 forbids overstating ("we never see your data").
- **Cross-links:** `turn-on-icloud-sync`, `what-syncs-and-what-stays-on-device`, `icloud-says-its-off`, `manage-crypto-tokens`

### `turn-on-icloud-sync` — Turn on iCloud sync

- **Type:** task
- **Parent:** `sync-and-privacy`
- **Length target:** 200–400 words
- **One-line scope:** Walk through getting iCloud sync working.
- **Key points / steps to cover:**
  - Make sure iCloud is signed in at the system level on each device.
  - Same Apple ID across devices.
  - Sync starts automatically — nothing to flip in Moolah.
  - Status footer at the bottom of the sidebar.
  - Welcome screen iCloud-off chip offers an Open System Settings link if iCloud is unavailable.
- **Vocabulary watch:** "iCloud" — official product name; never "Cloud", "Apple Cloud".
- **Cross-links:** `pick-up-a-profile-on-another-device`, `icloud-says-its-off`, `what-syncs-and-what-stays-on-device`

### `what-syncs-and-what-stays-on-device` — What Moolah syncs

- **Type:** reference
- **Parent:** `sync-and-privacy`
- **Length target:** 250–500 words
- **One-line scope:** Inventory of synced vs device-local data.
- **Key points / steps to cover:**
  - Synced: profiles, accounts, transactions, legs, categories, earmarks, budget items, schedules, transfer suggestions, import profiles, import rules.
  - Device-local: rate caches, last-synced timestamps for crypto/exchange, folder-watch settings, active-profile selection, view state, price-provider API keys.
  - Exchange API tokens sync via iCloud Keychain, separately from data.
- **Vocabulary watch:** Match terms used in `sync-and-privacy`.
- **Cross-links:** `sync-and-privacy`, `export-or-import-a-profile`

### `reference` — Reference

- **Type:** reference (section landing — very brief)
- **Parent:** top-level
- **Length target:** 100–200 words
- **One-line scope:** Pointer to the look-it-up tables.
- **Key points / steps to cover:**
  - Index of the reference articles below.
- **Vocabulary watch:** Keep it short — no filler.
- **Cross-links:** `keyboard-shortcuts`, `supported-crypto-chains-and-providers`

### `keyboard-shortcuts` — Keyboard shortcuts

- **Type:** reference
- **Parent:** `reference`
- **Length target:** open-ended (tabular)
- **One-line scope:** macOS keyboard reference grouped by menu, plus the few iPad-with-keyboard shortcuts that work.
- **Key points / steps to cover:**
  - File, Edit, View, Go, Transaction, List Navigation, Help groups.
  - Use the symbol form (⌘⇧⌥⌃).
  - Omit the disabled placeholders (Sign Out, Copy Transaction Link, Find Next/Previous) — HELP_GUIDE §18 forbids referencing unreleased/disabled features.
- **Vocabulary watch:** Match the in-app Keyboard Shortcuts window layout for groupings.
- **Cross-links:** `add-or-edit-a-transaction`, `filter-and-search-transactions`

### `supported-crypto-chains-and-providers` — Supported crypto chains and data providers

- **Type:** reference
- **Parent:** `reference`
- **Length target:** open-ended (tabular)
- **One-line scope:** Two tables: chains and providers.
- **Key points / steps to cover:**
  - Chains: Ethereum, OP Mainnet, Base. Native: ETH. Explorers.
  - Not supported: Polygon, Arbitrum, Avalanche, Bitcoin — name them so users searching know.
  - Providers: Alchemy (on-chain, user key), Blockscout (fallback), Coinstash (exchange, user token), CoinGecko (token prices, optional user key), CryptoCompare (fallback prices), Binance (fallback prices), Frankfurter (fiat rates), Yahoo Finance (stocks).
- **Vocabulary watch:** Provider names match HELP_GUIDE §9 spirit — match how the company spells itself.
- **Cross-links:** `add-a-crypto-wallet`, `add-an-exchange-account`, `manage-crypto-tokens`, `sync-and-privacy`

### `troubleshooting` — Troubleshooting

- **Type:** reference (section landing — very brief)
- **Parent:** top-level
- **Length target:** 100–200 words
- **One-line scope:** Symptom-led index. Each article stands alone.
- **Key points / steps to cover:**
  - Brief framing: "Pick the symptom that matches what you're seeing."
  - Reach-out path if none of the articles fit (GitHub issues link via Help > Report a Bug).
- **Cross-links:** the eight troubleshooting children (capped at 5 in body per HELP_GUIDE §17; the rest live in the section nav).

### `icloud-says-its-off` — iCloud says it's off

- **Type:** troubleshooting
- **Parent:** `troubleshooting`
- **Length target:** 200–400 words
- **One-line scope:** Resolve the four iCloud-unavailable reasons surfaced on the welcome screen.
- **Key points / steps to cover:**
  - `notSignedIn` → open System Settings, sign in.
  - `restricted` → device restrictions; mention Screen Time.
  - `temporarilyUnavailable` → wait it out.
  - `entitlementsMissing` → applies to dev/internal builds; update to App Store build.
- **Vocabulary watch:** Don't say "error" pointing at the user.
- **Cross-links:** `turn-on-icloud-sync`, `sync-and-privacy`

### `icloud-storage-is-full` — iCloud storage is full

- **Type:** troubleshooting
- **Parent:** `troubleshooting`
- **Length target:** 150–300 words
- **One-line scope:** What the banner means and what to do.
- **Key points / steps to cover:**
  - Sync pauses when iCloud is full.
  - Free up iCloud storage or upgrade iCloud+.
  - Once there's room, sync resumes on its own; no in-app action needed.
- **Cross-links:** `turn-on-icloud-sync`

### `wont-open-this-profile` — Moolah won't open this profile

- **Type:** troubleshooting
- **Parent:** `troubleshooting`
- **Length target:** 150–300 words
- **One-line scope:** The "Update Moolah to Continue" screen — what causes it and what to do.
- **Key points / steps to cover:**
  - Cause: profile was last written by a newer version of Moolah.
  - Fix: update to the latest from the App Store, or open a different profile on this device.
  - This is a data-format guard, not a corruption.
- **Cross-links:** `manage-your-profiles`

### `wallet-or-exchange-isnt-syncing` — My wallet or exchange account isn't syncing

- **Type:** troubleshooting
- **Parent:** `troubleshooting`
- **Length target:** 300–500 words
- **One-line scope:** Resolve the inline-caption matrix for both crypto wallets and Coinstash.
- **Key points / steps to cover:**
  - Missing key/token: Settings > Crypto Tokens for Alchemy; Edit Account for Coinstash.
  - Rejected key/token: regenerate on provider side, paste again.
  - Rate limited: wait the displayed time.
  - Network error: connectivity / retry.
  - Malformed response: provider-side; retry later.
  - "Never synced" status: account has had no successful run yet — wait or retry.
- **Vocabulary watch:** Use the exact caption text from the synced header where possible.
- **Cross-links:** `manage-crypto-tokens`, `add-a-crypto-wallet`, `add-an-exchange-account`, `supported-crypto-chains-and-providers`

### `scheduled-transaction-didnt-post` — A scheduled transaction didn't post on its own

- **Type:** troubleshooting
- **Parent:** `troubleshooting`
- **Length target:** 100–250 words
- **One-line scope:** Set the expectation: Moolah doesn't auto-post.
- **Key points / steps to cover:**
  - Moolah does not post scheduled transactions automatically.
  - When a scheduled item is due, open it and tap Pay Now (or use the row action).
  - For recurring items, paying advances to the next date.
- **Vocabulary watch:** Don't use the word "bug" or apologise — it's a design choice.
- **Cross-links:** `pay-a-scheduled-transaction`, `scheduled-transactions`

### `csv-import-needs-setup` — CSV import dropped into Needs Setup

- **Type:** troubleshooting
- **Parent:** `troubleshooting`
- **Length target:** 150–300 words
- **One-line scope:** Resolve the Needs Setup state on a freshly imported file.
- **Key points / steps to cover:**
  - Open Recently Added → Needs Setup → row.
  - Tap Set up CSV import: pick the target account, map columns (Date / Description / Amount / Payee).
  - Moolah remembers the shape; future files of the same shape import without setup.
- **Cross-links:** `how-import-detects-your-file`, `import-a-csv-file`

### `balance-looks-wrong` — A balance looks wrong

- **Type:** troubleshooting
- **Parent:** `troubleshooting`
- **Length target:** 250–500 words
- **One-line scope:** Walk through the few legitimate ways a balance can look "off".
- **Key points / steps to cover:**
  - Multi-currency accounts: if a rate provider failed, the balance is shown as unavailable rather than summed wrong.
  - Hidden transactions: spam filter on or hidden account excluded — toggle View > Show Hidden Accounts / Show Spam Transactions.
  - Sign mistakes: refunds should be positive expenses; credit-card opening balances should be negative.
  - Pending sync: a recent change on another device may not have arrived yet — check the sync footer.
- **Vocabulary watch:** Don't assert a specific cause without checks; the article enumerates.
- **Cross-links:** `sidebar-totals`, `add-or-edit-a-transaction`, `sync-and-privacy`

### `i-deleted-a-transaction-by-accident` — I deleted a transaction by accident

- **Type:** troubleshooting
- **Parent:** `troubleshooting`
- **Length target:** 100–200 words
- **One-line scope:** Set expectations honestly: there's no undo.
- **Key points / steps to cover:**
  - Moolah doesn't have undo for deleted transactions.
  - If you remember the details, re-enter them — the date can be any past date.
  - For the future: the confirmation dialog says "This action cannot be undone" — that's the moment to stop.
- **Vocabulary watch:** Calm tone — don't apologise; don't scold.
- **Cross-links:** `add-or-edit-a-transaction`

## Gaps and decisions

- **Brand guide §10 mismatch** — says "no investment tracking" while the product ships investment, crypto wallet, and exchange account types. This ToC writes the product as it ships. Reconciliation is for the brand-guide owner, not for the help corpus.
- **Cross-currency transfer** — folded into `record-a-transfer` rather than a standalone article. The variant is a single sub-section about the second amount field that appears when accounts have different currencies. If a future review judges this too dense, promote the sub-section to its own article with slug `record-a-cross-currency-transfer`.
- **Merge as transfer** — folded into `record-a-transfer` as an alternative path. The "Split Back into Separate Transactions" undo lives in the same article.
- **Spam transaction toggle** — covered inside `balance-looks-wrong` (as a check) and `manage-crypto-tokens` (as the upstream). No standalone task article.
- **Hidden accounts toggle** — covered inside `edit-hide-reorder-or-delete-an-account` and `balance-looks-wrong`. No standalone task article.
- **Settings reference** — no standalone settings-walkthrough article. Each setting that matters is in the task article that uses it (Folder watch → set-up-a-watched-folder; Alchemy key → manage-crypto-tokens; financial-year start → manage-your-profiles).
- **About / Release Notes / Privacy Policy / Terms / Report a Bug** — these are Help menu items that open external URLs or system surfaces. They don't need help articles; the Help menu is self-explanatory.
- **AppleScript** — out of scope for user-facing help. Developer-facing audience.
- **`SignedOutView` tagline ("Personal finance, your way.")** — dead-code surface; not referenced anywhere in this ToC, consistent with the editorial ruling that the sign-in path is out of scope.
- **Issue #251 (online-banking share-sheet feature request)** — not mentioned. HELP_GUIDE §18 forbids "coming soon".

## Revision log

### 2026-05-23 — Review 1 fixes

- C1: Fixed broken cross-link slug `crypto-wallet-isnt-syncing` → `wallet-or-exchange-isnt-syncing` in `add-a-crypto-wallet` and `manage-crypto-tokens` cross-link lists.
- I1: Renamed `sidebar-totals` title from "Sidebar totals explained" → "Sidebar totals" in both `Help/TOC.json` and this plan.
- I2: Changed `sidebar-totals` declared type from concept → reference in this plan (length target unchanged).
- I3: Changed `how-import-detects-your-file` declared type from reference → concept and renamed title from "How import detects your file" → "How CSV import works" in both files (slug unchanged).
- I4: Raised lower bound to 200 words for `record-an-investment-snapshot` (200–300) and `try-moolah-without-committing-real-data` (200–300).
- I5: Renamed slug `update-moolah-to-continue` → `wont-open-this-profile` in both files (title unchanged); no cross-link in the plan referenced the old slug.
- M1: Changed `reference` and `troubleshooting` section-landing entries from type concept → reference in this plan (length targets unchanged).
- M2: Added an authoring-watch note to `manage-crypto-tokens` instructing the author to split the article if it reads as three disconnected procedures at draft.
- M3: Renamed `what-syncs-and-what-stays-on-device` title from "What syncs and what stays on your device" → "What Moolah syncs" in both files (slug unchanged).
- M4: Added key point to `how-import-detects-your-file` covering how to remove a learned file shape (Settings > Import → swipe → Delete).
- M5: Added key point to `add-a-crypto-wallet` covering the per-transaction block-explorer link and counterparty addresses (read-only / copy-only).

### 2026-05-23 — Review 2 fix

- N1: Updated `how-import-detects-your-file` length target from "open-ended (skim-first)" → "200–400 words" to match the concept type set by the I3 fix (§4 concept budget).
