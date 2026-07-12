#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/landing-prs-tests.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$tmp_dir/bin"

cat >"$tmp_dir/bin/osascript" <<'MOCK'
#!/usr/bin/env bash
exit 0
MOCK

cat >"$tmp_dir/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail

echo "$*" >>"$MOCK_CALLS"

if [[ "$1 $2" == "pr view" ]]; then
  pr="$3"

  if [[ " $* " == *" --jq "* ]]; then
    echo "main"
    exit 0
  fi

  if [[ "$MOCK_SCENARIO" == "failure" ]]; then
    echo "{\"state\":\"OPEN\",\"mergedAt\":null,\"baseRefName\":\"main\",\"mergeStateStatus\":\"BLOCKED\",\"statusCheckRollup\":[{\"conclusion\":\"${MOCK_CONCLUSION:-FAILURE}\"}]}"
    exit 0
  fi

  if [[ "$MOCK_SCENARIO" == "stacked" && "$pr" == "41" ]]; then
    echo '{"state":"MERGED","mergedAt":"2026-07-12T01:00:00Z"}'
    exit 0
  fi

  count=0
  [[ -f "$MOCK_COUNT" ]] && count=$(cat "$MOCK_COUNT")
  count=$((count + 1))
  echo "$count" >"$MOCK_COUNT"

  if [[ "$MOCK_SCENARIO" == "queue-removal" || "$count" -eq 1 ]]; then
    base="main"
    [[ "$MOCK_SCENARIO" == "stacked" ]] && base="feature/parent"
    echo "{\"state\":\"OPEN\",\"mergedAt\":null,\"baseRefName\":\"$base\",\"mergeStateStatus\":\"BLOCKED\",\"statusCheckRollup\":[]}"
  else
    echo '{"state":"MERGED","mergedAt":"2026-07-12T02:00:00Z","baseRefName":"main","mergeStateStatus":"UNKNOWN","statusCheckRollup":[]}'
  fi
  exit 0
fi

if [[ "$1 $2" == "repo view" ]]; then
  echo "owner/repo"
  exit 0
fi

if [[ "$1 $2" == "api graphql" ]]; then
  queue_count=0
  [[ -f "$MOCK_QUEUE_COUNT" ]] && queue_count=$(cat "$MOCK_QUEUE_COUNT")
  queue_count=$((queue_count + 1))
  echo "$queue_count" >"$MOCK_QUEUE_COUNT"

  if [[ "$MOCK_SCENARIO" == "queue-removal" && "$queue_count" -gt 1 ]]; then
    echo "NONE"
  else
    echo "QUEUED"
  fi
  exit 0
fi

if [[ "$1 $2" == "pr merge" || "$1 $2" == "pr edit" ]]; then
  exit 0
fi

echo "unexpected gh invocation: $*" >&2
exit 1
MOCK

chmod +x "$tmp_dir/bin/gh" "$tmp_dir/bin/osascript"

run_watcher() {
  local scenario="$1"
  shift
  : >"$tmp_dir/calls"
  rm -f "$tmp_dir/count" "$tmp_dir/queue-count"
  PATH="$tmp_dir/bin:$PATH" \
    MOCK_SCENARIO="$scenario" \
    MOCK_CALLS="$tmp_dir/calls" \
    MOCK_COUNT="$tmp_dir/count" \
    MOCK_QUEUE_COUNT="$tmp_dir/queue-count" \
    POLL_INTERVAL=0 \
    bash "$script_dir/watch-pr.sh" "$@"
}

regular_output=$(run_watcher regular 42 --automerge-enabled)
grep -q "PR #42 merged successfully" <<<"$regular_output"

mkdir -p "$tmp_dir/work"
: >"$tmp_dir/calls"
rm -f "$tmp_dir/count" "$tmp_dir/queue-count"
land_output=$(
  cd "$tmp_dir/work"
  PATH="$tmp_dir/bin:$PATH" \
    MOCK_SCENARIO=regular \
    MOCK_CALLS="$tmp_dir/calls" \
    MOCK_COUNT="$tmp_dir/count" \
    MOCK_QUEUE_COUNT="$tmp_dir/queue-count" \
    POLL_INTERVAL=0 \
    bash "$script_dir/land-pr.sh" 42
)
grep -q "it will run until PR #42 merges or needs a fix" <<<"$land_output"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -f "$tmp_dir/work/.agent-tmp/landing-prs/watch-42.log" ]] && \
    grep -q "PR #42 merged successfully" "$tmp_dir/work/.agent-tmp/landing-prs/watch-42.log" && break
  sleep 0.1
done
grep -q "PR #42 merged successfully" "$tmp_dir/work/.agent-tmp/landing-prs/watch-42.log"
grep -q "pr merge 42 --auto --rebase" "$tmp_dir/calls"

for conclusion in FAILURE CANCELLED TIMED_OUT ACTION_REQUIRED STARTUP_FAILURE; do
  set +e
  failure_output=$(MOCK_CONCLUSION="$conclusion" run_watcher failure 42 --automerge-enabled 2>&1)
  failure_status=$?
  set -e
  [[ "$failure_status" -eq 1 ]]
  grep -q "Fix the failures, then rerun land-pr.sh" <<<"$failure_output"
done

set +e
queue_output=$(run_watcher queue-removal 42 --automerge-enabled 2>&1)
queue_status=$?
set -e
[[ "$queue_status" -eq 1 ]]
grep -q "removed from the merge queue before merging" <<<"$queue_output"
grep -q "Fix the queue failure, then rerun land-pr.sh" <<<"$queue_output"

stacked_output=$(run_watcher stacked 42 --parent 41)
grep -q "Automerge enabled; continuing to monitor" <<<"$stacked_output"
grep -q "PR #42 merged successfully" <<<"$stacked_output"
grep -q "pr edit 42 --base main" "$tmp_dir/calls"
grep -q "pr merge 42 --auto --rebase" "$tmp_dir/calls"

echo "landing-prs script tests passed"
