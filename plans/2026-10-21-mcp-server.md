# Embedded read-only MCP server (#1373)

## Agreed scope

Deliver the full V1 in stacked PRs, preserving a review and validation boundary at each
stage. Moolah listens exclusively on loopback over plain HTTP. HTTPS, certificates,
Tailscale, proxy configuration, and instructions for remote exposure are out of scope
(user direction, 2026-10-21).

1. Transport/dependency validation and macOS-only target boundary.
2. Read facade, explicit DTOs, bounded repository queries, profile service leases.
3. Device-local Keychain grants, authorization, revocation, limits, cancellation.
4. Opt-in macOS Settings, lifecycle, readiness, audit controls, local setup help.
5. Complete tool catalogue, regression coverage, client compatibility verification.

Each stage gets its own PR; #1373 remains open until the complete stack delivers V1.

## Transport decision

- Official Swift MCP SDK **0.12.1**, release commit
  `a0ae212ebf6eab5f754c3129608bc5557637e605`, MIT.
- Hummingbird **2.28.0**, release commit
  `e12178302dacb8226fc78157f89078a59c75dd98`, Apache-2.0.
- SwiftNIO **2.104.0**, swift-nio-extras **1.35.1**, and swift-log **1.16.1**,
  all Apache-2.0, are also exact direct pins. They were already transitive through
  Hummingbird; direct products are needed to insert the raw-target guard before
  the HTTPTypes codec and to implement Hummingbird's channel/logger signatures.
  The same Swift 6 compilation and signed sandbox verification cover these
  products. The guard consumes NIO-decoded HTTP parts; Moolah owns no HTTP parser.
- Direct dependencies are exact pins in `Modules/MoolahMCP/Package.swift`.
  Package resolution records the inspected transitive dependency versions.
- Both libraries use Swift 6 concurrency. Hummingbird requires Swift 6.2; the
  repository's Xcode 26+ toolchain meets that requirement. Compilation and tests
  use the installed Xcode toolchain with no concurrency escape hatches.
- The SDK supplies `StatelessHTTPServerTransport`, including MCP version/header
  validation. Hummingbird supplies the maintained HTTP parser, bounded body
  collection, connection cap, and cancellation-aware listener lifecycle.
- The SDK's NIO example was evaluated. It is example executable code rather than
  a reusable host product and includes unbounded body collection and unsafe
  concurrency annotations. Reusing Hummingbird avoids owning an HTTP parser or
  copying that example's lifecycle.
- Instantiate an SDK server/transport per HTTP message. SDK response waiters are
  keyed solely by client-chosen JSON-RPC ID; sharing a transport across clients
  permits collisions. Per-message handlers capture authorization independently.
  No MCP session ID or shared client initialization state is required.
- Advertise tools only. Use JSON POST responses, 202 for accepted notifications,
  and 405 for GET. Origin is denied unless explicitly allowed; Host is exact.
- JSON-RPC envelope validation rejects unsupported identifier shapes before SDK
  dispatch. A transport deadline prevents malformed requests from retaining
  response continuations indefinitely.

## Platform and sandbox boundary

`MoolahMCP` is a local package dependency of `Moolah_macOS` only. Its hosting
sources live outside shared Automation membership. The generated-project CI
check asserts macOS membership and rejects MCP products/sources in iOS targets;
the existing iOS CI job compiles the actual iOS application/tests.

Inbound networking is added only to macOS release entitlements and to a separate
macOS entitled-development file. The iOS entitled-development file retains its
existing permissions. Merely linking this stage's package starts no listener:
there is no application lifecycle integration yet.

## Isolated verification fixture

`just test-mcp` exercises endpoint policy, SDK negotiation/capabilities,
notifications, method/header errors, malformed envelopes, and concurrent clients
reusing IDs. Tests do not initialize the app or any financial profile.

`just verify-mcp-transport` installs the exact Python client in an isolated venv
and runs the live checks in CI.

`just build-mcp-spike` builds an isolated synthetic listener. It generates an
unpersisted random token and returns it through an inherited private pipe, then
exposes only `moolah_transport_probe`.
`scripts/test-mcp-transport.py` launches it and uses the official Python MCP SDK
2.3.0 with a custom bearer header for initialize → list → call. It also exercises
HTTP authentication, Host/Origin rejection, method handling and the body cap.
The fixture never opens database files, Keychain, CloudKit, or production data.

V1 supports clients that can attach a manually configured Authorization bearer
header. Clients requiring OAuth discovery are outside this mode. Actual
supported client/version evidence is recorded as verification completes; a
successful raw JSON-RPC request alone does not establish client compatibility.

## Remaining hardware acceptance

Record signed sandbox listening, app lifecycle/disabled-port behavior, locked-screen
Keychain queries, sleep/wake, and responsiveness evidence against the finished app.
An isolated fixture handshake does not establish these product acceptance criteria.

## Stage 1 verification (2026-10-21)

- Ten isolated Swift tests passed, including 16 simultaneous clients using ID 1.
- Official Python SDK **2.3.0** completed handshake, list, and structured tool call
  using `httpx2.AsyncClient(headers={"Authorization": "Bearer <token>"})` and
  `streamable_http_client`. Its JSON response support interoperates with the
  Swift SDK's stateless transport; GET is correctly rejected with 405.
- The same reference-client checks passed against an isolated `.app` signed with
  an Apple Development identity and sandbox + network.server entitlements.
  A bare signed command-line executable is not the sandbox fixture: the test
  bundle includes a CFBundleIdentifier and CFBundleExecutable. The finished
  Moolah release and development configurations still require their own checks.
- `just build-mac` passed. Its sole warning came from package App Intents metadata
  extraction (no framework dependency); no application Swift warnings appeared.
- `just build-ios` passed without compiling MCP, Hummingbird, or MoolahMCP.
- Generated-project membership and entitled-development plist checks passed.
- Deadline and caller-cancellation tests prove suspended tool work is cancelled
  and awaited before the adapter returns or throws. The adapter owns this task
  explicitly because the pinned SDK does not cancel handlers on server stop.

Upstream sources: [Swift SDK 0.12.1](https://github.com/modelcontextprotocol/swift-sdk/tree/0.12.1),
[Hummingbird 2.28.0](https://github.com/hummingbird-project/hummingbird/tree/2.28.0),
[Streamable HTTP contract](https://modelcontextprotocol.io/specification/2025-11-25/basic/transports).

## Stage 2: authoritative reads and session ownership

The transport-independent `ReadQueryRepository` supplies explicit DTOs for accounts,
categories, earmarks, native balances, and full multi-leg transactions. All list
limits and transaction keysets are pushed into SQLite. Transaction searches use
an explicit bounded interval and require account/category filters to match the
same leg; matching parents retain every leg, with `matches_filters` on each leg.
No UI store load path is used. Notes are omitted unless explicitly requested by
a trusted caller; the later grant layer must authorize that separate permission.

Pages order lists by UUID, and transactions by date descending / UUID ascending.
The revision combines repository lifetime, the single DatabaseQueue connection's
write count, SQLite external-writer detection, and a canonical SHA-256 fingerprint
of the lookup instrument DTOs plus the current profile default instrument. Any intervening write can
expire a continuation, including sync bookkeeping; clients restart the query.
This is a conservative invalidation policy, not a frozen cross-page snapshot.
Native position aggregates are bounded to the selected owners and return each
instrument separately, omit zeroed positions, and preflight at most 10,001
contributing legs before exact aggregation or loading. Result cardinality caps fail explicitly rather than
omitting legs or positions. Monetary quantities serialize as signed decimal
strings at the domain's eight-place storage scale.

Financial rows and their revision are read within one database read transaction.
Canonical instrument metadata comes from the existing shared registry before
that transaction, matching the established cross-database identity lookup
contract; the facade does not claim a cross-database snapshot. The app-wide iCloud engine state is sampled separately from that database
snapshot, with a warning that local data may not reflect other devices.

`SessionManager` owns both service leases and explicit macOS-window ownership.
A successful setup gate is distinct from a session object's existence; failed,
initializing, signed-out, removed, and incompatible sessions cannot supply read
access. The facade checks session identity both before and after a query.
Closing a macOS window retains a leased session; final-owner release runs the
existing sync/task/observation cleanup. Existing legacy cached callers retain
their lifetime. Compatibility eviction now uses that same cleanup path even
when no sync coordinator is present.

Date-only inputs use an explicit Gregorian/POSIX calendar and timezone, inclusive
days become a half-open instant interval using calendar arithmetic, and searches
are capped to one calendar year. Tests include the 23-hour spring day, 25-hour
autumn day, invalid dates, and leap-year range limits.

This stage does not expose a server or tools. Per-call grant checks, signed
cursors, price/report calculations, settings, and lifecycle wiring remain in
the following stages.

Review also hardened shared session routing: interrupted opens cannot publish a
stale profile, legacy ownership is committed only after success, and active roots
observe compatibility eviction. Tests and previews inject disconnected resources
so construction does not access shared public catalogues, live HTTP, or credential
providers. Public catalogue integration uses an explicit temporary directory.
Literal payee search escapes SQL LIKE wildcards in both contains queries and
prefix suggestions.

Stage 2 verification: 78 targeted tests across 19 suites passed, covering read
contracts, bounds, SQL plans, cursor revisions, session ownership, existing
session compatibility/bootstrap, and public-catalogue composition. The iOS build
passed and the generated-project boundary check confirms macOS-exclusive hosting.
Full `just format-check` passed with no SwiftLint output. The warning sweep found
no app Swift warnings; iOS emitted only the existing package AppIntents metadata
extraction notice. Code, concurrency, database, dates, instruments, UI, and help review
cycles addressed their findings before this stage's commit.

An additional 83 tests across 15 existing automation suites passed after migrating
their shared session fixtures to disconnected resources. Final warning-copy
review passed, and formatting was checked again after that copy change.


## Stage 3: credentials and enforced security boundaries

The macOS-only package now supplies the authenticated endpoint, device-local grants,
and opaque continuation signing. Grant creation returns a 256-bit random bearer
secret once. The Keychain archive holds only SHA-256 verifiers and explicit grant
metadata: credential identity, label, profile UUIDs, scopes, revision, expiry,
revocation and last use. The archive is bounded and written atomically before
publishing changes. Revoked credentials can be removed to recover capacity.

Keychain requests select the Data Protection Keychain, disable synchronization,
and use AfterFirstUnlockThisDeviceOnly accessibility with no user-presence gate.
Opening persistence runs off the main actor. These source-level policy checks
and isolated persistence tests do not establish locked-screen hardware behavior.

Every HTTP message authenticates and consumes the per-credential rolling limit
of 60 messages per minute before body collection. Tool execution additionally
checks the explicit profile and scope, permits four active queries per grant,
and applies a 15-second cancellation-aware deadline. Revocation and permission
changes cancel active work and invalidate captured authorization. Each listener
has an exclusive generation; stopping a listener cancels and awaits its queries,
and stale work cannot return data after another listener starts. Responses are
bounded before encoding the outer protocol envelope. Unexpected failures return
safe errors without exposing underlying paths or data.

Continuation tokens use a process-local HMAC key and a monotonic 15-minute TTL.
They bind credential/revision, profile, tool, canonical validated filters and the
repository continuation/revision. Tampering, restart, changed permission or a
changed repository revision requires restarting the query. Rate windows also use
monotonic time; grant expiry and audit-facing metadata use wall-clock instants.

Profile validation now refreshes the authoritative profile index before and after
reads. Removed or incompatible profiles evict their cached sessions, and current
profile currency is used without depending on a visible window updating first.

Verification: 32 isolated package tests and 16 targeted application tests passed.
The official Python MCP SDK 2.3.0 completed live authentication, handshake,
discovery and call checks against both unsigned and Apple Development signed
sandbox fixtures. Live checks also passed for loopback-only binding, Host/Origin
rejection, malformed raw targets, body size, methods, and the 60-message limit.
Fixtures use synthetic data and memory persistence; they never open production
profiles or Keychain. The local reference-client environment uses Python 3.14;
the system Python 3.9 cannot install this client version.

## Stage 4: macOS product integration

Settings → Integrations now contains MCP enablement, a validated stable port,
listener status and endpoint, explicit profile/scope selection, optional expiry,
permission edits, replacement credentials and confirmed revocation/removal. No
profile is selected in a new draft; transaction notes remain separately disabled.
A replacement opens a prefilled creation draft with a fresh valid expiry. Tokens
are displayed only after creation, can be copied deliberately, and are discarded
when the disclosure closes. Owned clipboard contents expire after one minute
without clearing a newer clipboard item. Setup help covers local HTTP clients with
manual bearer headers, optional login-item setup, availability and data privacy.

An app-scoped controller restores enablement from device-local preferences. It
owns the listener and background tasks independently of windows, retains the union
of active grants' profile leases, and drains queries/listener/tasks before releasing
leases on disable or quit. Generation checks release late acquisitions after a
listener fails. Readiness failures drop stale lease bookkeeping so restored profiles
can recover. Existing session ownership prevents closing a window from ending an
MCP-owned session. Readiness displays the same live sync progress as the sidebar.
MCP responses capture one app-wide sync state per call; unready profile items
retain `unknown`. `up_to_date` describes this Mac’s known engine work and does not
guarantee that all recent remote changes are present.

The audit actor serializes complete off-caller file transactions. Only completion
time, credential UUID, registered tool name, parsed profile UUID, elapsed duration
and stable outcome are accepted, including when decoding a persisted archive. The
atomic device-local JSON archive is bounded to 512 KiB and 1,000 records, retaining
at most seven elapsed days. App startup and hourly maintenance purge expired rows
even when MCP is off, without opening Keychain or a listener. Clear history remains
available for corrupt-file recovery. Foreground command revisions prevent delayed
maintenance errors from overwriting a successful recovery.

All hosting, settings, preview and MCP-specific test sources are excluded from iOS
membership; shared integration references remain conditional. App-hosted unit tests
and UI seeds use isolated local preferences, memory credentials and disconnected
sessions. Fresh disabled startup opens neither credential storage nor a socket.

Lifecycle testing exposed a real immediate-restart issue: the original listener
could not rebind while accepted connections remained in TIME_WAIT. Hummingbird's
SO_REUSEADDR option now permits immediate restart; SO_REUSEPORT is not enabled.
A live competing-listener regression confirms that another active listener still
fails closed on the configured port.

Stage 4 verification: 15 targeted application tests across five suites and 33 MCP
package tests passed. The iOS build and generated membership check passed. Code,
concurrency, retention/schema, dates, help and UI source reviews addressed their
findings. Native isolated test-host captures verified settings/create/edit layouts
in both appearances, including long labels. The temporary capture fixture is not
part of the delivered code.

Stage 4 remains a draft: credential token/button contrast and the actual integration
sheet navigation title/toolbar still need visual verification. The locked macOS
session's security shield prevents native capture, and Xcode's bridge is awaiting
user approval. No security shield was bypassed. UI review reports no remaining code
findings; these exact environmental verification limits carry into finished-app
checks in stage 5. Locked-screen Keychain access, sleep/wake and signed finished-app
checks also remain open; synthetic controller tests do not establish those results.

## Stage 5: complete read-only catalogue

The macOS app now registers all nine V1 tools explicitly. Each call checks its
scope and explicit profile UUID before resolving profile metadata or entities.
Notes require both an explicit request and the separate notes permission. Closed
input schemas, strict argument validation, exact decimal-string outputs and
read-only annotations describe the implemented contract. Every response includes
local query/snapshot metadata and an explicit unknown sync-freshness state.

List continuations bind the grant revision, profile, tool, normalised filters and
local database revision. UUID sets are canonicalised before signing. Transaction
continuations retain subsecond keyset precision inside their opaque payload.
Changes to data or permissions require restarting the query.

Balances retain every native position and value all requested accounts in one
conversion batch. Reporting totals require every contributing valuation. Summary
flows match Reports classification and convert on each UTC report day; current net
worth values all posted positions at the query instant. Hidden accounts and
future-dated posted transactions are explicitly included in current net worth.
Missing prices remain unavailable, intentional pricing-policy zeros are labelled,
and an aggregate price date remains unknown if any priced contributor lacks one.
Unexpected conversion failures are QUERY_FAILED, rather than profile availability
errors. Bounded static diagnostics contain no query arguments or financial data.

Summary inputs share one financial database snapshot. The exact production flow
SQL has a plan-pinning test that requires the date-index transaction search before
the indexed leg lookup, without full scans or a temporary sort. Financial input
caps fail explicitly. Price reads remain separate from the financial snapshot.

Status reads now derive metadata from the same captured session/profile as their
repository read. Final validation compares session generation and the full profile.
A sign-out latch prevents periodic maintenance from recreating a signed-out
session; resuming requires a signed-in session opened in Moolah.

The official Python MCP client 2.3.0 and MCP Inspector 2.11.0 both passed real
localhost HTTP authentication, discovery and structured tool calls against the
synthetic fixture. Inspector receives its configuration over anonymous stdin;
credentials are absent from command arguments, environment variables and files.
`just verify-mcp-inspector` reproduces this second-client check. The application
integration tests separately exercise the complete nine-tool registry against an
isolated profile, scope/profile/notes denial, signed pagination and revision expiry,
unsupported arguments, exact valuations, and unchanged visible filters.

Stage 4 CI found the account-performance UI seed could wait on live Frankfurter
history. Its failure artifacts show loading spinners. The seed now supplies daily
constant AUD/USD fixture rates over its chart horizon in the isolated shared index;
a regression verifies the complete history is available without provider requests.
The actual UI stability run is still pending an unlocked graphical session.

Finished-app signed sandbox/Keychain locked-screen, sleep/wake, credential contrast
and real sheet navigation checks remain pending. The first three PRs have green CI.
The fourth PR is a draft with the recorded UI failure; the final stage also remains
a draft until outstanding acceptance checks are complete. No synthetic transport
or unit-test result is presented as proof of those hardware/UI checks.

Stage 5 verification: 65 application regressions across 17 suites passed. A final
focused run passed three tests across two suites, including the four-zone offline
FX cases, full seed-write rollback, and invalid-conversion endpoint failure. The MCP
package passed all 33 tests across six suites. The final iOS build and macOS-only
membership check passed. Full formatting and strict lint passed; compiler-warning
sweeps found no application Swift warnings. Code, concurrency, database, date/time,
instrument, help and UI-test source reviews report no remaining findings. The
reviewed offline seed fix is also backported to the Settings PR for its CI failure.

## Reporting follow-up (2026-10-22)

The [completed reporting plan](completed/2026-10-22-mcp-reporting.md) records the
five follow-up steps: opt-in net worth, cursor-paged compact balances, exact
streaming aggregation, actionable limits, and named category/monthly rollups.
The signed Development app with these changes is running on localhost HTTP.
70 reporting regressions, the strengthened three-test pagination boundary run,
iOS/signed macOS builds and strict lint pass. The settings/tools PRs now have
green CI, including their UI jobs.

A local attempt at the required 20-run chart stability gate stopped at run 1:
macOS LocalAuthentication prevented the UI runner from initializing with
“System authentication is running.” Zero stability runs completed. The OS state
must be resolved before repeating the gate; no automatic retry masks this block.
Locked-screen Keychain, sleep/wake and the remaining visual credential/sheet
checks are still unverified. The PRs remain draft where acceptance is incomplete.
