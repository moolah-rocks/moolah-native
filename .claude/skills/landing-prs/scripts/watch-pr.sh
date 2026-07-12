#!/usr/bin/env bash
#
# watch-pr.sh — monitor a PR until it merges, optionally waiting for a
# stacked parent before retargeting and enabling automerge.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: watch-pr.sh <PR> [--parent PARENT-PR] [--automerge-enabled] [--repo OWNER/REPO]

  Polls until the PR actually merges. For a stacked PR, waits for the parent,
  retargets the child to main, enables automerge, and then keeps monitoring.

  Terminal states (with exit codes):
    PR merged          -> success                            -> exit 0
    PR closed          -> cannot proceed                     -> exit 1
    PR CI failed       -> fix failures and rerun land-pr.sh  -> exit 1
    PR conflict        -> fix conflict and rerun land-pr.sh  -> exit 1
    Parent closed      -> cannot proceed                     -> exit 1
USAGE
}

PR=""
PARENT=""
REPO=""
AUTOMERGE_ENABLED=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --parent)
      [[ -n "${2:-}" ]] || { echo "watch-pr.sh: --parent needs a value" >&2; exit 2; }
      PARENT="$2"; shift 2
      ;;
    --parent=*) PARENT="${1#--parent=}"; shift ;;
    --automerge-enabled) AUTOMERGE_ENABLED=true; shift ;;
    --repo)
      [[ -n "${2:-}" ]] || { echo "watch-pr.sh: --repo needs a value" >&2; exit 2; }
      REPO="$2"; shift 2
      ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    -*) echo "watch-pr.sh: unknown flag '$1'" >&2; exit 2 ;;
    *)
      [[ -z "$PR" ]] || { echo "watch-pr.sh: unexpected extra argument '$1'" >&2; exit 2; }
      PR="$1"; shift
      ;;
  esac
done

[[ -n "$PR" ]] || { usage >&2; exit 2; }
[[ "$PR" =~ ^[0-9]+$ ]] || { echo "watch-pr.sh: PR must be a number" >&2; exit 2; }
[[ -z "$PARENT" || "$PARENT" =~ ^[0-9]+$ ]] || { echo "watch-pr.sh: PARENT-PR must be a number" >&2; exit 2; }

REPO_FLAG=()
[[ -n "$REPO" ]] && REPO_FLAG=(--repo "$REPO")

if [[ -n "$REPO" ]]; then
  REPO_NAME_WITH_OWNER="$REPO"
else
  REPO_NAME_WITH_OWNER=$(gh repo view --json nameWithOwner --jq '.nameWithOwner')
fi

if [[ "$REPO_NAME_WITH_OWNER" != */* ]]; then
  echo "watch-pr.sh: could not resolve repository owner/name" >&2
  exit 1
fi

REPO_OWNER="${REPO_NAME_WITH_OWNER%%/*}"
REPO_NAME="${REPO_NAME_WITH_OWNER#*/}"

# The guarded expansion is required for macOS bash 3.2 with `set -u`.
POLL_INTERVAL="${POLL_INTERVAL:-60}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

notify() {
  local msg="$1"
  log "NOTIFY: $msg"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"Landing PR #$PR\"" 2>/dev/null || true
  fi
}

# Treat an individual gh failure as transient rather than abandoning a merge.
fetch_pr_json() {
  local pr="$1"
  local fields="$2"
  local out
  if out=$(gh pr view "$pr" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --json "$fields" 2>/dev/null); then
    echo "$out"
  else
    echo ""
  fi
}

fetch_queue_state() {
  local out
  if out=$(gh api graphql \
    -f query="query(\$owner: String!, \$name: String!, \$number: Int!) { repository(owner: \$owner, name: \$name) { pullRequest(number: \$number) { mergeQueueEntry { state } } } }" \
    -f owner="$REPO_OWNER" \
    -f name="$REPO_NAME" \
    -F number="$PR" \
    --jq '.data.repository.pullRequest.mergeQueueEntry.state // "NONE"' \
    2>/dev/null); then
    echo "$out"
  else
    echo ""
  fi
}

if [[ -n "$PARENT" ]]; then
  log "Watching parent PR #$PARENT -> PR #$PR (poll every ${POLL_INTERVAL}s)"
else
  log "Watching PR #$PR until it merges (poll every ${POLL_INTERVAL}s)"
fi

QUEUE_OBSERVED=false
QUEUE_MISSING_TICKS=0

while true; do
  pr_json=$(fetch_pr_json "$PR" 'state,mergedAt,baseRefName,mergeStateStatus,statusCheckRollup')
  parent_json=""
  queue_state=""
  if [[ -n "$PARENT" && "$AUTOMERGE_ENABLED" == false ]]; then
    parent_json=$(fetch_pr_json "$PARENT" 'state,mergedAt')
  fi

  if [[ "$AUTOMERGE_ENABLED" == true ]]; then
    queue_state=$(fetch_queue_state)
  fi

  if [[ -z "$pr_json" || \
    ( -n "$PARENT" && "$AUTOMERGE_ENABLED" == false && -z "$parent_json" ) || \
    ( "$AUTOMERGE_ENABLED" == true && -z "$queue_state" ) ]]; then
    log "gh fetch hiccup; will retry next tick"
    sleep "$POLL_INTERVAL"
    continue
  fi

  pr_state=$(jq -r '.state // "UNKNOWN"' <<<"$pr_json")
  pr_merged_at=$(jq -r '.mergedAt // empty' <<<"$pr_json")
  pr_base=$(jq -r '.baseRefName // ""' <<<"$pr_json")
  pr_merge_state=$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"$pr_json")
  failed_checks=$(jq -r '[.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT" or .conclusion == "ACTION_REQUIRED" or .conclusion == "STARTUP_FAILURE")] | length' <<<"$pr_json")

  if [[ -n "$pr_merged_at" ]]; then
    notify "PR #$PR merged successfully at $pr_merged_at."
    exit 0
  fi

  if [[ "$pr_state" == "CLOSED" ]]; then
    notify "PR #$PR closed without merging. Fix the PR state, then rerun land-pr.sh."
    exit 1
  fi

  if [[ "$failed_checks" -gt 0 ]]; then
    notify "PR #$PR has CI failures. Fix the failures, then rerun land-pr.sh."
    exit 1
  fi

  if [[ "$pr_merge_state" == "DIRTY" ]]; then
    notify "PR #$PR has merge conflicts. Fix the conflicts, then rerun land-pr.sh."
    exit 1
  fi

  if [[ "$AUTOMERGE_ENABLED" == true ]]; then
    if [[ "$queue_state" == "UNMERGEABLE" ]]; then
      notify "PR #$PR is unmergeable in the merge queue. Fix the queue failure, then rerun land-pr.sh."
      exit 1
    elif [[ "$queue_state" != "NONE" ]]; then
      QUEUE_OBSERVED=true
      QUEUE_MISSING_TICKS=0
    elif [[ "$QUEUE_OBSERVED" == true ]]; then
      QUEUE_MISSING_TICKS=$((QUEUE_MISSING_TICKS + 1))
      if [[ "$QUEUE_MISSING_TICKS" -ge 2 ]]; then
        notify "PR #$PR was removed from the merge queue before merging. Fix the queue failure, then rerun land-pr.sh."
        exit 1
      fi
      log "Merge-queue entry disappeared; confirming PR state next tick"
    fi
  fi

  if [[ -n "$PARENT" && "$AUTOMERGE_ENABLED" == false ]]; then
    parent_state=$(jq -r '.state // "UNKNOWN"' <<<"$parent_json")
    parent_merged_at=$(jq -r '.mergedAt // empty' <<<"$parent_json")

    if [[ -n "$parent_merged_at" ]]; then
      log "Parent #$PARENT merged at $parent_merged_at; proceeding"

      if [[ "$pr_base" != "main" && "$pr_base" != "master" ]]; then
        log "Retargeting PR #$PR: base '$pr_base' -> main"
        if ! gh pr edit "$PR" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --base main >/dev/null 2>&1; then
          notify "Retargeting PR #$PR failed. Fix it manually, then rerun land-pr.sh."
          exit 1
        fi
      fi

      log "Enabling automerge on PR #$PR"
      if ! gh pr merge "$PR" ${REPO_FLAG[@]+"${REPO_FLAG[@]}"} --auto --rebase >/dev/null 2>&1; then
        notify "Enabling automerge on PR #$PR failed. Fix it manually, then rerun land-pr.sh."
        exit 1
      fi

      AUTOMERGE_ENABLED=true
      log "Automerge enabled; continuing to monitor until PR #$PR actually merges"
    elif [[ "$parent_state" == "CLOSED" ]]; then
      notify "Parent #$PARENT closed without merging. Fix the stack, then rerun land-pr.sh."
      exit 1
    else
      log "Waiting: parent=$parent_state pr=$pr_state base=$pr_base merge_state=$pr_merge_state"
    fi
  else
    log "Waiting to merge: state=$pr_state base=$pr_base merge_state=$pr_merge_state"
  fi

  sleep "$POLL_INTERVAL"
done
