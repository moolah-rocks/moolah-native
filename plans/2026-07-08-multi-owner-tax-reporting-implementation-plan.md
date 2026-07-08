# Multi-owner Tax Reporting - Implementation Plan

Build from `plans/2026-07-08-multi-owner-tax-reporting-design.md`.

## Principles

- Keep existing single-owner behavior invisible and stable.
- Ship in PR-sized slices. Each slice gets tests, format/checks, and the
  required review agents before commit.
- Preserve existing general Reports behavior. The current Income & Expenses
  report stays non-tax.
- Calculate owner-level tax results first. `All owners` is a display rollup,
  never a profile-wide taxpayer calculation.
- Feed ownership into cost-basis event building before FIFO for CGT paths.

## Slice 1 - Domain ownership model and Swift resolver

Goal: establish pure domain types and fallback behavior without persistence or
UI dependencies.

Files:

- Add `Domain/Models/TaxOwner.swift`.
- Add `Domain/Models/TaxOwnershipResolver.swift`.
- Extend `Domain/Models/Account.swift` with optional `taxOwnerIds`.
- Extend `Domain/Models/Category.swift` with `isTaxReportable` and optional
  `taxOwnerIds`.
- Add tests under `MoolahTests/Domain/`.

Acceptance criteria:

- `TaxOwnerKind` supports `.individual` and `.trust`.
- New `Category` values default to `isTaxReportable == false`.
- Account/category owner arrays are optional; nil and empty both fall back.
- Resolver order is category owners -> account owners -> profile default.
- Resolver returns arbitrary owner counts with equal fractions.
- Existing account/category Codable decodes old data with defaults.

Verification:

- `just test-mac TaxOwnershipResolverTests AccountTests CategoryRepositoryContractTests`
- `just format-check`

Reviewers:

- `code-review`

## Slice 2 - Persistence and sync

Goal: persist tax owners, profile default owner, category reportability, and
account/category owner allocations.

Files/areas:

- `Domain/Repositories/`: add `TaxOwnerRepository` or extend a tax/profile
  repository boundary if one exists.
- `Domain/Repositories/BackendProvider.swift`: expose tax-owner repository.
- `Backends/GRDB/ProfileIndexSchema*.swift`: add/sync
  `Profile.defaultTaxOwnerId`; profile metadata lives in the profile-index DB,
  while `tax_owner` rows live in the per-profile DB.
- `Backends/GRDB/ProfileSchema*.swift`: add migration.
- `Backends/GRDB/Records/`: add tax-owner and allocation rows.
- `Backends/GRDB/Repositories/`: add repository and mapping.
- `Backends/GRDB/Sync/`: add CloudKit row mappings.
- `CloudKit/schema.ckdb`: add fields/records through the CloudKit schema
  workflow.
- `Backends/CloudKit/Sync/ProfileDataSyncHandler*`: include new record types
  in queue/apply paths.
- `TestBackend`: seed/default support.

Schema shape:

- `tax_owner(id, record_name, name, kind, encoded_system_fields, needs_push)`.
- `account_tax_owner(id, record_name, account_id, owner_id, encoded_system_fields, needs_push)`.
- `category_tax_owner(id, record_name, category_id, owner_id, encoded_system_fields, needs_push)`.
- `profile.default_tax_owner_id`.
- `category.is_tax_reportable DEFAULT 0`.

Default owner bootstrap:

- Prefer a deterministic default owner id derived from `profile.id`, or a
  nullable storage column with a domain fallback that resolves deterministically.
- Per-profile migration must create the matching default `tax_owner` row.
- Profile-index migration must set/sync `default_tax_owner_id`.
- Tests must cover cross-database ordering so a profile cannot point at a
  missing owner forever.

Acceptance criteria:

- Existing profiles migrate with one default individual tax owner.
- New profiles create one default individual tax owner.
- Account/category owner assignments round-trip locally and through domain
  repositories.
- Category reportability round-trips and defaults false for old rows.
- Remote deletes replicate FK-free cleanup semantics.
- Sync queues only user-initiated owner/allocation mutations.
- Queue-all-existing, needs-push scanning, deletion journal behavior, record
  lookup, and system-fields caching include the new record types.

Verification:

- Repository contract tests for tax owners and allocation persistence.
- GRDB migration tests for existing profile backfill.
- CloudKit row mapping tests.
- `just test-mac TaxOwner AccountRepositoryContractTests CategoryRepositoryContractTests`
- `just format-check`

Reviewers:

- `code-review`
- `database-schema-review`
- `database-code-review`
- `sync-review`

Skill:

- Use `modifying-cloudkit-schema` before CloudKit schema work.

## Slice 3 - Owner-aware income and deduction report data

Goal: add tax-specific category aggregation without changing the general Income
& Expenses report.

Files/areas:

- `Domain/Repositories/AnalysisRepository.swift`: add tax report aggregation
  method or a tax-specific repository boundary.
- `Backends/GRDB/Repositories/GRDBAnalysisRepository+Tax*.swift`: owner-aware
  SQL aggregation.
- Shared SQL helper for effective owner rows.
- `Features/Reports/`: owner income/deduction DTOs.

Acceptance criteria:

- Only `isTaxReportable` categories are included.
- `.income` legs produce taxable income; `.expense` legs produce deductible
  expense; other leg types are excluded.
- Uncategorised legs are excluded.
- Category owners override account owners; account owners override profile
  default.
- Arbitrary owner counts split equally.
- Conversion uses each row's own date and preserves Rule 11 unavailable flags.
- Existing `loadCategoryBalances` and Income & Expenses UI remain unchanged.

Verification:

- Plan-pinning tests for owner-aware SQL.
- Analysis contract tests for owner fallback/splitting/category gating.
- `just test-mac ReportingStoreTaxIncomeDeductionTests GRDBTaxReportAggregationTests`
- `just format-check`

Reviewers:

- `code-review`
- `database-code-review`
- `instrument-conversion-review`

## Slice 4 - Owner-aware cost basis and CGT

Goal: calculate owner-level CGT before all-owner rollup.

Files/areas:

- `Shared/CostBasisEventBuilder.swift`
- `Shared/HoldingsCostLedger.swift` and related pass/query files, or a
  tax-specific owner-aware ledger if preserving the existing account ledger is
  cleaner.
- `Shared/CapitalGainsCalculator.swift`
- `Features/Reports/ReportingStore.swift`
- `Features/Reports/CapitalGainsSummary.swift`

Acceptance criteria:

- Joint account sales split quantity, cost base, proceeds, gains/losses, and
  holding-period classification equally by owner.
- Same-owner non-fiat transfers move owner lots with no CGT event.
- Different-owner non-fiat transfers dispose/acquire at market value.
- Partial-overlap transfers move the overlapping fraction and dispose/acquire
  only the changed fraction.
- Cross-owner custom trades dispose for source owner(s) and acquire for
  destination owner(s).
- `All owners` rollup sums owner reports after owner-level loss/discount
  handling.
- Trust owners show trust support figures; individual owners show simple
  discounted estimate.
- Existing account performance, positions, and non-tax P&L consumers either
  keep using owner-agnostic output or intentionally sum owner-expanded lots
  back to the existing account/instrument shape.

Verification:

- Unit tests for owner-expanded FIFO/event builder.
- ReportingStore tests for individual and all-owner CGT summaries.
- Regression tests that existing non-tax account performance remains stable.
- `just test-mac HoldingsCostLedger CapitalGainsCalculator ReportingStoreTax`
- `just format-check`

Reviewers:

- `code-review`
- `instrument-conversion-review`
- `datetime-review`
- `concurrency-review` if ledger store/loading changes.

## Slice 5 - Tax report result and presentation

Goal: evolve the current Capital Gains report into a Tax report.

Files/areas:

- `Features/Reports/Views/ReportSection.swift`: rename/evolve section.
- `Features/Reports/Views/ReportsSelector.swift`: financial year + owner
  picker.
- `Features/Reports/Views/ReportsView.swift`
- `Features/Reports/Views/TaxReportView.swift`
- New income/deduction table views if needed.
- `UITestSupport/UITestIdentifiers+Reports.swift`

Acceptance criteria:

- Existing Income & Expenses report remains unchanged.
- Tax report includes taxable income, deductible expenses, realised CGT, and
  optional FY-end holdings.
- Single-owner profiles hide owner selector.
- Multi-owner profiles default to `All owners`.
- Individual owner selection updates instantly from loaded `TaxReportResult`.
- All-owner CGT details preserve owner attribution.
- Empty/unavailable states remain honest under Rule 11.

Verification:

- Store/presentation tests for owner selection and rollup.
- SwiftUI previews for single-owner and multi-owner reports.
- UI tests for owner picker visibility and report switching if practical.
- `just test-mac TaxReportPresentation ReportingStoreTax`
- `just format-check`

Reviewers:

- `code-review`
- `ui-review`
- `help-review` for report copy.
- `ui-test-review` if UI tests are touched.

## Slice 6 - Account/category owner controls

Goal: expose ownership only when useful while keeping tax reportability
available for single-owner profiles.

Files/areas:

- `Features/Accounts/Views/EditAccountView.swift`
- `Features/Accounts/Views/CreateAccountView.swift`
- `Features/Categories/Views/CategoryDetailView.swift`
- `Features/Categories/Views/CreateCategorySheet.swift`
- `Features/Reports/` or settings surface for adding second owner.

Acceptance criteria:

- Account/category owner controls are hidden while the profile has one owner.
- Category "Include in tax report" control is available regardless of owner
  count and defaults off.
- A user can add a second owner from a discoverable tax/settings surface.
- Multi-owner pickers support arbitrary selected owners.
- Removing an owner is either unsupported in v1 or safely constrained.

Verification:

- Store tests for owner mutations.
- UI/previews for single and multi-owner forms.
- UI tests if identifiers are added.
- `just test-mac AccountStore CategoryStore TaxOwner`
- `just format-check`

Reviewers:

- `code-review`
- `ui-review`
- `help-review`
- `sync-review` if owner mutations are wired here.

## Controller Notes

- Subagents can own exploration or isolated implementation slices, but schema,
  sync, and owner-aware cost-basis changes must be integrated carefully by the
  controller.
- Do not mix slices in one commit/PR.
- Before each slice, re-read its acceptance criteria and relevant repo guides.
- Before committing code, run required tests, `just format`, `just format-check`,
  and the relevant reviewer agents until no findings remain.
