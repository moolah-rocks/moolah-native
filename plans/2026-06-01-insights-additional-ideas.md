# New Personalized-Insight Ideas — moolah-native (beyond Insight Catalog items 1–34)

> **Implementation status (updated):** the following were implemented in
> `Domain/Insights/` with tests in `MoolahTests/Domain/Insights/AdditionalInsightTests.swift`:
> **C-1** uncategorized backlog, **B-1** unreconciled transfers
> (`DataQualityInsights`); **A-1** group spend concentration
> (`AccountGroupInsights`); **E-3** windfall income, **E-2** pay-rate change
> (`IncomeExtraInsights`); **F-1** lapsed merchant, **E-4** weekend-spend skew
> (`SpendHabitInsights`); **F-2** unbudgeted-category spotlight
> (`BudgetCoverageInsights`). `InsightReferences` gained `groupIds`; `InsightInput`
> gained the account-group, budgeted-category, and data-quality-count fields these
> need. The remaining ideas (B-2/B-3 transfer-stream analysis, C-2/C-3/C-4 import
> reconciliation, D-1…D-5 crypto/multi-instrument, E-1/E-5) are not yet built —
> several need a parallel transfer-leg / native-instrument feed alongside
> `InsightTransaction`.
>
> **Editor's note (added when saving):** this report was produced by a survey
> agent against the codebase as of 2026-06-01, as the second half of the
> insights-core task. One correction to its "cross-cutting prerequisite":
> `InsightReferences` (`Domain/Insights/Insight.swift`) **already** carries
> `accountIds`, `instrumentIds`, and `transactionIds` in addition to
> `categoryIds`/`earmarkIds` — only a `groupId` field is genuinely missing
> for Theme A. The note about needing a parallel transfer-leg / income-stream
> feed (transfers are intentionally dropped by `InsightTransaction.records`)
> is accurate. Everything else is reproduced verbatim.

This proposes ~22 new deterministic, pure-Swift insight ideas that exploit data the original on-device-AI design (`plans/2026-04-18-on-device-ai-design.md`) never modeled, plus several it modeled but didn't fully exploit. The richest unmined seams are **post-design-doc features**: account groups/buckets (`Domain/Models/AccountGroup.swift`, `AccountBucket.swift`), import provenance (`Domain/Models/CSVImport/ImportOrigin.swift`), transfer detection (`Transaction+TransferDetection.swift`, `TransferSuggestion.swift`), and per-leg crypto counterparties (`TransactionLeg.counterpartyAddress`). All detection below stays off the LLM hot path, matching the architecture in `Domain/Insights/`. Every monetary idea respects the signed-amount / never-`abs()` / conversion-can-fail rules (`guides/INSTRUMENT_CONVERSION_GUIDE.md`, `guides/CODE_GUIDE.md` §16).

---

## Theme A — Account Groups & Bucket Structure (entirely new substrate)

The grouping feature added `AccountGroup` (id, name, bucket, instrument, position) and `Account.groupId`/`Account.bucket`. None of the 34 catalog items are group- or bucket-aware. These run on `AccountStore` accounts joined to `AccountGroup` records; insights would need `accountId`/`groupId` added to `InsightReferences` (currently only category/earmark ids — `Domain/Insights/Insight.swift:119`).

### A1. Group net-flow concentration
- **Value:** "82% of your spending this month came from accounts in your *Daily Spending* group."
- **Detection:** Group `InsightTransaction.spendMagnitude` by `Account.groupId` (map `accountId → groupId`); report any group whose share of total monthly outflow exceeds a threshold, or whose share moved >N pts vs prior month.
- **Data:** `InsightTransaction.accountId`, `Account.groupId`, `AccountGroup.name`.
- **Difficulty:** Easy. **AI:** no.
- **Caveats:** Drop legs whose conversion failed (count mismatch = "data incomplete"); never `abs()` — use `spendMagnitude`/`incomeMagnitude`.

### A2. Bucket balance drift (current vs investments)
- **Value:** "Your investable assets now exceed your everyday cash for the first time."
- **Detection:** Sum converted balances per `AccountBucket` (`.current` vs `.investments` via `Account.bucket`), compare the ratio against the trailing series; fire on a crossing.
- **Data:** `Account.bucket`, account balances (`AccountStore`/daily balances), `AccountBucket.swift`.
- **Difficulty:** Medium. **AI:** no.
- **Caveats:** A bucket sum is only emitted if *every* contributing per-instrument conversion succeeded (mirror `HistoricalValueSeries`' all-or-nothing rule).

### A3. Group instrument mismatch / FX exposure
- **Value:** "Two accounts in your *Europe* group are denominated in USD, not EUR."
- **Detection:** For each group, compare member `Account.instrument` against `AccountGroup.instrument`; flag groups holding accounts in a different instrument (latent FX exposure the user grouped as one bucket).
- **Data:** `AccountGroup.instrument`, `Account.instrument`, `Account.groupId`.
- **Difficulty:** Easy. **AI:** no.
- **Caveats:** Purely structural, no money math — safe. Treat unknown `groupId` (group record not yet synced) as ungrouped, per the advisory-reference note in `Account.swift:69`.

### A4. Ungrouped-account nudge (organizational, positive-framed)
- **Value:** "You have 3 accounts not in any group — want to file them?"
- **Detection:** Count accounts with `groupId == nil` within a bucket that already has groups; surface as a low-surprise organizational insight.
- **Data:** `Account.groupId`, `AccountGroup` existence per bucket.
- **Difficulty:** Easy. **AI:** no. Actionability fits the "noted/review" tier; keep surprise low so the ranker doesn't over-promote it.

---

## Theme B — Transfer Detection & Inter-Account Flow (new substrate)

`TransferSuggestion` (content-addressed pairs) and `Transaction.isTransferDetectionEligible` / `isMergedTransfer` are post-design-doc. Catalog item 13 forecasts balances but nothing reasons about *transfer hygiene* or money movement *between* the user's own accounts.

### B1. Unreconciled-transfer backlog
- **Value:** "You have 5 likely transfers between your accounts waiting to be merged."
- **Detection:** Count outstanding `TransferSuggestion` records (each is exactly two tx ids, `TransferSuggestion.swift`); summarize total and oldest `suggestedAt`. Optionally rank by the paired amount.
- **Data:** `TransferSuggestion`, the two referenced `Transaction`s.
- **Difficulty:** Easy. **AI:** no.
- **Caveats:** This is data-quality, not spend — `framing: .neutral`, `actionability: .review`. High value because unmerged transfers double-count as fake income+expense and corrupt every *other* spend detector's inputs.

### B2. Phantom-transfer spend contamination warning
- **Value:** "Some recent transfers between your accounts may be inflating your spending totals."
- **Detection:** When unmerged `TransferSuggestion` pairs exist whose legs are typed `.expense`/`.income` (not yet `.transfer`), estimate how much they inflate the period's spend/income magnitude vs the merged-away figure. This is a *meaningful extension* of items 11/16 (deltas / savings rate), explaining anomalies they would otherwise report.
- **Data:** `TransferSuggestion` + the legs' `type`/`amount`, `InsightAggregates`.
- **Difficulty:** Medium. **AI:** no.
- **Caveats:** Sign-sensitive — the two sides have opposite signs; do not collapse with `abs()`. Only an explanatory caveat, not a hard number, unless conversions all succeed.

### B3. Recurring inter-account sweep detection
- **Value:** "You move about $500 to savings around the 1st each month."
- **Detection:** Run the existing `SubscriptionDetector` cadence clustering (`Domain/Insights/Subscriptions/`) over *merged transfer* transactions (`Transaction.isMergedTransfer` / two `.transfer` legs) keyed by the destination `accountId` instead of payee. Surface the recurring savings/sweep habit positively, and warn when a month is missing (analogous to missing-paycheck #30 but for self-transfers).
- **Data:** transfer-typed legs, `accountId`, dates; reuse `SubscriptionDetector`.
- **Difficulty:** Medium. **AI:** no.
- **Caveats:** Excluded from `InsightTransaction.records(...)` today (it drops transfers — `InsightTransaction.swift:93`), so this needs a parallel transfer-leg feed; don't pollute the spend feed.

---

## Theme C — Import Provenance & Data Quality (new substrate)

`ImportOrigin` carries `parserIdentifier`, `importSessionId`, `bankReference`, `rawDescription`, `rawBalance`, `importedAt` (`Domain/Models/CSVImport/ImportOrigin.swift`); merged transfers carry `MergedImportOrigin`. The catalog has zero data-quality insights, yet bad data silently breaks every statistical detector.

### C1. Uncategorized-backlog nudge
- **Value:** "42 imported transactions still need a category — categorize them to sharpen your insights."
- **Detection:** Count transactions where `Transaction.needsReview` is true (`Transaction+TransferDetection.swift:30` — all legs `categoryId == nil`), optionally scoped to recent `importSessionId`. Suppress all category-based insights' confidence when this backlog is large.
- **Data:** `Transaction.legs[].categoryId`, `ImportOrigin.importSessionId`.
- **Difficulty:** Easy. **AI:** no.
- **Caveats:** Pure count; sign-safe. Strong ranker actionability (`.review`).

### C2. Statement-balance reconciliation gap
- **Value:** "Your latest CommBank import's running balance doesn't match Moolah's — something may be missing."
- **Detection:** `ImportOrigin.rawBalance` is the bank's stated running balance per row. Compare the last imported row's `rawBalance` against Moolah's computed account balance at that date (`RunningBalanceResult`/daily balances). A divergence beyond rounding means a missing/duplicate transaction.
- **Data:** `ImportOrigin.rawBalance`, `ImportOrigin.importedAt`, computed running balance.
- **Difficulty:** Medium. **AI:** no.
- **Caveats:** Compare within the *same* instrument only (`rawBalance` is in the account's native currency — no conversion, so don't introduce one). Highest-value data-quality insight: catches the failure mode that breaks everything downstream.

### C3. Possible duplicate import
- **Value:** "These 3 transactions look like duplicates from re-importing the same statement."
- **Detection:** Within or across `importSessionId`s, group by (`bankReference` when present) or (date + `rawAmount` + normalized `rawDescription`); flag exact collisions that weren't deduped. `bankReference` is the bank's stable id and the strongest key.
- **Data:** `ImportOrigin.bankReference`, `rawAmount`, `rawDescription`, `importedAt`.
- **Difficulty:** Medium. **AI:** no.
- **Caveats:** `rawAmount` is signed — match on signed value, not magnitude, so a refund isn't paired with a charge.

### C4. Stale data-source warning
- **Value:** "You haven't imported from Macquarie in 38 days — your spending picture may be incomplete."
- **Detection:** Group `ImportOrigin.importedAt` by `parserIdentifier`; if a previously-regular source has gone quiet beyond its typical cadence, warn. For synced accounts use `WalletSyncState.lastSyncedAt` / `lastError` (`Domain/Models/WalletSyncState.swift`) instead.
- **Data:** `ImportOrigin.parserIdentifier` + `importedAt`; `WalletSyncState.lastSyncedAt`/`lastError`.
- **Difficulty:** Easy. **AI:** no.
- **Caveats:** Don't fire for one-off manual imports; require an established cadence (≥3 sessions).

---

## Theme D — Crypto / Multi-Instrument Nuances (under-exploited substrate)

Items 25–27 cover concentration, performers, and harvest, but operate only on reduced `InstrumentProfitLoss`. The richer crypto substrate — `TransactionLeg.counterpartyAddress`, `Instrument.kind`/`chainId`, `CostBasisLot`, `CapitalGainEvent.holdingDays`, `CryptoPriceCache` staleness — is untouched.

### D1. Gas/network-fee leakage
- **Value:** "You spent ~$210 in network fees across 30 on-chain transactions this year."
- **Detection:** Crypto transactions carry cross-instrument `.expense` fee legs (the gas leg — see `Transaction+TransferDetection.swift:16-19`). Sum converted fee-leg magnitudes per chain. This is a crypto-specific extension of fee-spend (#22), which only matches fiat fee *categories*.
- **Data:** fee legs (`.expense` leg in a different instrument from the value leg), `Instrument.chainId`.
- **Difficulty:** Medium. **AI:** no.
- **Caveats:** Fee legs are in the chain's gas token; convert per-date or report in native token if conversion fails (don't drop silently — note incompleteness).

### D2. Recurring crypto counterparty
- **Value:** "You've sent ETH to the same address 6 times — looks like a recurring payment."
- **Detection:** Cluster crypto legs by `TransactionLeg.counterpartyAddress` (lowercased on-chain address) with the subscription cadence test. The on-chain analog of payee-based subscription detection (#1), which can't see addresses.
- **Data:** `TransactionLeg.counterpartyAddress`, dates, quantity.
- **Difficulty:** Medium. **AI:** no.
- **Caveats:** Address is `nil` for multi-recipient/self-send/gas legs (`TransactionLeg.swift:11-17`) — skip those rather than bucketing them as one phantom counterparty.

### D3. Asset-class allocation mix (fiat vs equities vs crypto)
- **Value:** "Crypto is now 35% of your net worth, up from 12% a year ago."
- **Detection:** Partition holdings by `Instrument.kind` (`.fiatCurrency` / `.stock` / `.cryptoToken`, `Instrument.swift:5`), sum converted value per class, and trend the shares. A meaningful generalization of single-instrument concentration (#25) to *asset class*.
- **Data:** `Instrument.kind`, position values, `ValuedPosition`.
- **Difficulty:** Medium. **AI:** no.
- **Caveats:** All-or-nothing conversion per class; crypto prices are USD-based (`CryptoPriceCache`) so a missing rate to the reporting currency must invalidate the whole class sum.

### D4. Approaching long-term CGT threshold (Australia)
- **Value:** "Holding BHP 22 more days crosses the 12-month mark for the 50% CGT discount."
- **Detection:** For each open `CostBasisLot`, compute days since `acquiredDate`; flag lots at 343–365 days (just under the `holdingDays > 365` long-term boundary defined on `CapitalGainEvent.swift:17`). Purely a *timing* prompt, distinct from the loss-offset harvest (#27).
- **Data:** `CostBasisLot.acquiredDate`/`remainingQuantity`, `CapitalGainEvent.isLongTerm` rule.
- **Difficulty:** Medium. **AI:** no.
- **Caveats:** AU-specific; frame as a prompt to review, never tax advice (same discipline as the existing harvest detector). Only for lots with `remainingQuantity > 0`.

### D5. Stale valuation warning
- **Value:** "Your portfolio value uses prices from 4 days ago — markets have moved."
- **Detection:** Compare `CryptoPriceCache.latestDate` / `StockPriceCache` against `context.now`; if the freshest cached price predates today beyond a tolerance, caveat all investment insights.
- **Data:** `CryptoPriceCache.latestDate`, `StockPriceCache`, `TokenPricingStatus`.
- **Difficulty:** Easy. **AI:** no.
- **Caveats:** Data-quality framing; gates the *confidence* of D3/#25–27 rather than asserting a dollar figure.

---

## Theme E — Earmarks, Income & Cash Flow Extensions (under-exploited)

### E1. Earmark funding shortfall vs upcoming bills
- **Value:** "Your *Holiday* earmark is $300 short of the trip you've scheduled."
- **Detection:** Join `EarmarkSnapshot.balance`/`savingsGoal` against `ScheduledBill`s whose payee/category maps to that earmark; flag when projected need exceeds funded balance before the due date. Combines earmark state (#18–20) with scheduled bills (#13), which the catalog never cross-references.
- **Data:** `EarmarkSnapshot` (`InsightInput.swift:10`), `ScheduledBill` (`InsightInput.swift:117`).
- **Difficulty:** Medium. **AI:** no.
- **Caveats:** Both pre-converted to reporting currency by the wiring layer; if either is `nil` (unknown), skip.

### E2. Pay-rise / pay-cut detection
- **Value:** "Your paycheck went up about 4% starting in April."
- **Detection:** On the detected income stream (#14), apply the subscription *price-hike* technique (#2) to flag a sustained step change in the recurring income amount — the income-side mirror the catalog only applies to expenses.
- **Data:** detected income stream amounts over time (income-typed `InsightTransaction`s).
- **Difficulty:** Easy (once income detection exists). **AI:** no.
- **Caveats:** Require persistence across ≥2 occurrences to distinguish a raise from a one-off bonus; bonus = separate positive (see E3).

### E3. Windfall / one-off income alert
- **Value:** "You received an unusually large deposit of $4,200 — a bonus or refund?"
- **Detection:** MAD-z (the same robust score used in #7) on income magnitudes against the user's typical inflow; a positive-framed counterpart to the large-*transaction* anomaly, which today focuses on expenses.
- **Data:** income-typed `InsightTransaction.incomeMagnitude`.
- **Difficulty:** Easy. **AI:** no.
- **Caveats:** Use `incomeMagnitude` (already clamps outflows to 0); never `abs()` an expense into fake income.

### E4. Weekend vs weekday spend split
- **Value:** "You spend 2.4× more on weekends than weekdays."
- **Detection:** Bucket `spendMagnitude` by weekday/weekend via `context.calendar`; report the ratio when stable. A distinct framing from the day-of-week *spike* in #9 (which finds one-day anomalies, not the habitual split).
- **Data:** `InsightTransaction.date`, `InsightContext.calendar`.
- **Difficulty:** Easy. **AI:** no.

### E5. First-of-period burn-rate front-loading
- **Value:** "You spend 60% of your monthly budget in the first 10 days."
- **Detection:** Within each financial month (`FinancialMonth.key`, `context.financialMonthEnd`), compute the cumulative-spend curve and flag heavy front-loading — a leading indicator for the end-of-month cash crunch that #13/#15 only catch once the balance is already low.
- **Data:** `InsightTransaction.date`/`spendMagnitude`, `InsightContext.financialMonthEnd`.
- **Difficulty:** Medium. **AI:** no.

---

## Theme F — Merchant & Category Behavior (extensions)

### F1. Lapsed-merchant / "you used to spend here"
- **Value:** "You haven't shopped at Spotify-adjacent merchants in 3 months — did you cancel?"
- **Detection:** Set difference the *opposite* direction from new-merchant (#8): merchants present in prior history but absent recently, weighted by their former spend. Stronger cancellation signal than the cadence-lengthening proxy in #4.
- **Data:** `InsightTransaction.normalizedPayee`, dates.
- **Difficulty:** Easy. **AI:** no. Marked as a meaningful extension of #4/#8.

### F2. Category-budget-less spending spotlight
- **Value:** "Your biggest spend category, *Dining*, has no budget set."
- **Detection:** Rank categories by trailing spend; cross-reference against `EarmarkBudgetItem.categoryId` (`Domain/Models/Earmark.swift:3`) to find the largest *un-budgeted* category. Actionable nudge bridging spend analysis and the budgeting feature.
- **Data:** `InsightTransaction.categoryId`, `EarmarkBudgetItem.categoryId`.
- **Difficulty:** Easy. **AI:** no.

### F3. Round-number / split-bill recurring pattern
- **Value:** "A recurring $50.00 round-number expense to *Jane* looks like a shared cost."
- **Detection:** Within subscription clusters, flag streams whose amount is an exact round number and category is uncategorized/personal — a heuristic for informal recurring reimbursements. Low priority; nice-to-have.
- **Data:** subscription clusters + `InsightTransaction.amount`.
- **Difficulty:** Easy. **AI:** no.

---

## Top 5 recommended next (ranked by value ÷ effort)

1. **C1 Uncategorized-backlog nudge** — trivial count, but it both drives action *and* lets the engine down-weight category insights when data is dirty. Highest leverage per line of code. (`Transaction.needsReview`.)
2. **B1 Unreconciled-transfer backlog** — Easy, and unmerged transfers actively poison spend/income/savings-rate detectors. Protecting the inputs is worth more than another spend metric. (`TransferSuggestion`.)
3. **C2 Statement-balance reconciliation gap** — uniquely catches missing/duplicate transactions via `ImportOrigin.rawBalance`; no other signal can. Medium effort, high trust payoff.
4. **A1 Group net-flow concentration** — first insight that makes the new account-groups feature feel intelligent; Easy once `groupId` is threaded into `InsightReferences`.
5. **D1 Gas-fee leakage** — concrete, surprising dollar figure for crypto users that the fiat-only fee detector (#22) structurally cannot produce. Reuses the existing cross-instrument fee-leg shape.

**Cross-cutting prerequisite:** add a `groupId` to `InsightReferences` (`Domain/Insights/Insight.swift` — `accountIds`/`instrumentIds`/`transactionIds` already exist) and a parallel transfer-leg / income-stream feed alongside `InsightTransaction.records(...)` (which intentionally drops transfers — `Domain/Insights/InsightTransaction.swift`). Themes B and D depend on it.
