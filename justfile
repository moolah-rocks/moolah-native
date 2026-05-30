# Moolah native app — common development tasks.
# Install just: brew install just

# Load .env if present (code signing settings, etc.)
set dotenv-load := true

# List available recipes
default:
    @just --list

# Run swift-format style lint (prints warnings; does not exit non-zero for
# pre-existing advisory violations). Use `format-check` in CI and pre-commit
# to enforce actual formatting.
#
# `Vendored/` is excluded — third-party MIT source we copied verbatim
# (with marked local extensions). See Vendored/OutlineView/NOTICE.md.
lint:
    #!/usr/bin/env bash
    set -euo pipefail
    git ls-files '*.swift' ':!:Vendored/**' \
        | xargs swift-format lint --configuration .swift-format

# Apply swift-format formatting in place, then run SwiftLint autocorrect.
# Run this before committing; CI rejects unformatted files or new lint warnings.
#
# `Vendored/` is excluded — see the comment on `lint`.
format:
    #!/usr/bin/env bash
    set -euo pipefail
    git ls-files '*.swift' ':!:Vendored/**' \
        | xargs swift-format format -i --configuration .swift-format
    swiftlint lint --fix --quiet

# Back-compat alias for `format`.
lint-fix: format

# Verify that every tracked Swift file is already in formatted form.
# Non-destructive: does not modify any files. Exits non-zero on any diff.
# Used by CI; run locally before committing if you want to preview failures
# without applying changes.
#
# `Vendored/` is excluded — see the comment on `lint`.
format-check:
    #!/usr/bin/env bash
    set -euo pipefail
    fail=0
    while IFS= read -r file; do
        if ! cmp -s "$file" <(swift-format format --configuration .swift-format "$file"); then
            echo "::error file=$file::Not formatted; run 'just format' to fix"
            diff -u --label "$file" --label "$file (formatted)" \
                "$file" <(swift-format format --configuration .swift-format "$file") || true
            fail=1
        fi
    done < <(git ls-files '*.swift' ':!:Vendored/**')
    if [ "$fail" -ne 0 ]; then
        echo
        echo "One or more files are not formatted correctly."
        echo "Run 'just format' and commit the result."
        exit 1
    fi
    echo "All Swift files are correctly formatted."
    swiftlint lint --strict --quiet

# Verify production code contains no `import SwiftData`. Phase B of the
# GRDB migration removed every SwiftData dependency from production
# sources; this guard keeps it that way. CI runs this alongside
# `format-check`.
no-swiftdata:
    #!/usr/bin/env bash
    set -euo pipefail
    if grep -rln "import SwiftData" App/ Backends/ Features/ Shared/ MoolahBenchmarks/ ; then
        echo "Production code must not import SwiftData — phase B is in effect."
        exit 1
    fi
    echo "No SwiftData imports in production."

# FILTERS restrict the run to specific tests: each is a class (e.g.
# TransactionStoreTests) or class/method (e.g. TransactionStoreTests/testFoo);
# the platform's test target prefix (MoolahTests_iOS or MoolahTests_macOS) is
# added automatically. Pass a fully-qualified TestTarget/Class form to pin a
# filter to one platform's target.
# Run the test suite on iOS Simulator and macOS in parallel (optional FILTERS).
test *FILTERS: generate
    bash scripts/test.sh all {{ FILTERS }}

# Run tests on macOS only. See `test` for FILTERS syntax.
test-mac *FILTERS: generate
    bash scripts/test.sh mac {{ FILTERS }}

# Run tests on iOS Simulator only. See `test` for FILTERS syntax.
test-ios *FILTERS: generate
    bash scripts/test.sh ios {{ FILTERS }}

# Run performance benchmarks (macOS only)
benchmark *FILTER: generate
    bash scripts/benchmark.sh {{ FILTER }}

# Run UI tests on native macOS (no simulator). FILTERS work like `test`:
# pass a class name (e.g. `UITestingLaunchSmokeTests`) or class/method to
# narrow the run. The MoolahUITests_macOS prefix is added automatically.
test-ui *FILTERS: generate
    bash scripts/test-ui.sh {{ FILTERS }}

# Run unit tests for release-script helpers (no git/network side effects).
test-release-scripts:
    bash scripts/tests/test-release-common.sh

# Build the app for macOS
build-mac: generate
    #!/usr/bin/env bash
    set -euo pipefail
    args=(-scheme Moolah-macOS -destination 'platform=macOS' -derivedDataPath .build)
    if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
        # CODE_SIGNING_ALLOWED=NO skips signing for every target in the
        # graph — including the bundled MoolahImportExtension_macOS, whose
        # App Group entitlement would otherwise require a provisioning
        # profile under Automatic signing even when the parent app falls
        # back to ad-hoc identity. (Pairing this with CODE_SIGN_IDENTITY=-
        # is counter-productive: Xcode still resolves an Automatic
        # provisioning profile for the extension before consulting the
        # identity, and fails fast on the missing profile.) Developers
        # with a DEVELOPMENT_TEAM in their .env build through real signing
        # and need a provisioning profile registered for the extension's
        # bundle id (rocks.moolah.app.importextension).
        args+=(CODE_SIGNING_ALLOWED=NO ENABLE_HARDENED_RUNTIME=NO)
    fi
    xcodebuild build "${args[@]}"

# Build and launch the macOS app. Extra args are forwarded as launch
# arguments to the app process (e.g. `just run-mac --ui-testing`).
#
# With args: launches the binary directly and backgrounds it so env
# vars exported by the caller (e.g. `UI_TESTING_SEED=welcomeEmpty`)
# reach the child process. Launch Services (`open --args`) does not
# reliably forward the shell environment into the target app.
#
# Without args: uses `open` so the app activates through Launch
# Services like a double-click (preserves Finder-style launch).
run-mac *args: generate
    #!/usr/bin/env bash
    set -euo pipefail
    build=(-scheme Moolah-macOS -destination 'platform=macOS' -derivedDataPath .build)
    if [ -z "${DEVELOPMENT_TEAM:-}" ]; then
        build+=(CODE_SIGN_IDENTITY="-" ENABLE_HARDENED_RUNTIME=NO)
    fi
    xcodebuild build "${build[@]}"
    if [ -n "{{args}}" ]; then
        # Kill any running instance first; `open` would silently
        # reuse it, skipping the new launch arguments entirely.
        pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
        nohup .build/Build/Products/Debug/Moolah.app/Contents/MacOS/Moolah \
            {{args}} >/dev/null 2>&1 &
        disown
    else
        open .build/Build/Products/Debug/Moolah.app
    fi

# Build the app for the iOS Simulator
build-ios: generate
    #!/usr/bin/env bash
    set -euo pipefail
    SIM="$(bash scripts/find-simulator.sh)"
    echo "==> Building for iOS Simulator ($SIM)…"
    xcodebuild build \
        -scheme Moolah-iOS \
        -destination "platform=iOS Simulator,name=$SIM" \
        CODE_SIGNING_ALLOWED=NO

# Regenerate the site/help/ web copy from the HTML fragments under
# site/help/_src/. Runs only when source files or the generator have changed
# since the last successful run. The web copy is the canonical help surface —
# the macOS Help menu opens https://moolah.rocks/help/ directly. A native
# HelpViewer book is not built (HelpViewer's sidebar TOC is gated to
# Apple-CDN-hosted books only).
build-help:
    #!/usr/bin/env bash
    set -euo pipefail

    STAMP_DIR=".build/stamps"
    HELP_STAMP="$STAMP_DIR/help-gen.stamp"
    mkdir -p "$STAMP_DIR"

    needs=0
    if [ ! -f "$HELP_STAMP" ]; then
        needs=1
    elif [ ! -f "site/help/index.html" ]; then
        needs=1
    elif find site/help/_src -type f \
        \( -name '*.html' -o -name '*.tmpl' -o -name '*.json' \
           -o -name '*.css' \) \
        -newer "$HELP_STAMP" 2>/dev/null | grep -q .; then
        needs=1
    elif find tools/HelpGen/Sources -type f -name '*.swift' \
        -newer "$HELP_STAMP" 2>/dev/null | grep -q .; then
        needs=1
    fi

    if [ "$needs" -eq 1 ]; then
        swift run --package-path tools/HelpGen help-gen
        touch "$HELP_STAMP"
    fi

# Regenerate the CloudKit wire-struct layer from CloudKit/schema.ckdb,
# then regenerate Moolah.xcodeproj from project.yml. Stamp-gated: each
# sub-step is skipped when its inputs are unchanged since the last
# successful run, so `just test` / `just build-mac` don't pay the
# xcodegen + swift-run cost on every invocation. Force a full regen
# with `rm -rf .build/stamps`.
generate:
    #!/usr/bin/env bash
    set -euo pipefail

    STAMP_DIR=".build/stamps"
    SCHEMA_STAMP="$STAMP_DIR/ckdb-schema-gen.stamp"
    PLUGINS_STAMP="$STAMP_DIR/plugin-manifest-gen.stamp"
    mkdir -p "$STAMP_DIR"

    # ---- help-gen ----
    just build-help

    # ---- ckdb-schema-gen ----
    # Regenerate when the schema, the generator's sources, or the output
    # directory itself has gone missing. The output dir is gitignored, so
    # a fresh checkout always misses the stamp and regenerates.
    needs_schema_gen=0
    if [ ! -f "$SCHEMA_STAMP" ]; then
        needs_schema_gen=1
    elif [ ! -d "Backends/CloudKit/Sync/Generated" ] \
        || [ -z "$(ls -A Backends/CloudKit/Sync/Generated 2>/dev/null)" ]; then
        needs_schema_gen=1
    elif [ "CloudKit/schema.ckdb" -nt "$SCHEMA_STAMP" ]; then
        needs_schema_gen=1
    elif find tools/CKDBSchemaGen/Sources -type f -name '*.swift' \
        -newer "$SCHEMA_STAMP" 2>/dev/null | grep -q .; then
        needs_schema_gen=1
    fi

    if [ "$needs_schema_gen" -eq 1 ]; then
        swift run --package-path tools/CKDBSchemaGen ckdb-schema-gen generate \
            --input CloudKit/schema.ckdb \
            --output Backends/CloudKit/Sync/Generated
        touch "$SCHEMA_STAMP"
    fi

    # ---- plugin-manifest-gen ----
    # Regenerate the BundledPlugins Swift table and the per-platform
    # MoolahImportExtension Info.plist files from Plugins/plugins.json. The
    # generator emits a complete Info.plist (CFBundle keys + NSExtension dict
    # + activation rule predicate) so the extension targets can point at it
    # directly as INFOPLIST_FILE — no merge step is needed. Unlike the CKDB
    # output, these files are committed (predictable PR diffs); the stamp
    # avoids re-running `swift run` when nothing changed.
    PLUGIN_SWIFT="Modules/ImportExtensionKit/Sources/ImportExtensionKit/Generated/PluginRegistry+Bundled.swift"
    PLUGIN_IOS_PLIST="MoolahImportExtension_iOS/Generated/Info.plist"
    PLUGIN_MAC_PLIST="MoolahImportExtension_macOS/Generated/Info.plist"
    needs_plugin_gen=0
    if [ ! -f "$PLUGINS_STAMP" ]; then
        needs_plugin_gen=1
    elif [ ! -f "$PLUGIN_SWIFT" ] || [ ! -f "$PLUGIN_IOS_PLIST" ] \
        || [ ! -f "$PLUGIN_MAC_PLIST" ]; then
        needs_plugin_gen=1
    elif [ "Plugins/plugins.json" -nt "$PLUGINS_STAMP" ]; then
        needs_plugin_gen=1
    elif find tools/PluginManifestGen/Sources -type f -name '*.swift' \
        -newer "$PLUGINS_STAMP" 2>/dev/null | grep -q .; then
        needs_plugin_gen=1
    fi

    if [ "$needs_plugin_gen" -eq 1 ]; then
        mkdir -p \
            "$(dirname "$PLUGIN_SWIFT")" \
            "$(dirname "$PLUGIN_IOS_PLIST")" \
            "$(dirname "$PLUGIN_MAC_PLIST")"
        swift run --package-path tools/PluginManifestGen PluginManifestGen \
            Plugins/plugins.json \
            "$PLUGIN_SWIFT" \
            "$PLUGIN_IOS_PLIST" \
            "$PLUGIN_MAC_PLIST"
        touch "$PLUGINS_STAMP"
    fi

    # Provide default
    export CODE_SIGN_STYLE="${CODE_SIGN_STYLE:-Automatic}"

    # ---- xcodegen ----
    # Optionally inject Debug-config entitlements for local CloudKit development.
    # Set ENABLE_ENTITLEMENTS=1 to make `just build-mac` / `just run-mac` produce
    # a Debug binary signed with the test container's iCloud entitlement. Release
    # builds are produced by fastlane lanes (no entitlement injection here) and
    # shipped via the GitHub release artefact — there is no local Release path.
    #
    # xcodegen's own `--use-cache` keys on the resolved spec — the parsed
    # `project.yml` *and* the full set of source files it globs in. That
    # makes it skip regeneration when nothing changed and regenerate when
    # a file is added or deleted under one of project.yml's directory
    # paths (the case a `project.yml` mtime check misses) or when the
    # injected-entitlements spec content differs. The cache lives inside
    # the worktree's `.build`, so it is not shared between worktrees and
    # is removed along with the worktree.
    XCODEGEN_CACHE=".build/xcodegen.cache"
    if [ "${ENABLE_ENTITLEMENTS:-}" = "1" ]; then
        SPEC=$(bash scripts/inject-entitlements.sh)
        trap "rm -f $SPEC" EXIT
        xcodegen generate --use-cache --cache-path "$XCODEGEN_CACHE" --spec "$SPEC"
    else
        xcodegen generate --use-cache --cache-path "$XCODEGEN_CACHE"
    fi

# Removes:
#   - .build                      xcodebuild derived data + generate stamps
#                                 (build-mac / run-mac)
#   - .DerivedData-mac / -ios     test.sh derived data
#   - .DerivedData-bench          benchmark.sh derived data
#   - .agent-tmp/derived-data-ui  test-ui.sh derived data
#   - Moolah.xcodeproj            xcodegen output (gitignored)
# All are regenerated by a subsequent `just generate` / build / test.
#
# Remove build/derived-data artefacts so the next build starts cold.
clean:
    #!/usr/bin/env bash
    set -euo pipefail
    rm -rf .build .DerivedData-* .agent-tmp/derived-data-ui Moolah.xcodeproj
    echo "Removed build/derived-data artefacts and Moolah.xcodeproj."

# Pure-text check: no CloudKit calls. Run in CI on every PR.
#
# Verify CloudKit/schema.ckdb is additive over the committed Production baseline.
check-schema-additive:
    swift run --package-path tools/CKDBSchemaGen ckdb-schema-gen check-additive \
        --proposed CloudKit/schema.ckdb \
        --baseline CloudKit/schema-prod-baseline.ckdb

# Sync code signing certificates (runs Match)
certificates:
    bundle exec fastlane ios certificates

# Check App Store requirements without signing (Info.plist, icons, etc.)
validate-appstore:
    bash scripts/validate-appstore.sh

# Validate that every TODO / FIXME references an open GitHub issue.
# Requires `gh` authenticated (GITHUB_TOKEN in CI or `gh auth login` locally).
# See guides/CODE_GUIDE.md §20.
validate-todos:
    bash scripts/check-todos.sh

# Validate an iOS archive against App Store rules (requires signing)
validate-ios: generate
    bundle exec fastlane ios validate

# Build and upload to TestFlight
testflight: generate
    bundle exec fastlane ios beta

# Bump marketing version (usage: just bump-version 1.2.0)
bump-version version:
    sed -i '' 's/MARKETING_VERSION: .*/MARKETING_VERSION: "{{version}}"/' project.yml
    just generate

# Build, launch macOS app, and stream logs to .agent-tmp/app-logs.txt.
# Extra args after the predicate are forwarded as launch arguments to
# the app process (e.g.
# `just run-mac-with-logs 'subsystem == "com.moolah.app"' --ui-testing`).
run-mac-with-logs predicate='subsystem == "com.moolah.app"' *args: generate
    bash scripts/run-with-logs.sh '{{predicate}}' {{args}}

# Open the project in Xcode
open:
    open Moolah.xcodeproj

# Export the CloudKit Development schema to CloudKit/schema.ckdb.
# Requires DEVELOPMENT_TEAM and a management token (`xcrun cktool save-token
# --type management` for local use, or CKTOOL_MANAGEMENT_TOKEN in CI).
export-schema:
    bash scripts/export-schema.sh

# Manual local convenience: import CloudKit/schema.ckdb to the developer's
# personal Development container with --validate. Not used by CI.
verify-schema:
    bash scripts/verify-schema.sh

# Manual local convenience: Apple's recommended Production-equivalent
# dry-run. Resets your personal Dev container to match Prod, then imports
# the proposed schema with --validate. DESTRUCTIVE — set
# CKTOOL_ALLOW_DEV_RESET=1 to confirm. Not used by CI.
dryrun-promote-schema:
    bash scripts/dryrun-promote-schema.sh

# Release-tag CI: verifies the live Production schema matches
# CloudKit/schema-prod-baseline.ckdb. Used as a sanity check that the
# committed baseline is up to date.
verify-prod-matches-baseline:
    bash scripts/verify-prod-matches-baseline.sh

# Release-tag CI: verifies the live Production schema matches
# CloudKit/schema.ckdb (the source of truth). Apple's API does not expose
# a way to write schema to Production via cktool — deploy via the CloudKit
# Console (Schema → Deploy Schema Changes to Production). This target is
# the gate that confirms the Console deploy has been performed.
verify-prod-deployed:
    bash scripts/verify-prod-deployed.sh

# Release-tag CI: imports CloudKit/schema.ckdb to the Development
# environment as a staging step before a manual Console deploy. Resets Dev
# first to match Production so the Console's diff view is clean.
# DESTRUCTIVE on Dev — wipes any developer experiments in the team's Dev
# CloudKit container. See issue #495 for separating dev/test from the
# release-pipeline container.
import-schema-to-dev:
    bash scripts/import-schema-to-dev.sh

# Manual local convenience: bootstraps the test container's Development
# schema from CloudKit/schema.ckdb. Run once after creating the test
# container in App Store Connect, or to wipe the test container back to a
# known-good state. DESTRUCTIVE — set CKTOOL_ALLOW_DEV_RESET=1 to confirm.
# Not used by CI.
import-schema-to-test:
    bash scripts/import-schema-to-test.sh

# Release-tag CI: refreshes CloudKit/schema-prod-baseline.ckdb from live
# Production after a successful release. Opens a follow-up PR if the
# baseline file changed.
refresh-prod-baseline:
    bash scripts/refresh-prod-baseline.sh

# === Release ===
# Verify the local repo is on main, clean, in sync with origin, gh
# authenticated, and CI green. Used by both RC and final flows.
release-preflight:
    bash scripts/release-preflight.sh

# Compute the proposed version for the next release tag.
# KIND=rc|final. Emits JSON to stdout (see scripts/lib/release-common.sh).
release-next-version KIND:
    bash scripts/release-next-version.sh {{KIND}}

# Create the GH pre-release for an RC. Creates the tag at HEAD of main,
# which fires release-rc.yml. NOTES_FILE is a path to a markdown file
# containing the user-facing release notes (see guides/RELEASE_GUIDE.md).
release-create-rc VERSION NOTES_FILE:
    bash scripts/release-create-rc.sh {{VERSION}} {{NOTES_FILE}}

# Create the final GH release. Creates the tag at the same commit as
# the named RC, which fires release-final.yml.
release-create-final VERSION RC_TAG NOTES_FILE:
    bash scripts/release-create-final.sh {{VERSION}} {{RC_TAG}} {{NOTES_FILE}}

# Wait for the workflow run associated with a release tag to finish.
# Exits zero if the run succeeded, non-zero with the conclusion otherwise.
release-wait TAG:
    bash scripts/release-wait.sh {{TAG}}

# Print a summary of a release: GH release state, workflow run state,
# attached assets.
release-status TAG:
    bash scripts/release-status.sh {{TAG}}

# Download the latest GitHub release (including prereleases), unzip it,
# and replace /Applications/Moolah.app. Prints the installed version on
# success. Requires `gh` authenticated.
install-release-mac:
    #!/usr/bin/env bash
    set -euo pipefail
    tag="$(gh release list --limit 1 --json tagName --jq '.[0].tagName')"
    if [ -z "$tag" ]; then
        echo "No GitHub releases found." >&2
        exit 1
    fi
    tmp="$(mktemp -d)"
    trap 'rm -rf "$tmp"' EXIT
    echo "==> Downloading ${tag}…"
    gh release download "$tag" --pattern 'Moolah-*.zip' --dir "$tmp"
    zip="$(find "$tmp" -maxdepth 1 -name 'Moolah-*.zip' -print -quit)"
    if [ -z "$zip" ]; then
        echo "Release $tag has no Moolah-*.zip asset." >&2
        exit 1
    fi
    echo "==> Extracting $(basename "$zip")…"
    unzip -q "$zip" -d "$tmp/extracted"
    app="$(find "$tmp/extracted" -maxdepth 2 -name 'Moolah.app' -type d -print -quit)"
    if [ -z "$app" ]; then
        echo "Moolah.app not found inside $(basename "$zip")." >&2
        exit 1
    fi
    echo "==> Replacing /Applications/Moolah.app…"
    pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
    rm -rf "/Applications/Moolah.app"
    mv "$app" "/Applications/Moolah.app"
    version="$(defaults read /Applications/Moolah.app/Contents/Info CFBundleShortVersionString)"
    build="$(defaults read /Applications/Moolah.app/Contents/Info CFBundleVersion)"
    echo "==> Installed Moolah $version (build $build) from $tag"

# Assert that `just build-help` is idempotent — running twice in a row must
# leave the stamp's modification time unchanged on the second invocation.
# Catches regressions where the change-detection logic in `build-help` is
# broken (e.g. always regenerates). Used by CI on the macOS lane.
verify-help:
    #!/usr/bin/env bash
    set -euo pipefail
    just build-help
    STAMP=".build/stamps/help-gen.stamp"
    if [ ! -f "$STAMP" ]; then
        echo "verify-help: stamp missing after first build-help; aborting"
        exit 1
    fi
    before=$(stat -f %m "$STAMP")
    just build-help
    after=$(stat -f %m "$STAMP")
    if [ "$before" != "$after" ]; then
        echo "verify-help: stamp mtime changed on second run ($before -> $after);"
        echo "             change detection is broken."
        exit 1
    fi
    echo "verify-help: idempotent, stamp unchanged."
