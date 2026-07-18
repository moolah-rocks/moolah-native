#!/usr/bin/env bash
# Run XCUITest UI tests on native macOS (no simulator).
#
# Usage: test-ui.sh [FILTER ...]
#   FILTERs follow the same convention as scripts/test.sh: pass a class name
#   (`UITestingLaunchSmokeTests`) or class/method
#   (`UITestingLaunchSmokeTests/testAppLaunchesWithTradeBaselineSeed`) to
#   narrow the run. The `MoolahUITests_macOS` prefix is added automatically;
#   pass a fully-qualified `MoolahUITests_macOS/Class[/method]` form to skip
#   the prefix.
#
# UI tests are macOS-only (see guides/UI_TEST_GUIDE.md §1) and run through
# the dedicated `Moolah-macOS-UITests` scheme. Output flows directly to the
# terminal; tee it to `.agent-tmp/test-ui.txt` from the caller if you want to
# inspect failures without re-running.
set -euo pipefail

# `AppleKeyboardUIMode` is a host-global preference. Re-exec under one
# advisory lock so concurrent UI-test runs from sibling worktrees cannot
# restore the preference while another run still needs it. `lockf` releases
# the lock automatically if either process exits or is killed; `-k` keeps the
# lock file so acquisition ordering remains deterministic.
if [ "${MOOLAH_UI_TEST_KEYBOARD_LOCK_HELD:-0}" != 1 ]; then
    export MOOLAH_UI_TEST_KEYBOARD_LOCK_HELD=1
    exec /usr/bin/lockf -k -w /private/tmp/moolah-ui-test-keyboard-mode.lock "$0" "$@"
fi

# Disable nested sandboxing when running inside sandvault; xcodebuild creates
# its own sandbox and fails when already running inside one.
export SWIFTPM_DISABLE_SANDBOX=1
export SWIFT_BUILD_USE_SANDBOX=0

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

COMMON_ARGS=(
    -IDEPackageSupportDisableManifestSandbox=1
    -IDEPackageSupportDisablePackageSandbox=1
    'OTHER_SWIFT_FLAGS=$(inherited) -disable-sandbox'
)

FILTERS=("$@")

filter_flags=()
for f in ${FILTERS[@]+"${FILTERS[@]}"}; do
    if [[ "$f" == MoolahUITests_macOS/* ]]; then
        filter_flags+=("-only-testing:$f")
    else
        filter_flags+=("-only-testing:MoolahUITests_macOS/$f")
    fi
done

echo "==> Running UI tests on native macOS…"
# Per-worktree derived data lives under the worktree's own `.agent-tmp/`
# so two parallel agents running UI tests from sibling worktrees can't
# collide on the same `Moolah.app` bundle. A shared path (the previous
# `/tmp/moolah-derived-data-ui` default) silently let two `xcodebuild test`
# invocations launch the SAME `rocks.moolah.app` bundle, after which one
# test's seed would bleed into the other's accessibility tree. CI overrides
# this via `DERIVED_DATA_PATH` and runs on fresh runners, so there is no
# regression there.
DERIVED_DATA_PATH="${DERIVED_DATA_PATH:-$REPO_ROOT/.agent-tmp/derived-data-ui}"
mkdir -p "$DERIVED_DATA_PATH"

# Capture xcodebuild output so we can both print it live and scan it for
# `[MoolahUITestCase] ARTEFACT_DIR` lines on failure (the runner is
# sandboxed and writes artefacts to /private/tmp/MoolahUITests/...).
LOG_FILE="$(mktemp)"

# Button and pop-up controls only participate in the macOS Tab loop when
# Keyboard Navigation (Full Keyboard Access) is enabled. CI runners use the
# default text-fields-only mode, which makes keyboard UI tests fail before
# their action is reached. Set the global preference for this test process and
# restore the developer's exact prior state on every exit path.
KEYBOARD_UI_MODE_WAS_SET=false
KEYBOARD_UI_MODE_VALUE=""
if KEYBOARD_UI_MODE_VALUE="$(defaults read -g AppleKeyboardUIMode 2>/dev/null)"; then
    KEYBOARD_UI_MODE_WAS_SET=true
fi

cleanup() {
    rm -f "$LOG_FILE"
    if [ "$KEYBOARD_UI_MODE_WAS_SET" = true ]; then
        defaults write -g AppleKeyboardUIMode -int "$KEYBOARD_UI_MODE_VALUE"
    else
        defaults delete -g AppleKeyboardUIMode >/dev/null 2>&1 || true
    fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

defaults write -g AppleKeyboardUIMode -int 2

set +e
xcodebuild test "${COMMON_ARGS[@]}" \
    -derivedDataPath "$DERIVED_DATA_PATH" \
    -scheme Moolah-macOS-UITests \
    -destination "platform=macOS" \
    ${filter_flags[@]+"${filter_flags[@]}"} \
    | tee "$LOG_FILE"
EXIT_CODE=${PIPESTATUS[0]}
set -e

# Mirror any captured artefact directories back into the repo's .agent-tmp/
# so they survive after $TMPDIR cleanup.
mkdir -p "$REPO_ROOT/.agent-tmp"
copied=0
while IFS= read -r src; do
    [ -d "$src" ] || continue
    dest="$REPO_ROOT/.agent-tmp/$(basename "$src")"
    rm -rf "$dest"
    cp -R "$src" "$dest"
    copied=$((copied + 1))
    echo "==> mirrored artefacts: $dest"
done < <(grep -oE '\[MoolahUITestCase\] ARTEFACT_DIR [^ ]+' "$LOG_FILE" \
    | awk '{print $3}' | sort -u)

if [ "$EXIT_CODE" -eq 0 ]; then
    echo ""
    echo "==> UI tests passed."
else
    echo ""
    echo "==> UI tests FAILED (exit $EXIT_CODE). $copied artefact dir(s) copied to .agent-tmp/."
    exit "$EXIT_CODE"
fi
