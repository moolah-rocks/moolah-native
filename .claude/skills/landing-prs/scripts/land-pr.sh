#!/usr/bin/env bash
#
# land-pr.sh — land a PR via GitHub's native merge queue.
#
# Detects whether the PR targets main (queue directly) or a feature branch
# (kicks off a background watcher that auto-retargets + auto-enqueues once
# the parent merges). See SKILL.md alongside this script for details.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: land-pr.sh <PR> [--repo OWNER/REPO]

  PR              Pull request number to land.
  --repo          Repository in OWNER/REPO form. Defaults to the gh CLI's
                  current-context repo.

Behaviour:
  base == main:    enables automerge (rebase) immediately. Exits.
  base != main:    finds the parent PR (the open PR whose head matches the
                   child's base), starts watch-stacked-pr.sh under nohup,
                   and exits. The watcher retargets the child to main and
                   enables automerge once the parent merges.

Exit codes:
  0   success (automerge enabled, or watcher backgrounded)
  1   couldn't find a parent PR for a stacked child
  2   usage error
USAGE
}

PR=""
REPO=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo)
      [[ -n "${2:-}" ]] || { echo "land-pr.sh: --repo needs a value" >&2; exit 2; }
      REPO="$2"; shift 2
      ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    -*) echo "land-pr.sh: unknown flag '$1'" >&2; usage >&2; exit 2 ;;
    *)
      [[ -z "$PR" ]] || { echo "land-pr.sh: unexpected extra argument '$1'" >&2; exit 2; }
      PR="$1"; shift
      ;;
  esac
done

[[ -n "$PR" ]] || { usage >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "land-pr.sh: PR must be a number, got '$PR'" >&2; exit 2; }

REPO_FLAG=()
[[ -n "$REPO" ]] && REPO_FLAG=(--repo "$REPO")

# `${REPO_FLAG[@]+"${REPO_FLAG[@]}"}` — guard required because macOS ships
# bash 3.2, where `set -u` treats `"${arr[@]}"` of an empty array as
# "unbound variable". The `+` form returns the alternate value only when
# the array has at least one element, and produces zero positional args
# otherwise. Bash 4.4+ handles the unguarded form, but we cannot rely on
# Homebrew bash being on PATH.

# Resolve the PR's base. gh exits non-zero if the PR doesn't exist.
base=$(gh pr view "$PR" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --json baseRefName --jq '.baseRefName')

if [[ "$base" == "main" || "$base" == "master" ]]; then
  echo "PR #$PR targets '$base' → enabling automerge (rebase)."
  # The merge method is overridden by the queue's configured method on this
  # repo (REBASE), but we pass --rebase to be explicit. gh prints a harmless
  # warning if it conflicts; we don't gate on it.
  gh pr merge "$PR" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --auto --rebase
  echo "Done. Native merge queue will land it when checks pass."
  exit 0
fi

echo "PR #$PR targets '$base' (stacked) — looking up parent PR."

# Find the open PR whose head ref matches the child's base ref.
parent=$(gh pr list ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --head "$base" --state open --json number --jq '.[0].number // empty')

if [[ -z "$parent" ]]; then
  cat >&2 <<EOF
land-pr.sh: no open PR found whose head is '$base'.

The child PR (#$PR) targets a branch that doesn't have an open parent PR.
Either:
  - Open the parent PR first, then re-run this script, OR
  - If the stacking is no longer needed, retarget the child to main with:
      gh pr edit $PR ${REPO_FLAG[*]:-} --base main
    then re-run this script.
EOF
  exit 1
fi

echo "Parent: PR #$parent → child: PR #$PR"

# Background the watcher. State / logs in .agent-tmp/landing-prs/ (gitignored).
script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
log_dir=".agent-tmp/landing-prs"
mkdir -p "$log_dir"
log_file="$log_dir/watch-$PR.log"

watcher_args=("$PR" "$parent")
[[ -n "$REPO" ]] && watcher_args+=(--repo "$REPO")

nohup bash "$script_dir/watch-stacked-pr.sh" "${watcher_args[@]}" \
  >"$log_file" 2>&1 &
watcher_pid=$!

# Detach from the parent shell so the watcher survives session exit.
disown "$watcher_pid" 2>/dev/null || true

echo "Watcher started (PID=$watcher_pid)."
echo "Log: $log_file"
echo "Tail with: tail -f $log_file"
echo "Cancel with: kill $watcher_pid  (or: pkill -f 'watch-stacked-pr.sh $PR ')"
