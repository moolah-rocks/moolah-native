#!/usr/bin/env bash
# Compatibility wrapper. New callers should use watch-pr.sh directly.

set -euo pipefail

usage() {
  echo "usage: watch-stacked-pr.sh <CHILD-PR> <PARENT-PR> [--repo OWNER/REPO]" >&2
}

positional=()
forwarded=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --repo)
      [[ -n "${2:-}" ]] || { echo "watch-stacked-pr.sh: --repo needs a value" >&2; exit 2; }
      forwarded+=("$1" "$2"); shift 2
      ;;
    --repo=*) forwarded+=("$1"); shift ;;
    -*) echo "watch-stacked-pr.sh: unknown flag '$1'" >&2; exit 2 ;;
    *) positional+=("$1"); shift ;;
  esac
done

[[ ${#positional[@]} -eq 2 ]] || { usage; exit 2; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
exec bash "$script_dir/watch-pr.sh" "${positional[0]}" --parent "${positional[1]}" "${forwarded[@]+"${forwarded[@]}"}"
