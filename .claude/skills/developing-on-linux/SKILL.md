---
name: developing-on-linux
description: Use when working on this repo from a Linux box (e.g. Claude Code on the web, a Linux container, CI debugging) where Xcode and the macOS `just` toolchain are unavailable. Covers installing a Swift toolchain plus version-matched `swift-format` and `swiftlint`, then running format / lint / typecheck locally so you don't burn a 25-minute macOS CI round-trip to discover a formatting or compile error. Use whenever `swift`, `swift-format`, or `swiftlint` is "command not found", or a task says to fix `format-check` / lint / build issues but `just` can't run.
---

# Developing on Linux

The project builds and tests on **macOS only** (`just build-mac`, `just test`, and CI all run `xcodebuild` on `macos-26`). On a Linux host none of that runs. But the two gates that catch the most mistakes — `just format-check` (swift-format byte-parity + `swiftlint --strict`) and basic Swift type-checking — **can** be reproduced on Linux if you install the matching tools. Doing so turns a ~25-minute "push → wait for CI → read failure" loop into a local seconds-long loop.

## The one rule: match CI's pinned versions

CI installs exact tool versions (`scripts/install-ci-tools.sh`, `PINNED_TOOLS`). `format-check` does a **byte-for-byte** `cmp` against `swift-format` output, so a different `swift-format` version will reformat differently and fail CI even when your code is fine. Always read the current pins first:

```bash
grep -A4 'PINNED_TOOLS=' scripts/install-ci-tools.sh
# e.g. swiftlint|0.63.3|...   swift-format|602.0.0|...   xcodegen|2.45.4|...
```

`swift-format` versioning maps to the Swift release: **`602.0.0` ⇔ Swift 6.2**. The toolchain-bundled `swift-format` is built from the same source tag as the standalone Homebrew bottle, so the Swift 6.2 Linux toolchain's `swift-format` produces output identical to CI's `602.0.0`. (It self-reports as `6.2.0` — same thing.) If the pin moves to `6xx.y.z`, install the matching Swift `6.x` toolchain.

## Setup (Ubuntu x86_64)

Took ~2–3 min on a fresh container; the toolchain tarball is ~1 GB.

```bash
# 1. Swift toolchain (provides swiftc, swift-format, and libsourcekitdInProc.so).
#    Pick the URL matching your distro from https://www.swift.org/install/linux/
cd /tmp
curl -sSL -o swift.tar.gz \
  https://download.swift.org/swift-6.2-release/ubuntu2404/swift-6.2-RELEASE/swift-6.2-RELEASE-ubuntu24.04.tar.gz
mkdir -p swift-toolchain && tar xzf swift.tar.gz -C swift-toolchain
TC="/tmp/swift-toolchain/$(ls /tmp/swift-toolchain)/usr"

# 2. SwiftLint Linux binary at the PINNED version (realm/SwiftLint ships
#    swiftlint_linux_amd64.zip in its GitHub releases).
curl -sSL -o swiftlint.zip \
  https://github.com/realm/SwiftLint/releases/download/0.63.3/swiftlint_linux_amd64.zip
mkdir -p swiftlint-bin && (cd swiftlint-bin && unzip -o ../swiftlint.zip)
chmod +x swiftlint-bin/swiftlint

# 3. Persist an env file you can `source` in later Bash calls (shell state
#    does NOT persist between Bash tool calls — re-source it each time, or
#    inline the exports).
cat > /tmp/swiftenv.sh <<EOF
export PATH="$TC/bin:/tmp/swiftlint-bin:\$PATH"
export LD_LIBRARY_PATH="$TC/lib:\${LD_LIBRARY_PATH:-}"
EOF

source /tmp/swiftenv.sh
swift-format --version    # expect 6.2.0  (== CI's 602.0.0)
swiftlint version         # expect 0.63.3
```

**`swiftlint` needs the toolchain's `libsourcekitdInProc.so`.** Without it you get `Fatal error: Loading libsourcekitdInProc.so failed`. Setting `LD_LIBRARY_PATH` to the toolchain's `usr/lib` (as above) fixes it — this is why you install the full toolchain even though you "only" want the linter.

## Running the gates locally

Reproduce `just format-check` exactly (format byte-parity, then strict lint):

```bash
source /tmp/swiftenv.sh
files=$(git ls-files '*.swift' ':!:Vendored/**')   # or scope to your changed files

# (a) apply formatting in place — equivalent to `just format`'s swift-format step
swift-format format -i --configuration .swift-format $files

# (b) byte-parity check — what CI's format-check actually asserts
for f in $files; do
  cmp -s "$f" <(swift-format format --configuration .swift-format "$f") \
    || echo "NOT FORMATTED: $f"
done

# (c) strict lint — respects nested configs (e.g. MoolahTests/.swiftlint.yml)
swiftlint lint --strict --no-cache $changed_dirs
```

Scope `swiftlint` to the directories you touched for speed; it reads `.swiftlint.yml` from the repo root and honours nested overrides automatically.

### Lint rules that bite, and how to satisfy them

- **`multiline_parameters` / `multiline_arguments`** — `.swift-format` has `respectsExistingLineBreaks: true`, so it preserves a layout you write. Write wrapped parameter/argument lists **one per line** (matching existing files like `Shared/AccountPerformanceCalculator.swift`) and swift-format keeps them, satisfying the rule. `multiline_arguments` is also blanket-disabled in `MoolahTests/` and may be file-level-disabled on production files per `.swiftlint.yml` — prefer one-per-line over adding a disable.
- **`function_parameter_count` (>5)** — bundle related args into a small `private struct`.
- **`unneeded_synthesized_initializer`** — delete a memberwise/`init() {}` that exactly matches what the compiler would synthesize (note: an init that *adds default values* the properties lack is NOT redundant — keep it).
- **`identifier_name`** — min 3 chars (only `id, x, y, i, j, n, ok, to` are exempt). No `cv`, `mu`, `sd`.
- For the full policy and the "never reintroduce a baseline / don't `// swiftlint:disable` to dodge debt" rules, load the **`fixing-format-check`** skill.

## Type-checking without Xcode

You can't build the app target on Linux — some files use Darwin-only APIs (`import os`/`OSAllocatedUnfairLock`, `import OSLog`, `import CryptoKit`, `RelativeDateTimeFormatter`, etc.) and there's no iOS/macOS SDK. But you can still catch the bulk of compile errors in a **layer you're editing** by assembling a throwaway type-check harness of just the Foundation-only files it depends on:

```bash
source /tmp/swiftenv.sh
rm -rf /tmp/tc && mkdir -p /tmp/tc
cp Domain/Models/*.swift Domain/Models/CSVImport/*.swift Domain/Services/*.swift /tmp/tc/
cp Shared/FinancialMonth.swift Shared/Array+Uniqued.swift /tmp/tc/
cp <your-layer>/*.swift /tmp/tc/

# Shim/skip the few Darwin-only stragglers, then iterate:
#   - replace `import os` and shim OSAllocatedUnfairLock with an NSLock wrapper
#   - rm files that import OSLog/CryptoKit or use RelativeDateTimeFormatter
#     IF your layer doesn't depend on them (the compiler tells you what's missing)
swiftc -typecheck /tmp/tc/*.swift 2>&1 | grep error: | sort -u
```

Iterate: each error names either a real bug in your code (fix it in the repo) or a missing dependency / Linux-Foundation gap in an unrelated file (add the dep, or drop the file if your layer doesn't use it). Reaching **0 errors** means your layer compiles against the real domain type signatures — it does not guarantee the macOS build, but it eliminates the common mistakes (wrong initializer labels, `Decimal`-vs-`Double` arithmetic, missing members).

For test files: strip `@testable import Moolah` and `import Testing` and fold the support file into the same harness to type-check the test *builders* (the `@Test`/`#expect` macros themselves need the Testing module and won't compile here).

## What still only CI can verify

- The actual `xcodebuild` compile of the whole app + the iOS/macOS-specific code paths.
- Test **execution** (assertions, async behaviour) and UI tests.
- `validate-appstore`, `no-swiftdata`, `validate-todos`, schema additivity (these are quick shell/`just` checks; you can run several directly if `just` is present, but they don't need the toolchain above).

So: use the local loop to land format/lint/typecheck clean, then push and let CI close the loop on build + tests. When monitoring that CI run, follow the **`landing-prs`** skill's guidance and `subscribe_pr_activity` rather than polling.
