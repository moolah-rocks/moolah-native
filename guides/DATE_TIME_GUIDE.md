# Date & Time Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)

---

## 1. Why `Date` Is an Instant, Not a Calendar Value

A Foundation `Date` is **a single point on the timeline** — a count of seconds
since 2001-01-01 00:00:00 UTC. It carries no calendar, no time zone, and no
notion of "month" or "day". Apple's own documentation is explicit: a `Date`
"represents a specific point in time independent of any calendar or time zone".
To turn that instant into year/month/day you must apply a `Calendar`, and the
calendar's `timeZone` decides which civil day the instant falls on.

This codebase has **two fundamentally different kinds of date value**, and the
correct handling is *opposite* for each:

- A **timezoneless calendar-unit value** — "April 2026", "2026-06-05", a
  financial-month bucket key, a chart x-position. Its identity is a *named
  calendar unit*, not an instant. It must read the same in every time zone.
- A **local, now-relative or user-facing value** — "today for this user",
  "six months ago", "what year is it right now", a localized month name. Its
  identity is *deliberately* tied to the user's wall clock and locale.

Storing a timezoneless value in a `Date` forces a zone choice (usually midnight
in *some* zone). Reading it back with a *different* calendar/zone shifts the
components and corrupts the value. The classic bug:

> `"202604"` → UTC-midnight `2026-04-01` → read with `Calendar.current` in
> UTC−4 → `2026-03-31` local → `.month` reports **3**, not 4. The April bucket
> silently became March.

The round-trip is only safe when **both** the write and the read pin the **same
fixed zone**. That fixed zone, in this codebase, is UTC — exposed through one
canonical seam.

The trap is easy to miss because `print(date)` renders in the *local* zone,
masking that the value carries no zone of its own.

---

## 2. The Canonical Seam

**Key types:**

- `Shared/Extensions/Calendar+UTC.swift` —
  - `TimeZone.utc`: the UTC time zone, resolved once (non-optional, no
    force-unwrap).
  - `Calendar.utc`: a Gregorian calendar pinned to `TimeZone.utc` **and**
    `Locale(identifier: "en_US_POSIX")`. This is *the* seam to route every
    timezoneless parse / format / component-read through. It is a `Sendable`
    value type allocated once, so it carries no concurrency caveats.
- `Shared/FinancialMonth.swift` —
  - `FinancialMonth.key(for:monthEnd:)`: instant → `YYYYMM` bucket key, anchored
    to `Calendar.utc`, honouring the user's `monthEnd` cut-off.
  - `FinancialMonth.date(forKey:)`: `YYYYMM` label → first day of the month at
    **noon UTC** — a zone-invariant *positioning token* (see §4).
- `Domain/Insights/InsightContext.swift` — `defaultCalendar`, a UTC Gregorian
  calendar injected into every detector so bucketing matches the backend's
  UTC-midnight `DATE(...)` columns.

**When to use each:**

| Need | Use |
|------|-----|
| Derive the financial-month bucket for a transaction instant | `FinancialMonth.key(for:monthEnd:)` |
| Turn a `YYYYMM` label into a chart x-position or sort key | `FinancialMonth.date(forKey:)` |
| Parse / format / read components of any other timezoneless value | `Calendar.utc` |
| Bucket day/month inside an insight detector | `InsightContext.calendar` (defaults to `defaultCalendar`) |
| Anything whose identity is "now for this user" | `Calendar.current` / `Date()` — see §3 |

A `DateFormatter` used in a **parse or logic** path must set
`locale = Locale(identifier: "en_US_POSIX")` so a device configured with a
non-Gregorian calendar, a different `firstWeekday`, or localized symbols cannot
change how a label parses. `Calendar.utc` already pins this; a standalone
`DateFormatter` must do it explicitly.

---

## 3. The Decision Rule: Timezoneless vs. Local

Apply this single test to every date value you produce, parse, key, compare, or
store:

> **Does this value's identity change if the user flies to another time zone?**
> **If NO → timezoneless: pin UTC** (`Calendar.utc` / `FinancialMonth`).
> **If YES → local: `Calendar.current` / `Date()` is correct and intended.**

### Timezoneless — pin UTC (`Calendar.current` here is a BUG)

The value names a calendar unit; it must be identical in Los Angeles, Brisbane,
and Kiritimati.

- A financial-month bucket key (`ExpenseBreakdown.month`, `MonthlyIncomeExpense.month`).
- A chart x-position derived from a month label (`ExpenseBreakdown.monthDate`,
  `CategorySpendSeries.monthDate`, `CategoryOverTimePoint.monthDate`).
- A `YYYY-MM-DD` day key used as a cache key.
- Any value persisted or transmitted and later read back as a named month/day.

The three producers in this codebase all route through the seam:

- `Domain/Models/ExpenseBreakdown.swift` — `monthDate` → `FinancialMonth.date(forKey:)`.
- `Domain/Insights/CategorySpendSeries.swift` — `monthDate` → `FinancialMonth.date(forKey:)`.
- `Features/Analysis/AnalysisStore.swift` — `CategoryOverTimePoint.monthDate`, produced by
  the private `parseMonth(_:)` helper → `FinancialMonth.date(forKey:)`. The
  zone-invariance obligation attaches to the charted `monthDate` token, not to
  the helper; test it through the public `buildCategoriesOverTime(from:categories:)`.

### Local — `Calendar.current` / `Date()` is correct (do NOT "fix" these)

The value's identity *is* the user's current wall clock or locale. Pinning UTC
here would be the bug. These are deliberately local and must be left alone:

- **`TimePeriod.startDate`** (`Domain/Models/TimePeriod.swift`) — "n months ago
  from now" for an investment chart cutoff. `Calendar.current.date(byAdding:
  .month, value: -n, to: Date())` is exactly right: the user wants the last six
  months *as they experience them*.
- **`GetMonthlySummaryIntent`** (`Automation/Intents/GetMonthlySummaryIntent.swift`)
  — defaults the year to `Calendar.current.component(.year, from: Date())`
  ("this year" for the user) and renders the month name with a localized `MMMM`
  `DateFormatter`. Both are user-facing display, not logic keys.
- **`cappedToYesterday`** (`Shared/PriceCacheCap.swift`) — its `timeZone`
  parameter **defaults to `.current` in production on purpose**. An AEDT user
  opening the app at 7am Tuesday must see Monday's ASX close; a UTC-only cap
  would still be on Sunday at that moment and leave prices a day behind every
  morning. Tests pin `timeZone: UTC` for a deterministic `YYYY-MM-DD` label, but
  production must stay local. (Note it *also* re-anchors the result to UTC noon
  so the cache *key* is zone-stable — a hybrid; see §4.)
- **"Is this transaction today?"** and similar now-relative checks — comparing
  against the user's local civil day is the intended semantics.

The `monthEnd` cut-off itself is local: `AnalysisStore` initialises it from
`Calendar.current.component(.day, from: Date())` because it mirrors the user's
"today" boundary. Once chosen, it is fed into `FinancialMonth.key(for:monthEnd:)`,
which does its bucketing in UTC. The *boundary day* is local; the *bucketing
arithmetic* is timezoneless. Keep that split.

---

## 4. Noon-UTC Anchoring for Positioning Tokens

`FinancialMonth.date(forKey:)` returns the first day of the month at **noon
UTC**, not midnight. This is deliberate.

A positioning token exists only so a month bucket can be placed on a date axis
or ordered — it is **not** a timeline instant with meaning of its own. Noon
anchoring buys a **±12-hour margin**: even if a *downstream* read does not pin
UTC — a SwiftUI Charts axis that formats with `Calendar.current`, or a stray
`Calendar.current` somewhere in a view — the token still reports the same
calendar month in every real-world zone from **UTC−12 to UTC+14**. Midnight-UTC
would be correct only if every downstream read also pinned UTC; noon-UTC is
defense-in-depth for the reads you don't control.

UTC observes no DST, so day arithmetic on `Calendar.utc` is unambiguous — the
noon offset is purely to survive a non-UTC *read*, not to dodge a DST seam.

**Caveat — never compare a noon-UTC token for equality against a midnight
instant.** The backend's `DATE(...)` balance columns are UTC **midnight**. A
positioning token from `FinancialMonth.date(forKey:)` is noon UTC and will
*never* be `==` a midnight `DailyBalance.date`, even for the same calendar day.
Positioning tokens are for placement and ordering only:

```swift
// WRONG: a noon-UTC token never equals a midnight DATE() instant
if breakdown.monthDate == dailyBalance.date { … }   // always false

// CORRECT: compare the calendar units, or order by the token
let sameMonth = Calendar.utc.isDate(
  breakdown.monthDate!, equalTo: dailyBalance.date, toGranularity: .month)
```

`cappedToYesterday` applies the same noon-UTC re-anchoring to its *result* so
the shared `ISO8601DateFormatter` (UTC) renders the same `YYYY-MM-DD` cache-key
label the user would call "yesterday", while the *fetch upper bound* still sits
past local-morning market closes.

---

## 5. Anti-Patterns & Red Flags

Flag any of these in code that **produces, parses, persists, keys, or compares**
a calendar-unit value. Each WRONG/RIGHT pair uses this codebase's real symbols.

### `Calendar.current` to build or read a timezoneless value

```swift
// WRONG: reads the bucket label in the device's local zone
var c = DateComponents(); c.year = year; c.month = month; c.day = 1
return Calendar.current.date(from: c)            // drifts to prior month in UTC−n

// RIGHT: route through the seam (this is what FinancialMonth.date(forKey:) does)
let label = String(format: "%04d%02d", year, month)     // "202604"
return FinancialMonth.date(forKey: label)               // noon-UTC, zone-invariant
```

### `Calendar(identifier:)` without setting `.timeZone`

```swift
// WRONG: a bare Gregorian calendar defaults to the system zone
let cal = Calendar(identifier: .gregorian)
let month = cal.component(.month, from: monthDate)   // zone-dependent

// RIGHT: use the canonical UTC calendar
let month = Calendar.utc.component(.month, from: monthDate)
```

### `DateFormatter` in a parse/logic path without `en_US_POSIX`

```swift
// WRONG: localized parsing — fragile on non-en, non-Gregorian devices
let f = DateFormatter(); f.dateFormat = "yyyyMM"

// RIGHT: pin the locale (and the zone, if parsing to an instant)
let f = DateFormatter()
f.locale = Locale(identifier: "en_US_POSIX")
f.timeZone = .utc
f.dateFormat = "yyyyMM"
```

### Bare `Date()` componentized for "today"/this-month inside testable logic

```swift
// WRONG (in a detector): non-deterministic, reads ambient wall clock
let nowMonth = Calendar.current.component(.month, from: Date())

// RIGHT: inject `now` and a fixed calendar (InsightContext does exactly this)
let nowMonth = context.calendar.component(.month, from: context.now)
```

### `TimeZone.current` in a timezoneless parse/format path

```swift
// WRONG: a floating value must not follow the device zone
formatter.timeZone = .current

// RIGHT
formatter.timeZone = .utc
```

### Other red flags (from the research checklist)

- `Calendar.autoupdatingCurrent` building/reading a calendar-unit value — as
  wrong as `.current`.
- `startOfDay(for:)` on a calendar whose `timeZone` is not pinned.
- Local-midnight day/month arithmetic assumed to be DST-safe (use `Calendar.utc`,
  which has no DST, for timezoneless arithmetic).
- A parse and a read using *different* calendars/zones — the round-trip is not
  zone-symmetric.
- `firstWeekday` or localized month symbols used in **logic** (keying, sorting,
  comparison) rather than display.

---

## 6. Testing

The mandated approach is **in-process multi-zone injection**:
`MoolahTests/Shared/TimezonelessDateTests.swift` injects a `Calendar` per
`TimeZone` and asserts the produced value reads as the same month/day in every
zone. It runs in the normal single CI pass at ~zero cost and does **not** depend
on the ambient process `TZ`.

```swift
private static let zones: [String] = [
  "America/Los_Angeles",  // UTC−8/−7 — drifts a midnight-UTC instant to prior day
  "UTC",
  "Australia/Brisbane",   // UTC+10, no DST
  "Pacific/Kiritimati",   // UTC+14, the extreme positive case
]

for zone in Self.zones {
  let components = try calendar(zone).dateComponents([.year, .month], from: monthDate)
  #expect(components.year == 2026, "year drifted in \(zone)")
  #expect(components.month == 4, "month drifted in \(zone)")
}
```

**Rules** (these also live in `guides/TEST_GUIDE.md`):

- Pick zones on **both** sides of UTC, including an extreme negative
  (Los Angeles) and an extreme positive (Kiritimati), plus a no-DST zone
  (Brisbane). The strongly-negative zone is the one that exposes the
  midnight-UTC drift bug.
- **Inject** the calendar/zone (and `now`) — never read the ambient `TZ` inside
  the assertion. `TZ` env is sticky on the Simulator and untrustworthy as the
  primary mechanism; in-process injection is deterministic in a single run.
- **Do not** assert a `Calendar.current` component — that re-encodes the bug
  you're testing for.
- **Do not** assert a literal locale symbol (e.g. `"$"`). It is locale-fragile
  (`AUD` is `$` on en-AU but `A$` on a CI runner). Assert the zone-invariant
  integer components or the raw value instead.
- New timezoneless producers must add a zone-invariance case to
  `TimezonelessDateTests` (or a sibling suite following the same pattern).

For now-relative *local* values, inject the reference `now` (as `InsightContext`
does) so the test is deterministic; you are then asserting the *local*
interpretation is correct, which is a different test from zone-invariance.

---

## 7. Locale Safety

Any `DateFormatter`, `DateComponents`-driven format, or calendar used for
**parsing or logic** must use `Locale(identifier: "en_US_POSIX")`:

- `Calendar.utc` pins it already.
- A standalone `DateFormatter` in a parse/key path must set it explicitly
  (see §5).
- `ISO8601DateFormatter` is locale-independent for date-only output but its
  consumers must still read back through a UTC-pinned calendar.

The **only** place a localized locale is correct is **display** — e.g.
`GetMonthlySummaryIntent.monthName(_:)` rendering `MMMM` for the user. Display
strings are never used as keys, sort orders, or comparison inputs.

---

## 8. Reviewer Checklist

*(The `datetime-review` agent keys off this section.)*

For any change that produces, parses, persists, keys, or compares a date value:

- [ ] Every value is classified by the §3 decision test (does its identity
      change across time zones?), and the choice of `Calendar.utc` vs.
      `Calendar.current` follows from that.
- [ ] Timezoneless values (month keys, day keys, chart x-positions) are produced
      and read **only** through `Calendar.utc` or `FinancialMonth` — no
      `Calendar.current` / `.autoupdatingCurrent` in their path.
- [ ] No `Calendar(identifier:)` is used without pinning `.timeZone` (and,
      for parse paths, `.locale = en_US_POSIX`).
- [ ] No `DateFormatter` / `ISO8601DateFormatter` in a parse or logic path lacks
      an explicit `timeZone`, and no `DateFormatter` parse path lacks
      `en_US_POSIX`.
- [ ] A timezoneless value is parsed and read with the **same** fixed calendar
      (the round-trip is zone-symmetric).
- [ ] Positioning tokens are anchored at **noon UTC** (via
      `FinancialMonth.date(forKey:)`), and no code compares a noon-UTC token for
      `==` against a midnight `DATE(...)` instant.
- [ ] Deliberately-local values (`TimePeriod.startDate`,
      `GetMonthlySummaryIntent`'s year default and `MMMM` name,
      `cappedToYesterday`'s production `timeZone: .current`, "is it today?"
      checks) are **not** "fixed" to UTC.
- [ ] `Date()` used to derive "today"/this-month inside testable logic is
      injected instead (e.g. `InsightContext.now`), not read ambiently.
- [ ] `firstWeekday` and localized symbols appear only in **display**, never in
      keying / sorting / comparison logic.
- [ ] A new timezoneless producer adds an in-process multi-zone invariance test
      (Los Angeles / UTC / Brisbane / Kiritimati) following
      `TimezonelessDateTests`.
- [ ] Tests assert zone-invariant integer components, not a `Calendar.current`
      component or a literal locale symbol.

---

## 9. Further Reading

- Apple — `Date` reference: https://developer.apple.com/documentation/foundation/date
- Dave DeLong, "Explanation of Date object and timezones, please" (Swift Forums):
  https://forums.swift.org/t/explanation-of-date-object-and-timezones-please/53220
- swift-foundation — SF-0009 `Calendar.RecurrenceRule` (RFC-5545 enumeration,
  matchingPolicy / repeatedTimePolicy for nonexistent/ambiguous DST times).
- Use Your Loaf — "Fun With Date Calculations" (midnight vs. noon anchoring).
- Swift by Sundell — "Time traveling in unit tests" (injecting a fixed
  calendar / current date).
- Point-Free `swift-dependencies` — `\.calendar` / `\.timeZone` / `\.date` /
  `\.clock` injection.
- NSHipster — `DateComponents` / `NSCalendar` additions.
- Sarunw, Advanced Swift — `ISO8601DateFormatter` date-only and `en_US_POSIX`
  parsing.
- Floating-date value types: `raymondjavaxx/CalendarDate`,
  `ralfebert/CalendarDate`.

---

## Version History

- **1.0** (2026-06-05): Initial guide. Codifies the timezoneless-vs-local
  distinction, the `Calendar.utc` / `FinancialMonth` seam, the noon-UTC
  positioning-token convention, the in-process multi-zone test pattern
  (`TimezonelessDateTests`), and the reviewer checklist the `datetime-review`
  agent consumes. Consolidates the rationale previously living in
  `Calendar+UTC.swift`, `FinancialMonth.swift`, `InsightContext.swift`, and
  `PriceCacheCap.swift`.
