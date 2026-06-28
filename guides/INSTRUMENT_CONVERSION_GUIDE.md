# Instrument Conversion Guide

**Version:** 1.2
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)

---

## 1. Architecture Overview

Moolah is multi-instrument by construction: accounts, legs, earmarks, and positions are all expressed in an `Instrument` (fiat currency, stock, or crypto token), and a profile has a single `profileInstrument` that user-facing totals roll up into.

**Key types:**

- `Domain/Models/InstrumentAmount.swift` — `InstrumentAmount { quantity: Decimal, instrument: Instrument }`. All arithmetic (`+`, `-`, `+=`, `-=`) has a `precondition` that the two operands share an instrument and **traps** on mismatch. `Comparable` (`<`) compares raw `quantity` only and does NOT guard instrument equality.
- `Domain/Services/InstrumentConversionService.swift` — the only sanctioned conversion API:
  - `convert(_ quantity: Decimal, from: Instrument, to: Instrument, on: Date) async throws -> Decimal`
  - `convertAmount(_ amount: InstrumentAmount, to: Instrument, on: Date) async throws -> InstrumentAmount`
- `Shared/PositionBook.swift` — the canonical aggregation primitive. Per-instrument positions are kept as raw `Decimal` keyed by `Instrument` and only converted at read time in `dailyBalance(on:…)`.
- Production conversion implementations: `FiatConversionService` (Frankfurter API), `FullConversionService` (fiat + stock + crypto).
- Test doubles: `FixedConversionService` (ignores date), `DateBasedFixedConversionService` (honours date).

**Hard constraint:** Frankfurter does NOT return future exchange rates. For anything at or after today, the "latest available" rate — requested with `Date()` — is the documented best estimate.

**Key Sources:**
- `plans/ROADMAP.md` Phase 6 — multi-currency intent.
- `plans/2026-04-17-forecast-currency-conversion-plan.md` — forecast date rule and the crash this codifies.
- `plans/completed/2026-04-12-multi-instrument-design.md` — foundational design.

---

## 2. Core Principles

1. **Arithmetic crashes; conversion throws.** A mismatched `+`/`-` traps the process. A failed conversion throws and is recoverable. Convert *before* summing across instruments.
2. **Aggregate per-instrument, then convert.** Keep per-instrument positions as raw `Decimal` keyed by `Instrument`. Convert to a target instrument at the edge (read time), never in the middle of accumulation.
3. **The conversion date is a semantic choice.** It must reflect *when the value is denominated*, not when the code runs. Historic = snapshot date; current/future = `Date()`.
4. **Single-instrument fast path.** When a position's instrument equals the target, skip the conversion service entirely and add the raw quantity. Do not route same-instrument data through an async call.

---

## 3. Rules

### Rule 1: Never add `InstrumentAmount`s that may differ in instrument

`InstrumentAmount.+/-/+=/-=` `precondition` both sides share an instrument. A mismatch is a crash, not an error. If inputs can come from different instruments, convert first.

```swift
// WRONG: legs may be in different instruments on a multi-currency profile
let total = transaction.legs
  .map(\.amount)
  .reduce(.zero(instrument: profile.instrument)) { $0 + $1 }  // traps

// CORRECT: pre-convert each leg to the target instrument
var convertedLegs: [InstrumentAmount] = []
for leg in transaction.legs {
  if leg.instrument == profile.instrument {
    convertedLegs.append(leg.amount)
  } else {
    convertedLegs.append(
      try await conversionService.convertAmount(
        leg.amount, to: profile.instrument, on: transaction.date))
  }
}
let total = convertedLegs.reduce(.zero(instrument: profile.instrument)) { $0 + $1 }
```

### Rule 2: Reduce seeds must match every element

`reduce(InstrumentAmount.zero(instrument: X)) { $0 + $1 }` is only correct when *every* element of the sequence is in `X`. Reduce over a collection produced by an explicit conversion step, not over raw domain data.

### Rule 3: `max`, `min`, and `<` across instruments are nonsense

`InstrumentAmount: Comparable` compares raw `quantity`. It does NOT guarantee the instruments match, and it does NOT trap. 10 USD < 1 BHP.AX compares `10 < 1` and returns `false`. Only compare amounts that are provably in the same instrument. Convert first if needed.

### Rule 4: Clamp after conversion, not before

Per-earmark sums are clamped to `>= 0` *after* conversion in `PositionBook.dailyBalance`. Applying `max(…, .zero(instrument: X))` to a running sum whose instrument may disagree with `X` is both a crash risk and semantically wrong.

### Rule 5: Historic data uses the snapshot date

Any read whose semantics are "as of this date" must convert on that date. This includes:

- Daily balances (`fetchDailyBalances`, `computeDailyBalances` historic entries).
- Transaction list display amounts (`Transaction.buildWithBalance` uses `transaction.date`).
- Expense breakdowns and income/expense totals (per-transaction conversion).
- Historical reports, tax summaries, capital-gains calculations, and any chart whose x-axis is time.

```swift
// CORRECT: convert each leg at its transaction's date
let converted = try await conversionService.convertAmount(
  leg.amount, to: targetInstrument, on: transaction.date)
```

**Carve-out — transaction-list running balance (issue #530).** A transaction
list's running-balance column is a current-value figure projected backward
through history: each row's running balance must tie out to the live account
balance shown in the sidebar. Using each transaction's own date here would
make the most-recent row disagree with the sidebar whenever a historic rate
differs from today's, and would make every prior row drift independently. The
running-balance pipeline therefore snapshots a single `Date()` per page and
applies it to every leg conversion in that page (see
`Transaction.prefetchRates`). The per-leg display amount on each row is still
historic and uses `transaction.date`; only the running-balance accumulation
uses `Date()`. This is the only sanctioned departure from Rule 5 — do not
generalize it to other historic reads.

### Rule 6: Current-value reads use `Date()`

Reads whose semantics are "what is this worth right now" must convert on today:

- Sidebar totals, net worth, available funds.
- `InvestmentStore.valuatePositions` (current valuation).
- `AccountStore` rollups used by the sidebar and account detail.
- "Current" earmark availability shown to the user.

### Rule 7: Future dates are clamped to today by the conversion service

Frankfurter (and the stock/crypto rate providers) have no future rates. The conversion service (`FiatConversionService.convert` and `FullConversionService.convert`) therefore **clamps any `on: date` greater than `Date()` to today** before looking up a rate, so a future date resolves against the latest available rate rather than throwing.

**Practical consequence for call sites:** forecast and scheduled-transaction code may pass the natural semantic date (`transaction.date`, `scheduledInstance.date`) without pre-clamping. The service guarantees the lookup date is never in the future.

```swift
// Fine — the service clamps the future date to today.
let converted = try await conversionService.convertAmount(
  leg.amount, to: profile.instrument, on: scheduledInstance.date)
```

Callers are still free to pass `Date()` explicitly if that expresses intent more clearly (e.g. "current valuation of a historic position"), but it is not required for correctness. Do not add a separate `isForecast` / `conversionDate` parameter to internal APIs purely to select between the transaction date and today — the service handles it.

See `plans/2026-04-17-forecast-currency-conversion-plan.md` for the original rationale and the issue-#47 commit for the service-level clamp.

### Rule 8: Single-instrument fast path

If `instrument == target`, skip the conversion service and add the raw quantity directly. This keeps single-currency profiles off the network/cache path.

```swift
for (instrument, quantity) in positions {
  if instrument == target {
    total += quantity                                          // fast path
  } else {
    total += try await service.convert(quantity, from: instrument, to: target, on: date)
  }
}
```

### Rule 9: Use the semantic observation date, not wall-clock metadata

Use `transaction.date`, `dailyBalance.date`, `snapshot.date`, or the explicit parameter the function advertises. Do NOT use `createdAt` / `updatedAt` / record metadata timestamps — those reflect *when the user wrote the data*, not *what the data is denominated on*.

### Rule 10: Keep `startOfDay` consistent

The date used to key a balance and the date supplied to the conversion service must both be normalized the same way (usually `Calendar(identifier: .gregorian).startOfDay(for:)`). Mismatches can cross timezone boundaries and return yesterday's rate for today's value.

### Rule 11: Degrade gracefully; never display incorrect or confusing data

Conversion can fail in production — no network, no cached fallback, unsupported pair, missing provider mapping. The system must degrade as gracefully as it can, but it **must never present an incorrect, partial, or mixed-instrument number as if it were the answer the user asked for**.

**Core principle — a total is not required when any of its inputs is unavailable.** A total is a function of its inputs; if any required input can't be computed, the total also can't be computed, and showing *no total* (or an explicit "unavailable" state) is the correct answer, not a problem to work around. Graceful degradation means displaying the unavailable individual value and its dependent totals as unavailable *together*, while independently-scoped sibling individual values keep rendering normally. Filling the gap with a partial sum, a native-instrument fallback, a substituted zero, or a silently-omitted input is strictly worse than showing no value at all.

**Required behaviour when a conversion fails:**
- Mark the failing individual value — the row, position, leg, earmark, or cell whose conversion did not succeed — as *unavailable* (e.g. "—", a retry affordance, or an explicit error state). Never show a stale value, native-instrument fallback, or substituted zero in its place.
- Mark every total that depended on that value as *unavailable* in the same way. Any total that included a failed input is incorrect and must not be rendered as a value. The failing individual value and the totals that consume it surface as unavailable together; never one without the other.
- Keep independently-scoped sibling values and sibling totals rendering normally. A failure on one row / section / account / earmark / report line must not blank other rows whose values and aggregations are fully computable on their own. Scope failure tightly to the specific value that depends on the missing rate and the totals that consume it.
- Log the failure via `os.Logger` so it's diagnosable in production.
- Surface a user-visible error message with a path to retry once the rate source recovers.

**Not allowed — these all show misleading data:**
- Silently summing only the convertible positions and displaying the result as if it were the total. The "convertible portion" of a mixed-instrument total is itself an incorrect number; it is not a valid degradation.
- Displaying the unconverted `InstrumentAmount` in its native instrument in place of the requested total or the failing individual value. Mixing instruments in a single figure confuses users and is not an acceptable fallback.
- Replacing a failed conversion with `0` (or `.zero(instrument:)`) and folding it into the sum, or displaying zero as the individual value.
- `try?`-swallowing a conversion error, producing no log, no error state, and no user indication.
- Aborting the whole view or blanking sibling totals on the first failure when those siblings are independently computable (the pattern behind the "sidebar spinner forever" class of bug).
- Silently dropping the failing individual value from the total while still rendering the total as if it were complete. A total that omits one of its required inputs is a wrong number, not a partial one.
- Hiding the failing individual value while continuing to render a total that depended on it, or vice versa. Both must surface as unavailable together.
- Caching or persisting a partial or fallback total as the authoritative value for the next launch, so the user never sees the real number even after the network recovers.

**Structural guidance:** Catch conversion errors at the scope of the individual value and propagate "unavailable" outward through every total that consumes it. If a per-entity individual value (one account row, one earmark, one report line) cannot be fully computed, mark *that* value unavailable and mark every total that aggregates it as unavailable. Do not expand the blast radius to sibling values or sibling totals, and do not shrink it below the logical total the user is asking about — a total that silently omits one of its inputs is a wrong number, not a partial one.

---

## 4. Canonical Patterns

### Per-instrument accumulation, then convert at read time

`PositionBook` keeps `[UUID: [Instrument: Decimal]]` and converts in `dailyBalance(...)`. New aggregation code should adopt the same shape rather than accumulating `InstrumentAmount` across mixed instruments.

### Pre-convert into a typed carrier

`ConvertedTransactionLeg { leg: TransactionLeg, convertedAmount: InstrumentAmount }` — the type itself carries the guarantee that `convertedAmount.instrument` equals the target. Reducing over `[ConvertedTransactionLeg]` is safe by construction.

### Conversion-service seam

Every call site that needs a rate goes through `InstrumentConversionService`. This keeps the date decision and the fiat/stock/crypto dispatch in one place. Do not call `ExchangeRateService`, `CryptoPriceService`, or `StockPriceService` directly from a feature-level store or view.

### Single-instrument fast path

See Rule 8. Applies to both `convert(_:from:to:on:)` and `convertAmount(_:to:on:)`.

---

## 5. Anti-Patterns

| Anti-Pattern | Why It's Bad | Do This Instead |
|--------------|--------------|-----------------|
| Summing `TransactionLeg.amount` directly across legs | Legs are per-instrument; multi-currency profiles crash | Convert each leg, then sum (Rule 1) |
| `reduce(.zero(instrument: X)) { $0 + $1 }` over raw domain data | Seed instrument doesn't match elements in multi-currency data | Reduce over a pre-converted collection (Rule 2) |
| `max(a, b)` / `a < b` on `InstrumentAmount`s of unknown instrument | Compares raw quantity silently; 10 USD < 1 BHP.AX is false | Convert to a common instrument first (Rule 3) |
| Clamping `max(sum, .zero(instrument: X))` before conversion | Traps when `sum.instrument != X` | Clamp after conversion (Rule 4) |
| Historic reports calling `.convert(..., on: Date())` | Report values drift from the authoritative historic rate | Pass the snapshot/transaction date (Rule 5) |
| Sidebar/net-worth calling `.convert(..., on: someHistoricDate)` | Shows a stale rate as "now" | Pass `Date()` (Rule 6) |
| Threading an `isForecast` / `conversionDate` parameter through internal APIs purely to swap between `tx.date` and `Date()` | The conversion service already clamps future dates to today — no caller needs this branch | Pass `transaction.date` and rely on Rule 7's service-level clamp |
| Routing same-instrument data through the conversion service | Unnecessary async hop and network/cache traffic | Fast-path when `instrument == target` (Rule 8) |
| Using `createdAt` / `updatedAt` as conversion date | Metadata timestamp is not the semantic observation date | Use `transaction.date` / `dailyBalance.date` (Rule 9) |
| Keying balances and converting rates with un-normalized `Date` | Timezone drift — "today's rate" for yesterday's balance | Normalize both with `startOfDay` (Rule 10) |
| Test coverage only via `FixedConversionService` (date-ignoring) | Cannot detect wrong-date regressions | Use `DateBasedFixedConversionService` for date-sensitive tests |
| Constructing `InstrumentAmount(quantity:, instrument:)` with an implicit running-total instrument | Assumption breaks when inputs differ | Keep positions as `[Instrument: Decimal]` until convert time |
| Calling `ExchangeRateService` / `CryptoPriceService` / `StockPriceService` directly from a store or view | Bypasses the `InstrumentConversionService` seam and the fast path | Always go through `InstrumentConversionService` |
| Summing only the convertible positions and displaying the result as the total | The convertible portion of a mixed-instrument total is itself an incorrect number | Mark the affected total unavailable (Rule 11) |
| Displaying the unconverted amount in its native instrument as a fallback | Mixes instruments in a single figure and confuses users | Mark the affected total unavailable (Rule 11) |
| Replacing a failed conversion with `0` / `.zero(instrument:)` in the running sum | A wrong total rendered as authoritative | Mark the affected total unavailable; never substitute zero (Rule 11) |
| Wrapping all totals in one outer `do { ... } catch { total = nil }` | One bad position blanks sibling totals too — sidebar spinner forever | Scope the catch to the individual failing total; keep siblings rendering (Rule 11) |
| Silently dropping the failing input from the sum and rendering the total as if complete | A total that omits one of its inputs is a wrong number, not a partial one | Mark the failing input unavailable and every total that consumes it unavailable together (Rule 11) |
| Hiding the failing individual value while still displaying a total that depended on it (or vice versa) | The remaining display contradicts itself — a number derived from something the user can't see | Surface the failing individual value and its dependent totals as unavailable together (Rule 11) |
| `try?` on a conversion without logging or surfacing an error | Silent failure, invisible in production | Log via `os.Logger` and surface a retryable error to the user (Rule 11) |
| Showing a multi-instrument account/earmark balance as its primary position plus a "mixed currencies" warning badge | Hides real value behind a badge; the row no longer reflects the account's true worth | Convert every position to the account's *own* instrument and sum (Rule 1/2), the way `EarmarkStore.convertedBalances` converts to `earmark.instrument`; degrade per Rule 11 only when a rate is missing |

---

## 6. Review Checklist

### For every change that touches monetary aggregation

- [ ] Every `InstrumentAmount.+/-/+=/-=` operates on operands provably in the same instrument.
- [ ] Every `reduce(.zero(instrument: X))` reduces over a collection whose elements are provably in `X` (ideally a freshly pre-converted array).
- [ ] Every `max` / `min` / `<` on `InstrumentAmount`s compares values provably in the same instrument.
- [ ] Clamps, ceilings, and floors are applied *after* conversion to a known target instrument.
- [ ] Single-instrument fast path is present where the accumulated data could be same-instrument in a common user setup.

### For every change that touches conversion dates

- [ ] Historic reads (daily balances before today, transaction lists, expense/income breakdowns, tax summaries) convert on the snapshot/transaction date.
- [ ] Current-value reads (sidebar, net worth, available funds, investment valuations, account detail) convert on `Date()`.
- [ ] Forecast/scheduled paths may pass `transaction.date` — the conversion service clamps to today automatically (Rule 7). Do not add bespoke `isForecast` plumbing.
- [ ] Date is the semantic observation date (`transaction.date`, `dailyBalance.date`), not wall-clock metadata (`createdAt`, `updatedAt`).
- [ ] Date used to key a bucket matches the date handed to the conversion service (same `startOfDay` normalization).

### For every new conversion call site

- [ ] Goes through `InstrumentConversionService`, not a lower-level price/rate service.
- [ ] Single-instrument fast path present.
- [ ] Test coverage uses `DateBasedFixedConversionService` if date correctness matters.
- [ ] Failure path — a throwing conversion — is surfaced to the user or logged, not `try?`-swallowed.

### For every aggregation that can partially fail

- [ ] The individual value whose conversion failed is itself displayed as unavailable — never as a stale value, native-instrument fallback, substituted zero, or silently dropped from the rendered list.
- [ ] A total whose inputs include a failed conversion is marked unavailable — never summed from the convertible subset and displayed as if complete.
- [ ] The failing individual value and every total that depends on it are marked unavailable together; neither is hidden while the other is rendered as if valid.
- [ ] Unconverted amounts are never displayed in their native instrument as a fallback for a total that was requested in another instrument.
- [ ] Failed conversions are never substituted with `0` in a running sum.
- [ ] Conversion errors are caught at the scope of the individual value, so independently-scoped sibling values and sibling totals (other rows, other accounts, other report lines) keep rendering normally.
- [ ] Failures are logged via `os.Logger` and surfaced to the user with a retry path.
- [ ] Partial / fallback totals are not cached as authoritative values that would hide recovery.

---

## Version History

- **1.2** (2026-04-18): Rule 11 clarified — a total is not required when any of its inputs is unavailable. The failing individual value and every total that depends on it must be rendered as unavailable together; sibling individual values keep rendering. Codifies the symmetry between individual values and totals and rules out silently dropping a failing input from a total. Updates the anti-pattern table and review checklist accordingly. Flagged by issue #78 (`EarmarkStore.convertedTotalBalance` retry loop).
- **1.3** (2026-04-28): Rule 11a removed. The Remote (moolah-server) backend no longer exists; `CloudKitBackend` is the only production backend and is fully multi-instrument. The `supportsComplexTransactions` flag, `requireMatchesProfileInstrument` guard, and all single-instrument UI gating have been deleted.
- **1.1** (2026-04-17): Added Rule 11a — single-instrument backends (Remote, moolah) reject foreign-instrument writes. Superseded by v1.3: Rule 11a removed after Remote backend deletion.
- **1.0** (2026-04-17): Initial guide. Consolidates instrument-safe-arithmetic and conversion-date rules previously spread across `plans/ROADMAP.md`, `plans/2026-04-17-forecast-currency-conversion-plan.md`, and the `PositionBook` / `InstrumentAmount` source files. Adds Rule 11: on conversion failure, mark the affected total unavailable — never display the convertible portion as the total, never display the unconverted amount in its native instrument, and never substitute zero. Independently-scoped sibling totals must keep rendering.
- **1.1** (2026-04-17): Rule 7 moved from a call-site obligation to a service-level guarantee — `FiatConversionService` and `FullConversionService` now clamp any future date to `Date()` before rate lookup, so forecast and scheduled call sites can pass `transaction.date` directly.
