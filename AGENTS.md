# Codex Instructions - moolah-native

Read this file before work.

## Shared Guides

These assistant-facing guides apply to Codex:

- `guides/AI_ASSISTANT_GUIDE.md` for shared assistant rules and the mandatory review gate.
- `guides/AI_REVIEW_GATE_GUIDE.md` for reviewer finding policy.
- `guides/AI_WORKFLOW_GUIDE.md` for commands, test-output capture, formatting, warnings, and pre-commit checks.
- `guides/AI_ARCHITECTURE_GUIDE.md` for architecture constraints, thin views, money/instrument rules, and testing discipline.
- `guides/AI_PROJECT_GUIDE.md` for bug tracking, planning-document locations, and reviewer routing.

Task-specific guides still apply: `CODE_GUIDE.md`, `TEST_GUIDE.md`, `UI_TEST_GUIDE.md`, `UI_GUIDE.md`, `CONCURRENCY_GUIDE.md`, `SYNC_GUIDE.md`, `DATABASE_SCHEMA_GUIDE.md`, `DATABASE_CODE_GUIDE.md`, `DATE_TIME_GUIDE.md`, `INSTRUMENT_CONVERSION_GUIDE.md`, `BRAND_GUIDE.md`, and `HELP_GUIDE.md`.

`CLAUDE.md` contains Claude-specific workflow notes and historical detail. Follow shared guides first; use `CLAUDE.md` only for relevant rules that have not yet been extracted and that do not depend on Claude-only tools.

## Git Workflow

Follow the shared branch-and-PR rule in `guides/AI_WORKFLOW_GUIDE.md`. Codex has no built-in worktree tooling, so manage worktrees with `wt` (Worktrunk) — `wt switch --create <branch>` — then open the PR with `gh pr create`. Never push to `main`.

## Codex Skills And Agents

- Repo skills are exposed through `.agents/skills`.
- Codex custom review agents live in `.codex/agents`.
- Codex review agents are thin wrappers around `.claude/agents/*.md`; read the referenced detailed checklist before reviewing.
- Codex only spawns subagents when explicitly asked. Before committing code, explicitly run or request the relevant review agents and repeat review/fix until no findings remain.
