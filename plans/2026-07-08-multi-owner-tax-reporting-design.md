# Multi-owner Tax Reporting - Design Spec

## Problem

Moolah profiles can already track multiple real-world entities in one ledger:
a husband, wife, and family trust. Today tax reporting is effectively
profile-wide. That is not enough when the same profile contains accounts and
categories that belong to different tax owners, or accounts jointly owned by
multiple people.

The feature needs to support:

- Capital gains reports per owner.
- Tax-reportable income per owner.
- Tax-deductible expenses per owner.
- Single-owner profiles that never need to think about ownership.

This design updates the older `plans/2026-04-11-australian-tax-reporting-design.md`
ownership model. That older document names fields such as owner type and tax
category groupings that are intentionally out of scope for this simpler
first pass.

## Goals

1. Introduce profile-scoped tax owners.
2. Keep single-owner profiles frictionless: no owner selectors appear while
   the profile has only one owner.
3. Let accounts and categories optionally name one or more owners.
4. Split amounts evenly when more than one owner is assigned.
5. Let tax reportability be configured independently from ownership.
6. Support owner-aware capital gains, including CGT events for non-fiat
   transfers between differently owned accounts.
7. Keep ownership resolution centralized so Swift and SQL paths agree.

## Non-goals

- Uneven ownership shares. Equal splits are enough for the first version.
- Historical ownership. Changing an account or category owner is treated as
  a correction: reports behave as if the new owner was always the owner.
- Owner ordering, archived owners, trust-specific tax-rate calculation, or
  beneficiary distribution logic.
- Category inheritance for tax reportability or ownership.
- Creating disposal events merely because an investment account owner was
  corrected.
- Lodgeable tax-return generation. Owner kind exists only to distinguish
  individuals from simple family trusts; full trust distribution and
  beneficiary tax calculations are out of scope.

## Domain Model

### TaxOwner

```swift
struct TaxOwner: Identifiable, Codable, Sendable, Hashable {
  let id: UUID
  var name: String
  var kind: TaxOwnerKind
}

enum TaxOwnerKind: String, Codable, Sendable, CaseIterable {
  case individual
  case trust
}
```

Do not add `position` or `isArchived` in v1. They can be additive later if
product behavior requires them.

`kind` is included only because the target use case is individuals plus simple
family trusts. It should not open the door to company accounting or full
tax-return calculation in v1.

### Profile

```swift
struct Profile {
  var defaultTaxOwnerId: UUID
}
```

The default belongs on the profile, like `currencyCode`. A new profile should
create one default tax owner automatically, probably named from the profile
label or a neutral default such as "Owner".

### Account

```swift
struct Account {
  var taxOwnerIds: [UUID]?
}
```

`nil` or an empty array means "use the profile default tax owner". Multiple
IDs mean equal ownership. The app should preserve a deterministic ID order for
stable display and repeatable SQL results, but the order has no tax meaning.
The model and first UI should support any number of selected owners, not only
one or two, even though most real profiles will use one owner or a simple joint
pair.

### Category

```swift
struct Category {
  var isTaxReportable: Bool
  var taxOwnerIds: [UUID]?
}
```

`isTaxReportable` defaults to `false` for new categories. A single-owner
household should be able to use tax reportability without enabling any owner
feature, but tax reports should include only categories the user has
deliberately marked reportable. The transaction leg type decides the report
section:

| Category reportable? | Leg type | Tax report output |
|---|---|---|
| true | `.income` | taxable income |
| true | `.expense` | deductible expense |
| true | other types | excluded from income/deduction sections |
| false | any | excluded from income/deduction sections |

Category ownership is optional and overrides account ownership only when set.
This supports cases such as a joint bank account paying an expense that belongs
entirely to the trust.

`isTaxReportable` is a user assertion that the category belongs in tax
reporting. Moolah can then produce reliable arithmetic for the supported simple
cases, but it is not deciding whether a particular real-world expense is
legally deductible or whether a receipt is assessable in every circumstance.

There is no parent category inheritance in v1. A child category only uses the
fields on that exact category.

## Ownership Resolution

Every owner-aware report must go through one resolver. No report should
hand-roll "use category else account else profile default" logic.

Resolution order:

1. Category owners, when resolving an income or expense leg and the category
   has owner IDs.
2. Account owners, when the leg has an account and the account has owner IDs.
3. Profile default owner.

The result is always one or more equal fractions:

```swift
struct TaxOwnerAllocation: Sendable, Hashable {
  let ownerId: UUID
  let fraction: Decimal
}
```

For two owner IDs, the resolver returns `0.5` and `0.5`. For three, it returns
`1 / 3` each. This is the only place equal split math should live.

Future uneven shares can be added by extending the persisted allocation shape
with a nullable `share` column. The resolver can prefer explicit shares when
present and keep equal shares as the fallback.

### Swift API

Working shape:

```swift
struct TaxOwnershipResolver {
  let profileDefaultOwnerId: UUID
  let accountsById: [UUID: Account]
  let categoriesById: [UUID: Category]

  func allocationsForLeg(_ leg: TransactionLeg) -> [TaxOwnerAllocation]
  func allocationsForAccount(_ accountId: UUID?) -> [TaxOwnerAllocation]
}
```

`allocationsForLeg` is used by ordinary income and deduction reports.
`allocationsForAccount` is used by capital gains, where ownership is based on
the account holding the disposed asset.

### SQL API

Some report paths should stay SQL-first for performance. The resolver needs a
SQL equivalent so Swift and SQL agree. The simplest first version is to keep
shared SQL fragments in one place, for example:

```swift
enum TaxOwnershipSQL {
  static let effectiveLegOwnerRows: SQL = ...
  static let effectiveAccountOwnerRows: SQL = ...
}
```

The SQL should emit one row per effective owner with:

```text
source_row_id
owner_id
owner_count
allocation_numerator
allocation_denominator
```

For v1, `allocation_numerator` is always `1` and
`allocation_denominator` is the number of owners. Aggregations can multiply
the signed scaled quantity by `allocation_numerator` and divide by
`allocation_denominator`, or aggregate whole-leg quantities first and split in
Swift after conversion when Decimal precision is easier to preserve.

Do not duplicate the fallback expression across repositories. If SQLite views
or CTE helpers make the queries clearer, use them; otherwise keep the SQL
literal builder centralized and plan-pinned in tests.

## Income And Deduction Reports

Income and deduction reports are category-gated and owner-allocated.

Rules:

1. Scheduled templates are excluded, matching existing analysis queries.
2. Only categories with `isTaxReportable == true` are included.
3. `.income` legs contribute to taxable income.
4. `.expense` legs contribute to deductible expenses.
5. Other leg types do not contribute to these sections.
6. Amounts convert to `Profile.instrument` on the leg date, following
   `guides/INSTRUMENT_CONVERSION_GUIDE.md`.
7. Rule 11 unavailable-data flags remain mandatory: never show a complete
   tax total if a dependent conversion failed.

The report model should keep owner separation explicit:

```swift
struct OwnerIncomeDeductionReport: Sendable {
  let ownerId: UUID
  let taxableIncomeByCategory: [UUID: InstrumentAmount]
  let deductibleExpenseByCategory: [UUID: InstrumentAmount]
  var incomeHasUnavailableData: Bool
  var expenseHasUnavailableData: Bool
}
```

Uncategorised legs have no category, so they cannot be tax-reportable via
category settings. For v1 they should be excluded from tax income/deduction
reports, even though the non-tax Reports screen may still show uncategorised
income and expense totals. This keeps the rule "tax reportable comes from the
category" honest.

The existing `ReportingStore.loadCategoryBalances` remains the general
income/expense analysis path. Add a separate tax-report load path rather than
threading tax behavior through the general category balance properties.

## Owner-aware Cost Basis

Capital gains need owner context before FIFO, not only after report projection.
The existing cost-basis pass is account-aware. Tax reporting needs an
owner-aware pass that expands asset events by effective owner allocation and
tracks lots by owner as well as account/instrument.

Working key:

```swift
struct OwnerTaxLotKey: Hashable, Sendable {
  let ownerId: UUID
  let accountId: UUID?
  let instrument: Instrument
}
```

For account-level holdings display, owner-level lots can be summed back to the
account/instrument level. For owner tax reports, each owner gets their own FIFO
history. This is what makes arbitrary owner counts and partially overlapping
transfers reliable.

The event builder needs ownership resolution in its input, for example:

```swift
CostBasisEventBuilder.events(
  sourceTransactionId: transaction.id,
  legs: transaction.legs,
  on: transaction.date,
  trackedAccountIds: trackedAccountIds,
  ownershipResolver: taxOwnershipResolver,
  referenceCurrency: profileInstrument,
  conversionService: conversionService)
```

Tests are required for:

- Same-owner non-fiat transfer: owner lots move, no CGT event.
- Different-owner non-fiat transfer: source owner disposes, destination owner
  acquires.
- Partially overlapping owner sets: overlapping fraction moves; changed
  fraction disposes/acquires.
- Custom trade where disposed/acquired asset legs are assigned to accounts with
  different owners.
- Joint account sale: each owner receives an equal share of quantity, cost
  base, proceeds, gain/loss, and holding-period classification.

## Capital Gains

Capital gains are owner-owned. The owner comes from the account assigned to
the asset leg that is disposed, expanded through the owner-aware cost-basis
pass.

Rules:

1. Trade disposal owner = owners resolved from the negative non-fiat trade
   leg's account.
2. Trade acquisition owner = owners resolved from the positive non-fiat trade
   leg's account.
3. Fiat/payment legs provide valuation context, not ownership authority.
4. Jointly owned account gains are split evenly across the resolved owners.
5. Owner changes do not create disposal events and are not historical.

The CGT report should emphasize owner gross figures that are valid inputs for
downstream tax work:

- Short-term capital gains.
- Long-term capital gains before discount.
- Capital losses.
- Total gain/loss.
- Discount-eligible gain as supporting information.

Owner kind controls the simple CGT presentation:

| Owner kind | v1 CGT presentation |
|---|---|
| `individual` | show estimated net capital gain using the individual-style 50% discount for discount-eligible gains |
| `trust` | show trust CGT support figures with discount-capable gains preserved for pass-through; do not present a final trust/beneficiary tax liability |

Trusts can have discount capital gains, but trust reporting and beneficiary
distribution treatment are not the same as a personal tax return. The v1 trust
report should therefore be useful for accounting support without pretending to
complete distribution or beneficiary calculations.

### Custom trades with different owners

If a custom trade assigns the disposed asset and acquired asset to different
accounts with different owners, treat it as a cross-owner disposal/acquisition:

```text
Source account owner(s): dispose the sold asset and realize CGT.
Destination account owner(s): acquire the bought asset at market cost base.
```

Example: BTC leaves Husband's wallet and ETH enters Trust's wallet. Husband
realizes the BTC capital gain or loss. The trust acquires ETH with a new cost
base.

### Non-fiat transfers

Transfers depend on effective account ownership fractions:

| Transfer shape | CGT treatment |
|---|---|
| Non-fiat transfer between accounts with identical owner fractions | cost-basis move, no CGT event |
| Non-fiat transfer between accounts with partially overlapping owner fractions | overlapping fraction moves; changed fraction disposes/acquires |
| Non-fiat transfer between accounts with no overlapping owners | disposal by source owner(s), acquisition by destination owner(s) |
| Fiat transfer between any owners | no CGT event |

For same-owner non-fiat transfers, move owner lots from source account to
destination account, preserving cost and acquisition dates.

For changed ownership fractions, the cost-basis event builder must not emit a
single simple move. It should emit owner-expanded events:

```text
overlap: move at carried cost
source-only fraction: disposal at market value on the transfer date
destination-only fraction: acquisition at market value on the transfer date
```

Example: `[Husband, Wife] -> [Husband]` for 10 ETH.

```text
Husband source fraction: 50%
Wife source fraction:    50%
Husband destination:     100%

5 ETH: Husband move, no CGT event
5 ETH: Wife disposal at market value
5 ETH: Husband acquisition at market value
```

This is the main place ownership has to feed into the cost-basis ledger rather
than only the final report projection.

## Report Result Shape

Avoid adding parallel owner-specific scalar properties to `ReportingStore`.
The current store has separate state for capital gains, profit/loss, and
general category balances. Owner-aware tax reporting should publish one
cohesive tax result for the selected financial year:

```swift
enum TaxReportOwnerSelection: Hashable, Sendable {
  case allOwners
  case owner(UUID)
}

struct TaxReportResult: Sendable {
  let financialYear: Int
  let owners: [UUID: OwnerTaxReport]
  let allOwners: OwnerTaxReportRollup
  let holdingsDate: Date
}

struct OwnerTaxReport: Sendable {
  let ownerId: UUID
  let incomeAndDeductions: OwnerIncomeDeductionReport
  let capitalGains: OwnerCapitalGainsReport
  let holdings: OwnerHoldingsReport
}
```

The view can derive the selected presentation from `TaxReportOwnerSelection`.
This lets one financial-year load compute all owners once, then owner switching
is instant and does not rerun the ledger. The load key should still include the
financial year and spam-instrument exclusions; owner selection is view state
over the loaded result.

`OwnerTaxReportRollup` is not a separate tax calculation. It is produced by
summing the owner-level reports using report-specific rollup rules.

## UI Rules

Owner UI is data-driven, not behind an "advanced mode" toggle.

```text
If profile has one tax owner:
  hide owner selectors from account/category edit flows
  resolve everything to profile.defaultTaxOwnerId

If profile has more than one tax owner:
  show owner selectors on account edit
  show optional owner selectors on category edit
  show owner filter/sections in tax reports
```

There still needs to be a way to add a second owner, probably from a tax report
settings surface. The rule is that day-to-day account/category forms do not
show ownership controls until there is actually more than one owner to choose.

Category tax reportability should be available even for single-owner profiles,
because single-person households still need taxable income and deductions.

Category edit has two independent controls:

- Include in tax report: off by default for new categories.
- Owner: shown only when the profile has more than one owner, optional, and
  described as overriding the account owner for tax reports.

The category owner control needs careful copy and layout so "optional owner
override" does not read as required setup.

## Tax Report UI

Keep the existing general "Income and Expenses" report as a non-tax analysis
surface. It should continue to show normal category cashflow, including
uncategorised rows, and should not be filtered by `isTaxReportable`. Tax
reportability defaults to off, so reusing the existing report for tax would
make ordinary spending analysis feel broken as soon as this feature ships.

Evolve the current "Capital Gains" financial-year report into an owner-aware
"Tax" report. The current capital-gains screen already has the right
financial-year framing; taxable income and deductions belong beside CGT there,
not as a filter on the general cashflow report.

The working structure is:

```text
Reports
  Income and Expenses      existing general cashflow report
  Tax                      renamed/evolved Capital Gains financial-year report
```

The Tax report contains:

- Taxable income.
- Deductible expenses.
- Realised capital gains.
- Holdings at financial-year end, if still useful as supporting information.

Controls:

```text
Financial year picker
Owner picker, shown only when the profile has more than one tax owner
```

The owner picker values are:

```text
All owners
<each TaxOwner.name>
```

`All owners` is the default for multi-owner profiles. Single-owner profiles do
not show the owner picker and implicitly use the default owner.

### Individual owner view

An individual owner view shows only amounts allocated to that owner:

- Taxable income/deductible expenses after category/account/default ownership
  resolution.
- Capital gains from disposals allocated to that owner.
- Holdings/gain while held allocated to that owner.

### All owners view

`All owners` renders a merged profile-wide rollup for display, but the data is
not calculated as one synthetic taxpayer. The report first calculates each
owner independently, then sums owner-level display values.

This matters for correctness:

- A non-fiat transfer between accounts with different owners still creates a
  disposal/acquisition event before the all-owner display is summed.
- CGT loss application and discounting should be applied per owner before
  summing owner-level net capital gain figures.
- Jointly owned disposals should not be recombined in a way that hides which
  owner received which share.

The all-owner summary tiles can be merged totals. Detail tables need more care:

- Income/deduction category rows can be merged by category, with an optional
  owner breakdown disclosure later.
- Capital-gains sale rows should either show one row per owner-attributed sale
  share with an Owner column, or group the sale visually while preserving an
  owner breakdown inside the expanded detail. The current
  transaction/instrument grouping is not sufficient on its own because it would
  recombine joint-owner shares and hide owner-specific tax treatment.
- Drill-down transaction lists from tax reports need owner-aware filters or a
  tax-specific detail list. Reusing the existing category drill-down filter
  would show non-reportable or differently owned legs unless it is extended.

Report-by-report details may differ. The invariant is that all-owner amounts
are display rollups over owner-level tax results, not independent tax
calculations over the raw profile.

## Persistence And Sync

Suggested local schema:

```sql
CREATE TABLE tax_owner (
    id                     BLOB NOT NULL PRIMARY KEY,
    record_name            TEXT NOT NULL UNIQUE,
    name                   TEXT NOT NULL,
    encoded_system_fields  BLOB
) STRICT;

CREATE TABLE account_tax_owner (
    id                     BLOB NOT NULL PRIMARY KEY,
    record_name            TEXT NOT NULL UNIQUE,
    account_id             BLOB NOT NULL,
    owner_id               BLOB NOT NULL,
    encoded_system_fields  BLOB,
    UNIQUE (account_id, owner_id)
) STRICT;

CREATE INDEX account_tax_owner_by_account
    ON account_tax_owner(account_id);
CREATE INDEX account_tax_owner_by_owner
    ON account_tax_owner(owner_id);

CREATE TABLE category_tax_owner (
    id                     BLOB NOT NULL PRIMARY KEY,
    record_name            TEXT NOT NULL UNIQUE,
    category_id            BLOB NOT NULL,
    owner_id               BLOB NOT NULL,
    encoded_system_fields  BLOB,
    UNIQUE (category_id, owner_id)
) STRICT;

CREATE INDEX category_tax_owner_by_category
    ON category_tax_owner(category_id);
CREATE INDEX category_tax_owner_by_owner
    ON category_tax_owner(owner_id);
```

Add columns:

```sql
ALTER TABLE profile ADD COLUMN default_tax_owner_id BLOB;
ALTER TABLE category ADD COLUMN is_tax_reportable INTEGER NOT NULL DEFAULT 0
  CHECK (is_tax_reportable IN (0, 1));
```

Migration should backfill a default owner for every existing profile and set
`profile.default_tax_owner_id`. The SQL column may need to be nullable at the
storage layer for forward sync/application ordering, but the domain `Profile`
should expose a non-optional default owner ID once migration has run.

If CloudKit record cardinality becomes too heavy, account/category owner IDs
could instead be stored as encoded arrays on `AccountRecord` and
`CategoryRecord`. Separate join records are cleaner for conflict behavior and
future additive shares, but they require more sync plumbing.

Required implementation notes:

- Bump `DataFormatVersion.current`.
- Add CloudKit schema entries for any new synced records/fields.
- Add delete/null-out behavior equivalent to the FK-free sync contract.
- Add one canonical SQL surface for effective owner rows, preferably a shared
  CTE builder or SQLite view used by every owner-aware query.
- Add plan-pinning tests for owner-aware income/deduction aggregation and any
  owner-aware cost-basis event leg loading.
- Add repository contract tests for default owner creation and owner fallback.

## Open Questions

1. In the all-owner capital-gains detail table, should owner attribution be a
   visible Owner column on every row, or an expandable owner breakdown under a
   visually grouped sale?
2. Should the UI label the reportable-category toggle "Include in tax report"
   or use more cautious wording such as "Tax report candidate"?
3. Do FY-end holdings belong in the first owner-aware Tax report, or should
   v1 focus on income/deductions and realised CGT only?

## Suggested Implementation Order

1. Add `TaxOwner`, `Profile.defaultTaxOwnerId`, category reportability, and
   account/category owner storage.
2. Add the Swift `TaxOwnershipResolver` and tests for all fallback cases.
3. Add owner-aware income/deduction aggregation.
4. Add owner-aware cost-basis tests and event building for joint sales,
   same-owner transfers, changed-owner transfers, partial overlaps, and
   cross-owner custom trades.
5. Publish `TaxReportResult` from `ReportingStore`, calculated per owner first
   and rolled up for all-owner display.
6. Add owner-aware tax report presentation.
7. Add account/category UI controls gated by tax-owner count.

## ATO Reference Points

Use official ATO guidance when implementing and reviewing the tax rules. The
important simple-case anchors are:

- Crypto disposals include selling, gifting, converting to fiat,
  crypto-to-crypto swaps, and using crypto to buy goods/services:
  <https://www.ato.gov.au/individuals-and-families/investments-and-assets/crypto-asset-investments/transactions-acquiring-and-disposing-of-crypto-assets/crypto-asset-transactions>
- Crypto CGT calculation, capital losses, CGT discount, and record keeping:
  <https://www.ato.gov.au/individuals-and-families/investments-and-assets/crypto-asset-investments/how-to-work-out-and-report-cgt-on-crypto>
- Personal-use crypto is a special case and not handled by this v1 model:
  <https://www.ato.gov.au/individuals-and-families/investments-and-assets/crypto-asset-investments/crypto-asset-as-a-personal-use-asset>
- Joint share ownership is generally equal unless unequal ownership is
  demonstrated:
  <https://www.ato.gov.au/forms-and-instructions/you-and-your-shares-2025/share-ownership-liquidation-mergers-rights-and-buy-backs/joint-ownership-of-shares>
- Rental expenses may need apportionment and are not all immediately
  deductible:
  <https://www.ato.gov.au/individuals-and-families/investments-and-assets/property-and-land/residential-rental-properties/rental-expenses/how-to-claim-rental-expenses>
