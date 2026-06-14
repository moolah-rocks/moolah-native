---
name: landing-prs
description: Use when landing a PR in this repo — setting it to merge, "queuing it", enabling automerge, or shipping a stacked PR. Anything that lands code on main goes through this skill. Covers the simple case (`gh pr merge --auto --rebase`) and the stacked case (autonomous watcher that retargets to main and enqueues once the parent merges). Use when the user says "land", "ship", "queue", "merge", "set to automerge", or opens a PR targeting a non-main base.
---

# Landing PRs

This repo uses **GitHub's native merge queue** on `main`. The repo's branch ruleset on `main` requires the merge queue for every merge — direct push is rejected, "Merge" / "Rebase" / "Squash" buttons on PRs route through the queue, and CI runs on `gh-readonly-queue/main/pr-<N>-...` branches via the workflow's `merge_group:` trigger.

There is no project-level custom merge-train daemon any more. The user-level `~/.claude/skills/merge-queue/` skill exists but is **not for this repo** — it's reserved for projects without native merge queue access (e.g. a public repo on a personal account, where the feature is org-only).

## TL;DR

| Situation | Action |
|---|---|
| PR base is `main`, you want it to land | `gh pr merge <N> --auto --rebase` (or just run `land-pr.sh <N>`) |
| PR base is another feature branch (stacked) | `./.claude/skills/landing-prs/scripts/land-pr.sh <N>` — it starts a watcher that auto-retargets + auto-enqueues once the parent merges |
| You want to cancel automerge / pull a PR out of the queue | `gh pr merge <N> --disable-auto`; or, if it's currently in the queue, click "Remove from queue" in the GitHub UI |
| Watcher running for a stacked PR, you want to kill it | `pkill -f 'watch-stacked-pr.sh <N>'`; logs are in `.agent-tmp/landing-prs/watch-<N>.log` |

Always invoke `land-pr.sh` instead of `gh pr merge --auto --rebase` directly when the PR might be stacked — `land-pr.sh` detects the case automatically and falls through to the simple path when the PR targets `main`.

## Why a watcher is needed for stacked PRs

GitHub's automerge has a footgun for stacked PRs: **it merges the PR into whatever branch it currently targets**, not into `main`.

Concretely: if you open child PR #B with `--base feat/parent-branch` (because it stacks on PR #A which is open at that branch), and then you call `gh pr merge B --auto`, the moment checks pass, **#B merges into `feat/parent-branch`**. The child's commits become part of the parent's PR. The parent's diff balloons. The parent's CI re-runs against the combined diff. You then have to recover by extracting the child's commits to a new branch and force-pushing the parent back to its pre-merge state — exactly the recovery flow documented in `CLAUDE.md` under "Stacked-PR worktrees".

The fix: **never enable automerge on a stacked PR until its base has been retargeted to `main`**, which can only safely happen after the parent has merged. The watcher in this skill enforces that ordering.

(Native merge queue does NOT prevent this on its own. The queue's "Require merge queue" rule applies to `main`. A merge into `feat/parent-branch` doesn't go through the queue — branch protection doesn't apply — and the merge happens directly.)

## Procedure: regular PR (base = main)

```bash
./.claude/skills/landing-prs/scripts/land-pr.sh <N>
```

Detects `base == main`, runs `gh pr merge <N> --auto --rebase`. That enables automerge, which queues the PR with GitHub's native merge queue. When checks pass on the PR head, GitHub creates a `gh-readonly-queue/main/pr-<N>-...` branch with the PR rebased on top of main, runs CI on it (via the `merge_group:` trigger in `.github/workflows/ci.yml`), and fast-forwards `main` once green.

You don't have to wait. The script exits immediately after enabling automerge. The queue handles the rest.

## Procedure: stacked PR (base = another feature branch)

```bash
./.claude/skills/landing-prs/scripts/land-pr.sh <N>
```

Detects `base != main`, looks up the parent PR (the open PR whose `headRefName` matches the child's `baseRefName`), and backgrounds `watch-stacked-pr.sh` to poll both PRs every 60 seconds. The watcher:

- **Parent merged** → retargets child to `main` (`gh pr edit <N> --base main`), then enables automerge on the child. Exits.
- **Parent closed unmerged** → notifies via `osascript` and exits (child can't auto-proceed).
- **Child CI failed / merge conflict / closed** → notifies and exits. You fix and re-run `land-pr.sh <N>`.

The watcher survives `nohup` past the launching shell, so closing the terminal is safe. Its log lives at `.agent-tmp/landing-prs/watch-<N>.log`.

## Scripts

### `scripts/land-pr.sh <PR> [--repo OWNER/REPO]`

Entry point. Detects regular vs stacked and dispatches.

- `--repo` is optional; defaults to the current repo (from `gh`'s context). Useful when running from outside a checkout.
- Exit codes:
  - `0` — automerge enabled successfully, or watcher backgrounded successfully.
  - `1` — couldn't find parent PR for a stacked child (refuses to guess).
  - `2` — usage error.

### `scripts/watch-stacked-pr.sh <CHILD-PR> <PARENT-PR> [--repo OWNER/REPO]`

Background watcher. Not normally invoked directly — `land-pr.sh` calls it under `nohup`. You can invoke it manually if you need to resume watching after a session restart.

Polls every 60s. Emits one-line status updates to its log file. On terminal state, sends a desktop notification (via `osascript`) and exits.

Foreground use: omit `nohup` and run directly — log lines go to stdout. Useful for `Monitor` integration if you want Claude to react to events:

```bash
./.claude/skills/landing-prs/scripts/watch-stacked-pr.sh 42 41
```

## Common operations

**List active watchers:**
```
pgrep -af watch-stacked-pr.sh
```

**Tail a watcher's log:**
```
tail -f .agent-tmp/landing-prs/watch-<N>.log
```

**Cancel a watcher:**
```
pkill -f 'watch-stacked-pr.sh <N> '
```
(Note the trailing space — pgrep/pkill regex anchors on the child PR number, not the parent's.)

**Re-arm a watcher** (e.g. after a session restart where the background process died):
```
./.claude/skills/landing-prs/scripts/watch-stacked-pr.sh <CHILD> <PARENT> &
```

## Failure modes and recovery

| Symptom | Cause | Fix |
|---|---|---|
| `land-pr.sh` says "No open PR found for branch 'X'" | The PR has been opened against a base whose head PR doesn't exist or is closed. | Open the parent PR first, or manually retarget the child to `main` (`gh pr edit <N> --base main`) if the stacking is no longer needed. |
| Watcher running but the child PR's base never changed when the parent merged | The watcher process died (e.g. machine restart). | `pgrep -af watch-stacked-pr.sh` to check; re-arm via the "Re-arm" command above. |
| Child PR merged into the parent's branch instead of main | Automerge was enabled on the child before its base was retargeted (the very footgun this skill exists to prevent). | Follow the recovery in `CLAUDE.md` § "Stacked-PR worktrees: don't accidentally push into the parent PR". |
| Native merge queue is BLOCKED with all PR-level checks green | The queue branch's CI hasn't run, or hasn't passed. Likely the workflow doesn't subscribe to `merge_group:`. | Verify `.github/workflows/ci.yml` has `merge_group:` in `on:`. If a workflow change is needed, push a fix to the same PR (auto-removes from queue), re-enable automerge after CI passes on the new head. |
| `mergeStateStatus: BEHIND` | Branch is behind base; native MQ doesn't auto-rebase. | Either rebase locally + force-push (rebase merge method), or `gh pr update-branch <N>` for merge-commit method. |

## Clean up the worktree once automerge is enabled

As soon as automerge is on, the PR is done from your side — the remote branch holds the work and the merge queue handles the rest. **Remove the worktree and delete its local branch now; don't leave it sitting around waiting for the merge to complete.** Everything is committed and pushed, so the worktree is disposable and trivially recreated later if you ever need it again.

```bash
git -C <repo> worktree remove .claude/worktrees/<name>
git -C <repo> branch -D <local-branch>
```

Safe because: the work is on `origin/<branch>` and tied to the PR. If a follow-up is needed, re-create the worktree off the remote branch (`git -C <repo> worktree add --no-track .claude/worktrees/<name> <branch> origin/<branch>`).

**Skip cleanup only when:**

- There are uncommitted or unpushed changes in the worktree (nothing to recover from if you delete it).
- Automerge isn't enabled yet — e.g. a stacked PR whose `watch-stacked-pr.sh` watcher is still waiting on the parent (the watcher reads nothing from the worktree, but you may still need it for fix-ups before the child can land).
- `worktree remove` refuses because the tree is dirty; investigate rather than force it.

This is a deliberate exception to the older "leave cleanup to the user" stance: cleanup is cheap and reversible precisely *because* the gate is "committed + pushed + on automerge."

If you need merge-event-driven follow-on work (not just worktree cleanup), layer it on top using the user-level `monitoring-pr-status` skill, which exposes merge / failure events as a stream of stdout lines suitable for `Monitor`-based integration.
