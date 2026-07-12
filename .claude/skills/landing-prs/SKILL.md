---
name: landing-prs
description: Use when landing a PR in this repo — setting it to merge, "queuing it", enabling automerge, monitoring it until it actually merges, reporting failures that need fixes, or shipping a stacked PR. Anything that lands code on main goes through this skill. Covers the simple case and the stacked case (autonomous watcher that retargets to main and enqueues once the parent merges). Use when the user says "land", "ship", "queue", "merge", "set to automerge", or opens a PR targeting a non-main base.
---

# Landing PRs

This repo uses **GitHub's native merge queue** on `main`. The repo's branch ruleset on `main` requires the merge queue for every merge — direct push is rejected, "Merge" / "Rebase" / "Squash" buttons on PRs route through the queue, and CI runs on `gh-readonly-queue/main/pr-<N>-...` branches via the workflow's `merge_group:` trigger.

There is no project-level custom merge-train daemon any more. The user-level `~/.claude/skills/merge-queue/` skill exists but is **not for this repo** — it's reserved for projects without native merge queue access (e.g. a public repo on a personal account, where the feature is org-only).

## TL;DR

| Situation | Action |
|---|---|
| PR base is `main`, you want it to land | Run `land-pr.sh <N>` — it enables automerge and watches until the PR actually merges |
| PR base is another feature branch (stacked) | Run `land-pr.sh <N>` — it watches the parent, auto-retargets + auto-enqueues the child, then watches until the child actually merges |
| You want to cancel automerge / pull a PR out of the queue | `gh pr merge <N> --disable-auto`; or, if it's currently in the queue, click "Remove from queue" in the GitHub UI |
| Watcher running, you want to kill it | `pkill -f 'watch-pr.sh <N> '`; logs are in `.agent-tmp/landing-prs/watch-<N>.log` |

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

Detects `base == main`, runs `gh pr merge <N> --auto --rebase`, then backgrounds `watch-pr.sh`. Automerge queues the PR with GitHub's native merge queue. When checks pass on the PR head, GitHub creates a `gh-readonly-queue/main/pr-<N>-...` branch with the PR rebased on top of main, runs CI on it (via the `merge_group:` trigger in `.github/workflows/ci.yml`), and fast-forwards `main` once green.

The watcher keeps polling until `mergedAt` is present. It reports success only after the PR actually merges. It tracks both PR-head checks and the native merge-queue entry. If CI fails, a check is cancelled/times out/requires action/fails to start, the queue entry becomes unmergeable or disappears before merge, the PR conflicts, or it closes unmerged, the watcher exits nonzero and tells you to fix the problem and rerun `land-pr.sh`.

## Procedure: stacked PR (base = another feature branch)

```bash
./.claude/skills/landing-prs/scripts/land-pr.sh <N>
```

Detects `base != main`, looks up the parent PR (the open PR whose `headRefName` matches the child's `baseRefName`), and backgrounds `watch-pr.sh` to poll both PRs every 60 seconds. The watcher:

- **Parent merged** → retargets child to `main` (`gh pr edit <N> --base main`), enables automerge, and continues watching.
- **Child merged** → notifies via `osascript` and exits successfully.
- **Parent closed unmerged** → notifies and exits nonzero (child can't auto-proceed).
- **Child CI failed / merge conflict / closed unmerged** → tells you to fix it, notifies, and exits nonzero. Fix the problem and rerun `land-pr.sh <N>`.

The watcher survives `nohup` past the launching shell, so closing the terminal is safe. Its log lives at `.agent-tmp/landing-prs/watch-<N>.log`.

## Scripts

### `scripts/land-pr.sh <PR> [--repo OWNER/REPO]`

Entry point. Detects regular vs stacked and dispatches.

- `--repo` is optional; defaults to the current repo (from `gh`'s context). Useful when running from outside a checkout.
- Exit codes:
  - `0` — watcher backgrounded successfully. This does not mean the PR has merged; follow its log to a terminal result.
  - `1` — couldn't find parent PR for a stacked child (refuses to guess).
  - `2` — usage error.

### `scripts/watch-pr.sh <PR> [--parent PARENT-PR] [--automerge-enabled] [--repo OWNER/REPO]`

Background watcher. Not normally invoked directly — `land-pr.sh` calls it under `nohup`. `--parent` selects the stacked flow; `--automerge-enabled` tells a restarted watcher that enqueueing is already done.

Polls every 60s. Emits one-line status updates to its log file. On merge or a fix-required state, sends a desktop notification (via `osascript`) and exits. `watch-stacked-pr.sh` remains as a compatibility wrapper.

Foreground use: omit `nohup` and run directly — log lines go to stdout. Useful when you want the agent to react to events:

```bash
./.claude/skills/landing-prs/scripts/watch-pr.sh 42 --parent 41
```

## Common operations

**List active watchers:**
```
pgrep -af watch-pr.sh
```

**Tail a watcher's log:**
```
tail -f .agent-tmp/landing-prs/watch-<N>.log
```

**Cancel a watcher:**
```
pkill -f 'watch-pr.sh <N> '
```
(Note the trailing space — pgrep/pkill regex anchors on the child PR number, not the parent's.)

**Re-arm a watcher** after automerge is already enabled (e.g. after a session restart):
```
./.claude/skills/landing-prs/scripts/watch-pr.sh <PR> --automerge-enabled &
```

## Failure modes and recovery

| Symptom | Cause | Fix |
|---|---|---|
| `land-pr.sh` says "No open PR found for branch 'X'" | The PR has been opened against a base whose head PR doesn't exist or is closed. | Open the parent PR first, or manually retarget the child to `main` (`gh pr edit <N> --base main`) if the stacking is no longer needed. |
| Watcher running but the child PR's base never changed when the parent merged | The watcher process died (e.g. machine restart). | `pgrep -af watch-pr.sh` to check; rerun `land-pr.sh <N>`. |
| Child PR merged into the parent's branch instead of main | Automerge was enabled on the child before its base was retargeted (the very footgun this skill exists to prevent). | Follow the recovery in `CLAUDE.md` § "Stacked-PR worktrees: don't accidentally push into the parent PR". |
| Native merge queue is BLOCKED with all PR-level checks green | The queue branch's CI hasn't run, or hasn't passed. Likely the workflow doesn't subscribe to `merge_group:`. | Verify `.github/workflows/ci.yml` has `merge_group:` in `on:`. If a workflow change is needed, push a fix to the same PR (auto-removes from queue), re-enable automerge after CI passes on the new head. |
| `mergeStateStatus: BEHIND` | Branch is behind base; native MQ doesn't auto-rebase. | Either rebase locally + force-push (rebase merge method), or `gh pr update-branch <N>` for merge-commit method. |

## Clean up the worktree once the PR is merged

Wait for the watcher to report that the PR actually merged. Then remove the worktree and delete its local branch.

```bash
git -C <repo> worktree remove .claude/worktrees/<name>
git -C <repo> branch -D <local-branch>
```

**Cleaning up the worktree you're *currently in*.** `git worktree remove` refuses to delete the worktree that is the session's current directory — so if you landed the PR from the active worktree, you must leave it first with `ExitWorktree`, which returns the session to the original checkout:

- **Worktree created by `EnterWorktree`** (the usual case for a task you started in a worktree): call `ExitWorktree` with `action: "remove"` — it leaves *and* deletes the worktree and its branch in one step. Done.
- **Worktree you entered via `EnterWorktree`'s `path:`, or created manually with `git worktree add`:** `ExitWorktree` will *not* delete it (it only removes worktrees it created). Call `ExitWorktree` with `action: "keep"` to return to the original directory, then run the `git worktree remove` / `branch -D` above from there.

Don't try to `git worktree remove` the current worktree by absolute path without exiting first — git rejects removing the checkout the session occupies.

**Skip cleanup only when:**

- There are uncommitted or unpushed changes in the worktree (nothing to recover from if you delete it).
- The watcher has not reported a successful merge.
- `worktree remove` refuses because the tree is dirty; investigate rather than force it.

Do not report the landing task complete merely because `land-pr.sh` returned zero. Tail `.agent-tmp/landing-prs/watch-<N>.log` until it reports either the successful merge or a fix-required terminal state.
