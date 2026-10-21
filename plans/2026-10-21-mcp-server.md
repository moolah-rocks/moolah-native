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

`just build-mcp-spike` builds an isolated synthetic listener. It accepts an
unpersisted random token on stdin and exposes only `moolah_transport_probe`.
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
