# AI Project Guide

Shared project-management and reviewer-routing rules for AI assistants.

## Bug Tracking

- Known bugs and feature issues live in GitHub issues: `https://github.com/moolah-rocks/moolah-native/issues`.
- Bug-fix PRs should close the related issue with `Fixes #123`.
- Swift `TODO` and `FIXME` comments must reference an open issue: `TODO(#N): reason -- https://github.com/moolah-rocks/moolah-native/issues/N`.
- Bare `TODO:` and `FIXME:` comments are disallowed.
- CI validates TODO references with `just validate-todos`.

## Planning

- Planning documents, feature specs, design specs, and gap analyses live in `plans/`.
- Completed plans move to `plans/completed/`.
- Do not create a `docs/` directory for plans, even if a skill suggests one.

## Production Data

- The production profile holds real financial data. Never apply data changes to it without an explicit, in-the-moment confirmation for that production run.
- Validating a migration or script on a development profile is required, but is not itself authorization to run it against production. Validate on dev, then stop, summarize exactly what will change on production, and ask before proceeding.
- Prior permission to "modify production directly" is scoped to the one case it was given for; it does not carry forward to later runs.

## Reviewer Routing

Run the relevant reviewer agents before committing. Findings follow `guides/AI_REVIEW_GATE_GUIDE.md`.

- `code-review`: production Swift, architecture, naming, types, protocols, errors, optionals, extension organization, thin-view discipline, TODO format.
- `ui-review`: SwiftUI, user-facing strings, layout, Apple HIG, accessibility.
- `concurrency-review`: stores, repositories, backend code, actor isolation, task hygiene, `Sendable`, async patterns.
- `sync-review`: CKSyncEngine, sync queueing, record mappings, conflict handling, account/zone changes.
- `database-schema-review`: schemas, migrations, indexes, PRAGMAs, database files, retention policy.
- `database-code-review`: GRDB records, repositories, SQL safety, query plans, transactions, database queues.
- `instrument-conversion-review`: `InstrumentAmount`, conversion dates, aggregations, reporting, forecasts, totals.
- `datetime-review`: month/day parsing, keys, comparisons, chart axes, "today", timezone-sensitive logic.
- `ui-test-review`: UI tests, screen drivers, identifiers, deterministic seeds, accessibility identifiers.
- `help-review`: help articles, onboarding, tooltips, empty states, errors, settings copy, brand voice.
- `appstore-review`: release tagging, App Store validation, Info.plist, project.yml, entitlements, icons.
