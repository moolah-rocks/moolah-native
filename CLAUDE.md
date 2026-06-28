# Claude Code Instructions — moolah-native

## Shared AI Instructions

Shared assistant rules live in `guides/AI_ASSISTANT_GUIDE.md`. Read that guide before modifying files. In particular, AI reviewer agents are the required quality gate in this repo: run the relevant reviewers before committing, fix every finding immediately, and repeat review plus fixes until no findings remain.

## Git Workflow

The shared branch-and-PR rule (`main` is protected, land every change via a pull request, never `git push origin main`) lives in `guides/AI_WORKFLOW_GUIDE.md`. The mechanics below are Claude-specific.

- **Default to a worktree, created with `EnterWorktree(name: <branch>)`.** Never make changes directly on the `main` checkout. At the start of any task that modifies files, create a worktree with **`EnterWorktree(name: <branch>)`** — it sets everything up for you (carries the gitignored `.env` over from the main checkout, rebases onto the default branch, and switches the session in). **Never** create worktrees with raw `git worktree add`, and never hand-copy `.env`. Clean up a finished worktree (PR on automerge) with **`ExitWorktree(action: "remove")`** — add `discard_changes: true` if it balks at the gitignored `.env`.
- **Ship via PR.** Push the feature branch and open a pull request with `gh pr create`. Do not attempt `git push origin main` — it will be rejected by branch protection.
- **Exceptions:** Read-only inspection and investigation can happen on the `main` checkout without a worktree. If you're unsure whether a task will require edits, create the worktree up front.

### Already in a worktree? `EnterWorktree` refuses to nest — `ExitWorktree` first

`EnterWorktree` fails with "Already in a worktree session" if the session is **already** inside a worktree (common when a previous task's worktree is still active, or a new task arrives in an existing worktree). To start a *different* worktree, return to the `main` checkout first, then create the new one:

1. `ExitWorktree` — `action: "keep"` to preserve the current worktree (its branch and files stay on disk), or `action: "remove"` if its work is done. Either way the session returns to the `main` checkout.
2. `EnterWorktree(name: <branch>)` — creates the new worktree and switches the session into it.

Do **not** reach for a raw `git worktree add` (+ `EnterWorktree(path:)`) to dodge the nesting restriction — that bypasses the setup the worktree tools do for you. And do **not** operate on a second worktree purely via absolute paths while the session CWD is stuck in the first one: skill, plan, and memory resolution all key off the session CWD, so they will silently target the wrong tree.

### Stacked-PR worktrees: don't accidentally push into the parent PR

`EnterWorktree(name:)` branches off the default branch, and the `landing-prs` skill handles stacking by retargeting a child PR to `main` once its parent merges — prefer that. The footgun below applies only if you deliberately use a raw `git worktree add` off another PR's head.

When you create such a worktree (e.g. stacking a fix-up PR on top of an open PR), `git worktree add -b <new-local> <remote-tracking-branch>` silently sets the new local branch to **track the parent's remote branch**. A subsequent `git push -u origin <new-local>` then pushes your commits *into the parent PR's branch* — overwriting or extending the wrong PR. This has happened; recovery requires a force-push to restore the parent.

To prevent it:

- **Pass `--no-track` when creating the worktree:**
  ```bash
  git -C <repo> worktree add --no-track .worktrees/<name> -b <new-local> origin/<base-branch>
  ```
- **Push with the explicit `<src>:<dst>` form** so the destination ref is unambiguous, even if upstream tracking is set wrong:
  ```bash
  git -C <worktree> push origin <new-local>:<new-local>
  ```
- Do **not** rely on `git push -u origin <new-local>` for the first push — without `--no-track` it resolves to the upstream-tracked branch, which is the parent's, not a new branch.

If you do push into the wrong branch by accident, push your commit to a new branch first to preserve the work, then force-push the parent's branch back to its previous head (verify the SHA via `gh pr view <parent> --json headRefOid` before and after).

### Xcode previews and the `mcp__xcode__RenderPreview` tool from a worktree

`mcp__xcode__RenderPreview` (and SwiftUI canvas previews in general) operate against **whichever `Moolah.xcodeproj` is currently open in Xcode**. If Xcode is open on the main checkout but you're editing a worktree, the tool will read stale source from the main checkout — newly added `#Preview` blocks won't be discoverable, and SourceKit diagnostics in the worktree may reference types as "not in scope" even though `just build-mac` from the worktree succeeds.

To use previews against a worktree:

1. `just -d <worktree-path> --justfile <worktree-path>/justfile generate` — `xcodegen` produces a per-worktree `Moolah.xcodeproj` (the project file is gitignored, so each worktree has its own).
2. Open the worktree's `Moolah.xcodeproj` in Xcode (`open <worktree-path>/Moolah.xcodeproj`). `mcp__xcode__RenderPreview` will then read from the worktree.

If the build passes from the worktree (`just build-mac`) but SourceKit / RenderPreview disagrees, the cause is usually that Xcode is still indexed against the main checkout — switch Xcode to the worktree's project before re-rendering.

## Shared Workflow, Architecture, And Project Rules

The following shared guides apply to all AI assistants:

- `guides/AI_WORKFLOW_GUIDE.md` for commands, test-output capture, formatting, warnings, and pre-commit checks.
- `guides/AI_ARCHITECTURE_GUIDE.md` for architecture constraints, thin views, money/instrument rules, and testing discipline.
- `guides/AI_PROJECT_GUIDE.md` for bug tracking, planning-document locations, and reviewer routing.
- `guides/AI_ASSISTANT_GUIDE.md` and `guides/AI_REVIEW_GATE_GUIDE.md` for the mandatory AI review gate.

Claude-specific reviewer definitions remain in `.claude/agents/`. Codex wrappers live in `.codex/agents/`.

## Agents

Claude review agents live in `.claude/agents/` and are invoked with `@<name>` (for example, `@code-review` or `@ui-review`). Reviewer routing is maintained in `guides/AI_PROJECT_GUIDE.md`; finding policy is maintained in `guides/AI_REVIEW_GATE_GUIDE.md`.
