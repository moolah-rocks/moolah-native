---
name: cutting-a-release
description: Use when cutting a release candidate, promoting an RC to a final release, or when the user asks to "ship a release" / "tag a release". Drafts user-facing release notes per BRAND_GUIDE.md and walks through the procedure in guides/RELEASE_GUIDE.md.
---

# Cutting a Release

The procedure is in [`guides/RELEASE_GUIDE.md`](../../../guides/RELEASE_GUIDE.md). Follow it step by step. Each step there names a `just` target — run that target via the Bash tool. Don't restate or paraphrase the procedure here; the runbook is the source of truth.

## What's special about doing this with AI assistance

The runbook is written so a human can execute it solo. The reasons a human might invoke this skill rather than running the runbook themselves are:

1. **Drafting release notes.** This is the step that benefits most from analysis: read merged PRs since `notes_base`, read the diffs that actually shipped, separate user-facing changes from internal ones, and write something that respects `guides/BRAND_GUIDE.md`.
2. **Surfacing surprises during the run.** If `release-preflight` fails, if `release-wait` reports a workflow failure, or if `release-status` shows missing assets, summarise the situation and propose a recovery path from the runbook's Recovery section.
3. **Surfacing the schema-deploy gate.** If the workflow pauses on `await-prod-deploy`, the user needs to manually click Deploy in the CloudKit Console (per the runbook's "Schema deploys" section) and then approve the GH workflow run. Tell them the workflow has paused, point them at the Console, and wait. Don't try to bypass the gate.
4. **Landing the baseline-schema PR.** When the `await-prod-deploy` gate fired, the RC build opens a bot PR that refreshes `schema-prod-baseline.ckdb`. CI does not run on it by itself and it will not merge on its own — see "Landing the baseline-schema PR" below.

Everything else is just running `just` targets in order.

## Release notes — operational notes

When the runbook says "Author release notes", do this:

1. Run `just release-next-version <kind>` and read `notes_base` from the JSON.
2. Gather the changeset:
   - `gh pr list --state merged --base main --search "merged:>=$(git -C . log -1 --format=%aI <notes_base>)"` for merged PRs in the window.
   - `git -C . log <notes_base>..HEAD --oneline` for the full commit list.
   - For any PR that looks substantive, read its body via `gh pr view <number> --json title,body,labels`.
3. Read `guides/BRAND_GUIDE.md` once per session before drafting (don't rely on memory of the voice rules).
4. Write the draft to `.agent-tmp/release-notes-<version>.md`. Show it to the user. Iterate on their feedback. Only call `just release-create-rc` / `just release-create-final` after they approve the notes.

The runbook's "Authoring release notes" section governs scope, filtering, and voice for both AI and human authors — re-read it before drafting; don't paraphrase the rules from memory.

## Landing the baseline-schema PR (only when the schema was deployed)

This only happens when this release deployed a CloudKit schema change (the `await-prod-deploy` gate fired). The RC build's final step opens a PR titled `chore(cloudkit): refresh schema-prod-baseline after deploy`, authored by the `github-actions` bot, updating `CloudKit/schema-prod-baseline.ckdb` to record the schema now live in Production.

**CI never runs on this PR on its own.** The bot pushes the branch with `GITHUB_TOKEN`, and GitHub suppresses workflow triggers from token-authored pushes — so its required checks (`Test`, `UI Test`, `CloudKit schema additivity`) never start, and it sits open forever. (This is why old baseline PRs pile up unmerged.) You have to trigger CI yourself, then land it.

### 1. Verify it is exactly the baseline update — and nothing else

This is a hard gate. Do **not** proceed unless **both** hold; if either fails, stop, surface it to the user, and don't land the PR:

- **Only one file changed.** `gh pr view <N> --repo moolah-rocks/moolah-native --json files` must show exactly `CloudKit/schema-prod-baseline.ckdb` and nothing else.
- **It matches the schema shipped at the tag.** The new baseline must reflect `CloudKit/schema.ckdb` as of the released tag's commit — i.e. the diff adds exactly the record types / fields this release introduced and deployed (the same diff reviewed in the CloudKit Console at the `await-prod-deploy` gate), and adds nothing the tag's schema doesn't contain.

  ```bash
  gh pr diff <N> --repo moolah-rocks/moolah-native   # the additions the PR makes to the baseline
  git -C . show v<version>:CloudKit/schema.ckdb       # the canonical schema that shipped at the tag
  ```

  Cross-check: every record type / field added by the PR must appear in the tag's `schema.ckdb`, and the PR must add nothing extra. If they disagree, the baseline is being updated to something other than what was deployed — stop.

### 2. Trigger CI on the PR's commit

`ci.yml` runs `on: push` for `mq-spec-*` branches (the documented "CI without a PR" path). Push the PR's **exact head commit** to an `mq-spec-*` branch under your own credentials — that re-triggers CI, and because check runs attach to the commit SHA (which the PR shares), they satisfy the PR's required checks:

```bash
SHA=$(gh pr view <N> --repo moolah-rocks/moolah-native --json headRefOid -q .headRefOid)
git -C . fetch origin <pr-head-branch>
git -C . rev-parse FETCH_HEAD                                # must equal $SHA
git -C . push origin "$SHA:refs/heads/mq-spec-baseline-<version>"
```

The `main` ruleset has `strict_required_status_checks_policy: false`, so the PR need not be up to date with `main`; the checks on its current SHA are sufficient and there's no rebase-to-an-unchecked-SHA deadlock.

### 3. Enable auto-merge and let the queue land it

```bash
gh pr merge <N> --repo moolah-rocks/moolah-native --auto
```

`main` uses GitHub's native merge queue, so the merge method is the queue's (a `--rebase` / `--squash` flag is ignored — expected; you may see "The merge strategy for main is set by the merge queue"). Once the shared-SHA checks go green the PR is added to the queue (`isInMergeQueue: true`, `AWAITING_CHECKS`), the queue runs its own `merge_group` CI pass on a `gh-readonly-queue/*` branch, then merges.

### 4. Clean up after it merges

Delete the throwaway branch you pushed, on origin and locally:

```bash
git -C . push origin --delete mq-spec-baseline-<version>
git -C . update-ref -d refs/remotes/origin/<pr-head-branch>   # the remote-tracking ref left by the fetch
```

The PR's own head branch is auto-deleted by the merge queue.

## When something goes wrong

Point at the relevant heading under "Recovery" in the runbook. Don't invent recovery procedures the runbook doesn't sanction. If something genuinely doesn't fit any recovery case, surface that to the user and ask before acting — the runbook is conservative on purpose (e.g. it says never delete a tag).

## Hand-off

- After an RC: tell the user how to install the TestFlight build and the Mac zip (extract, drag `Moolah.app` to `/Applications`), and what to look for in smoke-testing.
- After a final: tell the user the App Store submission has been made (auto-release after approval) and that the bump PR is in flight; remind them to edit `project.yml` in the PR if they want a non-default bump.
