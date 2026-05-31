#!/usr/bin/env bash
# Installs the build/lint toolchain at pinned, reproducible versions for CI.
#
# Why pin: CI previously ran `brew install xcodegen swift-format swiftlint`,
# which resolves to whatever bottle the GitHub runner image happens to ship.
# That version floats independently of what a developer has locally, so
# `just format-check` could pass locally and fail in CI (or vice versa) the
# moment SwiftLint changed a rule — exactly what bit us when local SwiftLint
# moved ahead of the runner's cached bottle.
#
# How it works: each tool is pinned to an exact version by downloading the
# matching Homebrew bottle directly from the ghcr.io registry, addressed by
# its sha256 (the digest baked into the homebrew-core formula). Bottles are
# prebuilt binaries — no source build — and these three are all
# `:any_skip_relocation`, so they run unmodified from wherever we extract
# them. The sha256 is the integrity check: a tampered or wrong blob fails to
# verify. This avoids both `brew install <url>` (removed in Homebrew 5.x) and
# `brew extract` (strips the bottle, forcing a slow source build).
#
# Platform: the pinned digests are the `arm64_tahoe` bottles — the macOS 26
# Apple-Silicon runners CI uses (and local Apple-Silicon dev machines on
# macOS 26). Developers normally get these versions from `brew`; this script
# exists so CI is deterministic.
#
# To bump a tool:
#   1. Open the homebrew-core formula at the desired version, e.g.
#        https://github.com/Homebrew/homebrew-core/blob/master/Formula/s/swiftlint.rb
#   2. Copy the `arm64_tahoe` sha256 from its `bottle do` block and the
#      version, and update the matching PINNED_TOOLS entry below.
#   3. `brew upgrade <tool>` locally so your machine matches, then re-run
#      `just format-check`.
#
# `just` itself is intentionally NOT pinned — it is the task runner, not a
# linter/generator, and its output does not gate `format-check`. It is always
# ensured present (via brew) so CI steps that call `just` work.
#
# Usage:
#   install-ci-tools.sh                 # just + all pinned tools (CI default)
#   install-ci-tools.sh xcodegen        # just + only the named pinned tool(s)
#
# Release workflows that only generate the project pass `xcodegen` so they
# pin the project generator without pulling in the linters they never run.

set -euo pipefail

# name | version | arm64_tahoe bottle sha256 (from the homebrew-core formula)
PINNED_TOOLS=(
  "swiftlint|0.63.3|9543efe7eb3d5c29413789fda02c3f8d70e4df5e3e4c4f8272dc6497be286aab"
  "swift-format|602.0.0|df0fdcc1a40fd5424122f4db14f70df46b02de3b9046943e4155b560e79ae0df"
  "xcodegen|2.45.4|f8763683b5538a556ac4de3a86132558a086fdd976ac4088ff87d09fae1982b5"
)

# Where extracted bottles live. Each lands at $TOOLS_DIR/<name>/<version>/bin.
TOOLS_DIR="${CI_TOOLS_DIR:-$HOME/.cache/moolah-ci-tools}"

# Reports the version a tool binary prints, normalised to a bare value so it
# can be compared against the pinned string (xcodegen prints "Version: x").
tool_version() {
  local name="$1" bin="$2"
  case "$name" in
    swiftlint) "$bin" version ;;
    swift-format) "$bin" --version ;;
    xcodegen) "$bin" --version | sed -E 's/^Version:[[:space:]]*//' ;;
    *) echo "unknown tool: $name" >&2; return 1 ;;
  esac
}

# Returns 0 if the named tool should be installed for this invocation: with no
# filter arguments every pinned tool is selected; otherwise only those named.
selected() {
  [ "$#" -eq 1 ] && return 0  # only the candidate name passed → no filter args
  local candidate="$1"; shift
  for want in "$@"; do [ "$want" = "$candidate" ] && return 0; done
  return 1
}

# Downloads and extracts a Homebrew bottle from ghcr.io by sha256, verifying
# the digest. Echoes the absolute bin directory of the extracted tool.
install_bottle() {
  local name="$1" version="$2" sha="$3"
  # The bottle tarball already contains a top-level <name>/<version>/ prefix,
  # so it is extracted into TOOLS_DIR directly.
  local bindir="$TOOLS_DIR/$name/$version/bin"

  if [ ! -x "$bindir/$name" ]; then
    mkdir -p "$TOOLS_DIR"
    local token
    token="$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:homebrew/core/$name:pull" \
      | python3 -c "import sys,json; print(json.load(sys.stdin)['token'])")"

    local tarball="$TOOLS_DIR/.bottle-$name.tar.gz"
    curl -fsSL -H "Authorization: Bearer $token" \
      "https://ghcr.io/v2/homebrew/core/$name/blobs/sha256:$sha" -o "$tarball"

    local actual
    actual="$(shasum -a 256 "$tarball" | cut -d' ' -f1)"
    if [ "$actual" != "$sha" ]; then
      echo "error: $name bottle sha256 mismatch — expected $sha, got $actual" >&2
      exit 1
    fi

    tar xzf "$tarball" -C "$TOOLS_DIR"
    rm -f "$tarball"
  fi

  if [ ! -x "$bindir/$name" ]; then
    echo "error: $name binary not found at $bindir/$name after extraction" >&2
    exit 1
  fi
  echo "$bindir"
}

# Unpinned task runner — install only if the runner image lacks it.
command -v just >/dev/null 2>&1 || HOMEBREW_NO_AUTO_UPDATE=1 brew install just

for entry in "${PINNED_TOOLS[@]}"; do
  IFS='|' read -r name version sha <<<"$entry"
  selected "$name" "$@" || continue

  echo "==> Pinning $name $version"
  bindir="$(install_bottle "$name" "$version" "$sha")"

  actual="$(tool_version "$name" "$bindir/$name")"
  if [ "$actual" != "$version" ]; then
    echo "error: $name version mismatch — expected $version, got $actual" >&2
    exit 1
  fi

  # Put the pinned tool ahead of any runner-image copy, for this process and
  # for later GitHub Actions steps.
  export PATH="$bindir:$PATH"
  [ -n "${GITHUB_PATH:-}" ] && echo "$bindir" >>"$GITHUB_PATH"
  echo "    $name $actual ✓  ($bindir)"
done

echo "Pinned tools ready."
