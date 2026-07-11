#!/usr/bin/env bash
#
# Explicit local recovery tool for branch-local schema experiments.
# Deletes only the local Development zone. Production paths are rejected by
# resolved-path guards before any removal happens.
set -euo pipefail

fail() {
    echo "error: $*" >&2
    exit 1
}

canonical_dir() {
    local path="$1"
    if [ -d "$path" ]; then
        (cd "$path" && pwd -P)
    else
        local parent
        parent="$(dirname "$path")"
        local name
        name="$(basename "$path")"
        [ -d "$parent" ] || fail "parent directory does not exist: $parent"
        printf '%s/%s\n' "$(cd "$parent" && pwd -P)" "$name"
    fi
}

APP_SUPPORT_ROOT="$HOME/Library/Containers/rocks.moolah.app/Data/Library/Application Support"
DEVELOPMENT_ROOT="$APP_SUPPORT_ROOT/Development"
PRODUCTION_ROOT="$APP_SUPPORT_ROOT/Production"

development_root="$(canonical_dir "$DEVELOPMENT_ROOT")"
production_root="$(canonical_dir "$PRODUCTION_ROOT")"

case "$development_root" in
    "$HOME"/Library/Containers/rocks.moolah.app/Data/Library/Application\ Support/Development) ;;
    *) fail "unexpected Development path: $development_root" ;;
esac

case "$development_root" in
    *Production* | "$production_root" | "$production_root"/*)
        fail "refusing to operate on a Production path: $development_root"
        ;;
esac

if pgrep -f "Moolah.app/Contents/MacOS/Moolah" >/dev/null 2>&1; then
    fail "Moolah is running. Quit it before resetting local Development data."
fi

targets=(
    "$development_root/Moolah"
    "$development_root/Moolah-v2-sync.syncstate"
)

existing_targets=()
for target in "${targets[@]}"; do
    case "$target" in
        "$development_root"/*) ;;
        *) fail "refusing to remove path outside Development: $target" ;;
    esac
    if [ -e "$target" ]; then
        existing_targets+=("$target")
    fi
done

cat <<EOF
This will permanently delete local Moolah Development data:

Zone: Development
Development path:
  $development_root

Will delete:
EOF

if [ "${#existing_targets[@]}" -eq 0 ]; then
    echo "  (nothing exists)"
else
    for target in "${existing_targets[@]}"; do
        echo "  $target"
    done
fi

cat <<EOF

Will not touch:
  $production_root

Development backups under Development/Moolah/Backups are deleted too.
EOF

for target in "${existing_targets[@]}"; do
    rm -rf "$target"
done

mkdir -p "$development_root"
echo "Development local Moolah data reset."
