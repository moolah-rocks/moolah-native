#!/usr/bin/env bash
# Prepares the build tree for local CloudKit development.
#
# 1. Writes .build/Moolah.entitlements with the full sandbox + CloudKit keys.
#    The icloud-container-identifiers list contains ONLY the test container —
#    a locally-signed binary cannot claim the production container. See
#    issue #495.
# 2. Produces project-entitlements.yml — a copy of project.yml that augments
#    each app target's existing Debug block with CODE_SIGN_ENTITLEMENTS
#    pointing at .build/Moolah.entitlements and the CLOUDKIT_ENABLED
#    compilation condition. (project.yml already carries a Debug block for
#    CLOUDKIT_ENVIRONMENT.)
#
# Only Debug is touched: the only locally-signed CloudKit-enabled build is
# `just build-mac` / `just run-mac` (Debug). Release builds are produced by
# the fastlane lanes (which run `just generate` without ENABLE_ENTITLEMENTS=1
# and apply their own fastlane/Moolah(-mac).entitlements) and shipped via
# the GitHub release artefact.
#
# The Debug-Tests configuration deliberately does NOT get these, so
# `just test` never signs the test host with iCloud entitlements. See
# plans/2026-04-20-strip-icloud-from-tests-design.md.
#
# Prints the path to the temp project file. Caller cleans up.
set -euo pipefail

TEMP_FILE="project-entitlements.yml"
ENTITLEMENTS_FILE=".build/Moolah.entitlements"

mkdir -p "$(dirname "$ENTITLEMENTS_FILE")"
cat > "$ENTITLEMENTS_FILE" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.app-sandbox</key>
    <true/>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.files.user-selected.read-write</key>
    <true/>
    <key>com.apple.developer.icloud-services</key>
    <array>
        <string>CloudKit</string>
    </array>
    <key>com.apple.developer.icloud-container-identifiers</key>
    <array>
        <!--
          Test container only: see issue #495. A locally-signed binary
          cannot claim the production container. fastlane-signed shipped
          builds use a different entitlements file
          (fastlane/Moolah(-mac).entitlements) that lists only
          iCloud.rocks.moolah.app.v2.
        -->
        <string>iCloud.rocks.moolah.app.test</string>
    </array>
    <key>com.apple.developer.icloud-container-environment</key>
    <string>$(CLOUDKIT_ENVIRONMENT)</string>
    <key>com.apple.security.application-groups</key>
    <array>
        <string>group.rocks.moolah.shared</string>
    </array>
</dict>
</plist>
PLIST

OUTFILE="$TEMP_FILE" ENTITLEMENTS_FILE="$ENTITLEMENTS_FILE" python3 << 'PY'
import os

with open("project.yml") as f:
    content = f.read()

entitlements_path = os.environ["ENTITLEMENTS_FILE"]

for target in ("Moolah_iOS", "Moolah_macOS"):
    target_header = f"  {target}:\n    type: application\n"
    target_start = content.find(target_header)
    if target_start == -1:
        raise SystemExit(f"inject-entitlements: could not find target {target}")

    configs_marker = "      configs:\n"
    configs_pos = content.find(configs_marker, target_start)
    if configs_pos == -1:
        raise SystemExit(
            f"inject-entitlements: could not find configs: block for {target}"
        )

    # Insert CODE_SIGN_ENTITLEMENTS and the CLOUDKIT_ENABLED compilation
    # condition at the top of the existing Debug: block. project.yml already
    # carries a Debug: block (for CLOUDKIT_ENVIRONMENT: Development);
    # inserting a second Debug: sibling would make xcodegen's YAML loader
    # keep only the last occurrence and silently drop these keys.
    debug_header = "        Debug:\n"
    debug_pos = content.find(debug_header, configs_pos)
    if debug_pos == -1:
        raise SystemExit(
            f"inject-entitlements: could not find Debug: block for {target}"
        )
    debug_insert_at = debug_pos + len(debug_header)
    debug_injection = (
        f"          CODE_SIGN_ENTITLEMENTS: {entitlements_path}\n"
        '          SWIFT_ACTIVE_COMPILATION_CONDITIONS: "$(inherited) CLOUDKIT_ENABLED"\n'
    )
    content = content[:debug_insert_at] + debug_injection + content[debug_insert_at:]

# Sanity check — both app targets now carry a Debug-scoped entitlement block.
debug_marker = "        Debug:\n          CODE_SIGN_ENTITLEMENTS:"
if content.count(debug_marker) != 2:
    raise SystemExit(
        "inject-entitlements: expected 2 Debug entitlement blocks, "
        f"found {content.count(debug_marker)}"
    )

with open(os.environ["OUTFILE"], "w") as f:
    f.write(content)
PY

echo "$TEMP_FILE"
