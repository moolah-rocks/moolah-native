# Moolah — Native iOS/macOS App

A universal personal finance app for iPhone and Mac. Tracks accounts, transactions,
categories, earmarks (savings goals), scheduled payments, and investment & crypto
holdings, and provides analysis and reporting. Data syncs across devices via
iCloud/CloudKit — no server component required.

## Requirements

| Tool | Version |
|---|---|
| Xcode | 26+ |
| iOS deployment target | 26+ |
| macOS deployment target | 26+ |
| XcodeGen | Latest (`brew install xcodegen`) |
| just | Latest (`brew install just`) |
| SwiftLint | 0.55+ (`brew install swiftlint`) — run by `just format` and `just format-check` |
| Ruby + Bundler | 3.3+ (for Fastlane, release builds only) |

## Quick start

```bash
git clone <repo>
cd moolah-native
just generate   # creates Moolah.xcodeproj from project.yml
just open       # opens in Xcode
```

> **Tip:** Re-run `just generate` after editing `project.yml`. Never edit
> `Moolah.xcodeproj/project.pbxproj` directly.

## Building & Running

```bash
just run-mac     # build and launch the macOS app directly
just build-mac   # build for macOS without launching (ad-hoc signed, no certificate needed)
just build-ios   # build for iPhone 17 Pro simulator
```

`just run-mac` writes its build products to `.build/` in the repo root so they don't
mix with Xcode's DerivedData, then opens the resulting `.app` bundle directly.

To build and run from Xcode: select the **Moolah** scheme and your destination, then
press **Run** (⌘R).

| Target | Destination |
|---|---|
| `Moolah_iOS` | iPhone 17 Pro simulator (iOS 26) |
| `Moolah_macOS` | My Mac |

## Running Tests

```bash
just test
```

Runs the full test suite on both iPhone 17 Pro simulator and macOS. Feature and
domain tests run against `TestBackend` (a `CloudKitBackend` backed by an in-memory
GRDB database) — no network connection or server account is needed. See
[`scripts/test.sh`](scripts/test.sh) for the platform-specific details.

To run one platform manually:

```bash
xcodebuild test -scheme Moolah -destination "platform=iOS Simulator,name=iPhone 17 Pro"
xcodebuild test -scheme Moolah -destination "platform=macOS"
```

## Project Structure

```
moolah-native/
├── App/                    # Entry point (MoolahApp.swift), composition root
├── Domain/
│   ├── Models/             # Plain Swift structs: UserProfile, Account, Transaction, …
│   └── Repositories/       # Protocol definitions only — no backend imports
├── Backends/
│   ├── CloudKit/           # Production backend: GRDB/SQLite repositories + CKSyncEngine iCloud sync
│   ├── GRDB/               # SQLite schema, records, and repository implementations
│   └── …                   # Price/rate providers (CoinGecko, CryptoCompare, Binance, YahooFinance, Frankfurter)
├── Features/               # One folder per screen/feature
│   ├── Auth/               # AuthStore, AppRootView, SignedOutView, UserMenuView
│   └── …
├── Shared/
│   ├── Components/         # Reusable SwiftUI views
│   ├── Extensions/
│   └── PreviewBackend.swift # In-memory backend used by SwiftUI previews
├── MoolahTests/            # Unit + store tests (MoolahTests_iOS, MoolahTests_macOS)
│   ├── Domain/             # Pure logic and model tests
│   ├── Features/           # Store tests using TestBackend
│   └── Support/
│       ├── TestBackend.swift # CloudKitBackend over an in-memory GRDB database
│       └── Fixtures/         # JSON/CSV fixture files
├── MoolahUITests_macOS/    # XCUITest UI tests (macOS only)
├── fastlane/               # Fastlane config for TestFlight/App Store builds
├── plans/                  # Planning documents and feature specs
├── guides/                 # Engineering guides (architecture, testing, sync, …)
├── justfile                # Common dev tasks (just build-mac, just test, …)
├── project.yml             # XcodeGen spec — edit this, not the .xcodeproj
├── .github/workflows/      # CI, release (RC/final), and monthly-RC workflows
└── scripts/
    └── test.sh             # Runs tests on both platforms
```

## Architecture

The app uses a **repository pattern** to decouple features from any specific backend.

```
Views / Stores  →  Repository protocols  →  Backend implementations
                   (Domain layer)            CloudKit (GRDB/SQLite + CKSyncEngine sync)
```

- **Domain models** (`UserProfile`, `Account`, `Transaction`, etc.) are plain Swift
  structs in the `Domain` module. Features only ever see these types.
- **Repository protocols** (`AuthProvider`, `AccountRepository`, ...) express
  operations in domain terms — no networking or persistence imports.
- **`BackendProvider`** is the single injection point via `@Environment`. The
  production implementation, **`CloudKitBackend`**, wraps the GRDB repositories
  (`Backends/GRDB/`) over a per-profile SQLite database plus a CKSyncEngine iCloud
  sync layer — no server component required.
- **`TestBackend`** (test target only) is a `CloudKitBackend` backed by an in-memory
  GRDB database, used by every test. **`PreviewBackend`** is the equivalent for
  SwiftUI previews. Neither is compiled into the app binary.

## Code Signing

- **Local development:** iOS targets are unsigned (simulators don't require it). macOS
  targets are ad-hoc signed (`CODE_SIGN_IDENTITY="-"`) with Hardened Runtime disabled.
- **Distribution builds:** Fastlane Match manages certificates and provisioning profiles
  via a private git repo. Entitlements (App Sandbox, CloudKit) are applied during
  distribution builds only.

## Release & TestFlight

Releases ship in two stages — release candidate, then final — both driven by `just`
targets and GitHub Actions:

- **RC tag** (`vX.Y.Z-rc.N`) fires `.github/workflows/release-rc.yml`, which builds and
  notarises the macOS zip (attached to the GitHub pre-release) and uploads the iOS build
  to TestFlight.
- **Final tag** (`vX.Y.Z`) fires `.github/workflows/release-final.yml` at the same commit
  as the promoted RC: it submits to the App Store and publishes the notarised Mac zip on
  the GitHub Release.
- **Monthly RC** (`.github/workflows/monthly-tag.yml`) cuts a fresh RC on the 1st of each
  month so TestFlight builds stay within the 90-day expiry. `workflow_dispatch` triggers
  it manually.

The flow is orchestrated by the release scripts — never push a release tag by hand:

```bash
just release-preflight                 # verify a clean, in-sync, green-CI HEAD
just release-next-version rc            # compute the next RC version + notes base
just release-create-rc 1.2.0-rc.1 notes.md   # tag + create the GH pre-release
just release-wait v1.2.0-rc.1           # follow the workflow to completion
```

Local Fastlane shortcuts:

```bash
just certificates   # sync signing certs via Fastlane Match
just testflight     # build and upload to TestFlight locally (fastlane ios beta)
just bump-version 1.2.0   # update MARKETING_VERSION in project.yml
```

See [`guides/RELEASE_GUIDE.md`](guides/RELEASE_GUIDE.md) for the full procedure,
recovery steps, and the CloudKit schema-deploy gate.
