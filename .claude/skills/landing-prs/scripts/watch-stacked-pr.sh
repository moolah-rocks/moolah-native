#!/usr/bin/env bash
#
# watch-stacked-pr.sh — wait for a parent PR to merge, then auto-retarget
# the child PR to main and enable automerge on it.
#
# Not normally invoked directly; land-pr.sh starts it via nohup. See the
# adjacent SKILL.md for the full procedure.

set -euo pipefail

usage() {
  cat <<'USAGE'
usage: watch-stacked-pr.sh <CHILD-PR> <PARENT-PR> [--repo OWNER/REPO]

  Polls every 60s. Emits status lines to stdout. On terminal state, sends a
  desktop notification (osascript on macOS; falls back to log-only) and exits.

  Terminal states (with exit codes):
    Parent merged       → retarget child + enable automerge → exit 0
    Parent closed       → cannot proceed                    → exit 1
    Child merged        → nothing left to do                → exit 0
    Child closed        → user gave up                      → exit 0
    Child CI failed     → user needs to fix                 → exit 1
    Child conflict      → user needs to rebase              → exit 1
USAGE
}

CHILD=""
PARENT=""
REPO=""

# Positional args first, then flags. Accept --repo anywhere.
positional=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo)
      [[ -n "${2:-}" ]] || { echo "watch-stacked-pr.sh: --repo needs a value" >&2; exit 2; }
      REPO="$2"; shift 2
      ;;
    --repo=*) REPO="${1#--repo=}"; shift ;;
    -*) echo "watch-stacked-pr.sh: unknown flag '$1'" >&2; exit 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done

[[ ${#positional[@]} -eq 2 ]] || { usage >&2; exit 2; }
CHILD="${positional[0]}"
PARENT="${positional[1]}"

[[ "$CHILD" =~ ^[0-9]+$ ]] || { echo "watch-stacked-pr.sh: CHILD-PR must be a number" >&2; exit 2; }
[[ "$PARENT" =~ ^[0-9]+$ ]] || { echo "watch-stacked-pr.sh: PARENT-PR must be a number" >&2; exit 2; }

REPO_FLAG=()
[[ -n "$REPO" ]] && REPO_FLAG=(--repo "$REPO")

POLL_INTERVAL="${POLL_INTERVAL:-60}"

log() {
  echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*"
}

notify() {
  local msg="$1"
  log "NOTIFY: $msg"
  if command -v osascript >/dev/null 2>&1; then
    osascript -e "display notification \"$msg\" with title \"Landing PR #$CHILD\"" 2>/dev/null || true
  fi
}

# Robust fetch: gh occasionally hiccups; treat single failures as transient.
fetch_pr_json() {
  local pr="$1"
  local fields="$2"
  local out
  if out=$(gh pr view "$pr" "${REPO_FLAG[@]}" --json "$fields" 2>/dev/null); then
    echo "$out"
  else
    echo ""  # Empty = "unknown this tick"; caller continues polling.
  fi
}

log "Watching parent PR #$PARENT → child PR #$CHILD (poll every ${POLL_INTERVAL}s)"

while true; do
  parent_json=$(fetch_pr_json "$PARENT" 'state,mergedAt')
  child_json=$(fetch_pr_json "$CHILD" 'state,mergedAt,baseRefName,mergeStateStatus,statusCheckRollup')

  if [[ -z "$parent_json" || -z "$child_json" ]]; then
    log "gh fetch hiccup; will retry next tick"
    sleep "$POLL_INTERVAL"
    continue
  fi

  parent_state=$(jq -r '.state // "UNKNOWN"' <<<"$parent_json")
  parent_merged_at=$(jq -r '.mergedAt // empty' <<<"$parent_json")

  child_state=$(jq -r '.state // "UNKNOWN"' <<<"$child_json")
  child_merged_at=$(jq -r '.mergedAt // empty' <<<"$child_json")
  child_base=$(jq -r '.baseRefName // ""' <<<"$child_json")
  child_merge_state=$(jq -r '.mergeStateStatus // "UNKNOWN"' <<<"$child_json")
  child_failed_checks=$(jq -r '[.statusCheckRollup[]? | select(.conclusion == "FAILURE" or .conclusion == "CANCELLED" or .conclusion == "TIMED_OUT" or .conclusion == "ACTION_REQUIRED")] | length' <<<"$child_json")

  # --- Child-side terminal states first (exit immediately if any apply) ---

  if [[ -n "$child_merged_at" ]]; then
    notify "Child #$CHILD already merged. Nothing to do."
    exit 0
  fi

  if [[ "$child_state" == "CLOSED" ]]; then
    notify "Child #$CHILD closed unmerged. Exiting."
    exit 0
  fi

  if [[ "$child_failed_checks" -gt 0 ]]; then
    notify "Child #$CHILD has CI failures. Fix and re-run land-pr.sh."
    exit 1
  fi

  if [[ "$child_merge_state" == "DIRTY" ]]; then
    notify "Child #$CHILD has merge conflicts. Rebase and re-run land-pr.sh."
    exit 1
  fi

  # --- Parent-side state ---

  if [[ -n "$parent_merged_at" ]]; then
    log "Parent #$PARENT merged at $parent_merged_at — proceeding"

    if [[ "$child_base" != "main" && "$child_base" != "master" ]]; then
      log "Retargeting child #$CHILD: base '$child_base' → main"
      if ! gh pr edit "$CHILD" "${REPO_FLAG[@]}" --base main >/dev/null 2>&1; then
        notify "Retarget of #$CHILD failed. Manual intervention needed."
        exit 1
      fi
      log "Retargeted #$CHILD to main"
    else
      log "Child #$CHILD already targets '$child_base'; no retarget needed"
    fi

    log "Enabling automerge on #$CHILD"
    if ! gh pr merge "$CHILD" "${REPO_FLAG[@]}" --auto --rebase >/dev/null 2>&1; then
      notify "Failed to enable automerge on #$CHILD. Manual intervention needed."
      exit 1
    fi

    notify "Child #$CHILD retargeted to main + automerge enabled."
    exit 0
  fi

  if [[ "$parent_state" == "CLOSED" ]]; then
    notify "Parent #$PARENT closed unmerged. Child #$CHILD can't auto-proceed."
    exit 1
  fi

  # Still waiting — log a heartbeat and sleep
  log "Waiting: parent=$parent_state child=$child_state child_base=$child_base child_merge_state=$child_merge_state"
  sleep "$POLL_INTERVAL"
done
