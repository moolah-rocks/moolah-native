#!/usr/bin/env bash
# Verifies the local repo is in a state suitable for cutting a release.
# Exits zero on success, non-zero with a descriptive message on failure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/release-common.sh"

fail() {
    printf '✗ %s\n' "$1" >&2
    exit 1
}

# 1. On main branch.
branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != "main" ]]; then
    fail "must be on main (currently on '$branch')"
fi

# 2. Working tree is clean.
if ! git diff-index --quiet HEAD --; then
    fail "working tree has uncommitted changes"
fi
if [[ -n "$(git ls-files --others --exclude-standard)" ]]; then
    fail "working tree has untracked files"
fi

# 3. In sync with origin/main.
git fetch origin main --quiet
# Sync tags so downstream tag-based logic (e.g. release-next-version) sees the
# same set as origin — otherwise stale local state can produce a wrong "next"
# version. See https://github.com/moolah-rocks/moolah-native/issues/498.
git fetch --tags --prune --force origin --quiet
local_sha=$(git rev-parse HEAD)
remote_sha=$(git rev-parse origin/main)
if [[ "$local_sha" != "$remote_sha" ]]; then
    fail "local main ($local_sha) is not in sync with origin/main ($remote_sha)"
fi

# 4. gh authenticated.
if ! gh auth status >/dev/null 2>&1; then
    fail "gh CLI is not authenticated (run 'gh auth login')"
fi

# 5. CI for the pinned commit passed.
#
# Verify CI for `$local_sha` specifically — not "latest CI on main" — so the
# release locks onto the exact commit the operator preflighted, even if other
# PRs land on main while the release is in flight. A `--branch main --limit 1`
# query chases a moving target: by the time the result comes back, a newer
# commit may have landed and reset the latest CI run to in_progress, looping
# the operator forever. `--commit "$local_sha"` is the SHA-pinned form.
ci_status=$(gh run list --commit "$local_sha" --workflow CI \
    --json status,conclusion --jq '.[0] | "\(.status):\(.conclusion)"' 2>/dev/null || true)
case "$ci_status" in
    completed:success) ;;
    completed:*) fail "CI for $local_sha concluded as ${ci_status#completed:}" ;;
    in_progress:*|queued:*) fail "CI for $local_sha is still running; wait for it to finish" ;;
    "" | "null:null") fail "no CI run found for $local_sha (push it to a branch CI watches, then re-run)" ;;
    *) fail "unexpected CI status '$ci_status' for $local_sha" ;;
esac

printf '✓ release-preflight passed\n'
printf '  branch: %s\n' "$branch"
printf '  HEAD:   %s\n' "$local_sha"
printf '\n'
printf 'Locked SHA: %s\n' "$local_sha"
printf 'All subsequent release commands target this commit. Do NOT `git pull` or\n'
printf '`git fetch` between now and `release-create-rc` — main may move on origin,\n'
printf 'but the tag will pin to local HEAD.\n'
