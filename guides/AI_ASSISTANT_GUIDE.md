# AI Assistant Guide

This guide contains assistant-facing rules that apply to all AI coding tools used in this repo. Tool-specific entrypoints such as `CLAUDE.md`, `AGENTS.md`, skills, and agents should reference this guide instead of duplicating it.

## Quality Gate

There is no routine human code review in this repo. AI reviewer agents are the required quality gate. `guides/AI_REVIEW_GATE_GUIDE.md` is the shared policy for reviewer findings.

- Run the relevant reviewer agents before committing any code.
- Do not skip review because a change is small.
- Do not ignore, defer, or downgrade reviewer findings.
- Treat pre-existing findings as findings to fix now, unless the user explicitly authorizes a narrower scope in the conversation.
- After fixing findings, repeat the review and fix cycle until the relevant reviewers report no findings.

Use at least `code-review` after modifying production Swift. Add specialized reviewers when the change touches their area:

- `ui-review` for SwiftUI views, user-facing strings, layout, accessibility, or Apple HIG concerns.
- `concurrency-review` for stores, repositories, async code, actor isolation, tasks, or `Sendable`.
- `sync-review` for CloudKit sync engines, record mappings, sync queues, or syncable repository mutations.
- `database-schema-review` for migrations, schema files, indexes, PRAGMAs, database files, or retention policy.
- `database-code-review` for GRDB records, repositories, SQL, query planning, or database queue usage.
- `instrument-conversion-review` for money, instruments, conversion, aggregation, reporting, forecasts, or totals.
- `datetime-review` for month/day parsing, keys, comparisons, chart dates, "today", or timezone-sensitive logic.
- `ui-test-review` for UI tests, screen drivers, test identifiers, seeds, or `.accessibilityIdentifier`.
- `help-review` for help content, onboarding, tooltips, empty states, error messages, or settings copy.
- `appstore-review` before release tagging.

## Shared Workflow

- Keep durable repo rules in guides and reference them from assistant-specific files.
- Keep `CLAUDE.md` and `AGENTS.md` short enough to load reliably.
- Put reusable workflows in skills, not in general instructions.
- Prefer one source of truth. If a rule applies to both Claude and Codex, put it in this guide or another guide under `guides/`.
- Keep assistant-specific wrappers thin and explicit about which shared file to read.

## Repo Discipline

- Use `just` targets for build, test, format, release, and generated-project work.
- Capture test output in `.agent-tmp/` when running tests so failures can be inspected without rerunning.
- Never edit `Moolah.xcodeproj` or generated CloudKit wire files directly.
- Follow the domain isolation, thin-view, concurrency, testing, TODO, and style rules in `CLAUDE.md` and the guides it names.
- Before committing, run `just format`, the appropriate tests/build, and the required reviewer cycle.
- Before relying on or relaying a subagent's factual claim about *current* shipped code (a method body, whether a file or test exists, a control-flow detail), verify it against `origin/main` (`git show origin/main:<path>`). Subagents often work in worktrees branched off an older commit and confidently state pre-merge behaviour as current fact — especially a premise that "explains" a bug a merged PR already fixed.
