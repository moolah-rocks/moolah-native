#!/usr/bin/env bash
#
# Verifies that the live Production schema matches CloudKit/schema.ckdb (the
# committed source of truth). Used by release-rc.yml as the gate that proves
# a Console-deploy has been performed.
#
# Apple's API does not expose a way to write schema to Production via cktool
# — the only path is the CloudKit Console's "Deploy Schema Changes to
# Production" button. This script is the verification half of that handoff:
# after a developer clicks Deploy in the Console, this script confirms the
# bytes landed.
#
# Comparison is *semantic*, not byte-equal: cktool's `export-schema` returns
# record types in chronological-creation order and uses different
# column-alignment whitespace than human-edited `.ckdb` files. We delegate
# to `tools/CKDBSchemaGen check-equal`, which parses both files and compares
# their parsed AST (record types, fields, types, indexes) regardless of
# source-file order or whitespace. Deprecation is deliberately excluded: a
# `// DEPRECATED` marker is a repo-local annotation with no CloudKit-side
# equivalent, so a live export never carries it — comparing it would make this
# gate permanently fail after any field/record deprecation.
#
# Targets the release container (CLOUDKIT_CONTAINER_ID_RELEASE) — see issue
# #495.
#
# Exits 0 if Production is semantically equal to schema.ckdb; non-zero with
# a descriptive list of differences (printed by the Swift tool) if not.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/cloudkit-config.sh
source "$HERE/cloudkit-config.sh"

cloudkit_require_env
CLOUDKIT_CONTAINER_ID="$CLOUDKIT_CONTAINER_ID_RELEASE"

[ -f "$CLOUDKIT_SCHEMA_FILE" ] \
    || cloudkit_fail "$CLOUDKIT_SCHEMA_FILE is missing."

live=$(mktemp)
trap 'rm -f "$live"' EXIT

cloudkit_cktool export-schema \
    --environment production \
    --output-file "$live" >/dev/null

if swift run --quiet --package-path tools/CKDBSchemaGen ckdb-schema-gen check-equal \
    --a "$live" \
    --b "$CLOUDKIT_SCHEMA_FILE" >&2
then
    echo "✓ live Production schema matches $CLOUDKIT_SCHEMA_FILE"
    exit 0
fi

cat >&2 <<EOF

✗ live Production schema does not match $CLOUDKIT_SCHEMA_FILE.

The proposed schema has not been deployed to Production. Apple's API does
not expose a CLI path for production schema deploys — the only way to
deploy is the CloudKit Console:

  1. Open https://icloud.developer.apple.com/dashboard/ for container
     $CLOUDKIT_CONTAINER_ID.
  2. Schema → Deploy Schema Changes to Production.
  3. Review the diff (Dev should already match schema.ckdb if this script
     ran via the release pipeline; if not, run 'just import-schema-to-dev'
     first).
  4. Confirm Deploy.
EOF
exit 1
