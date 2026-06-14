# Moolah Database Code Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)
**Engine:** SQLite via [GRDB.swift](https://github.com/groue/GRDB.swift) added as a SwiftPM dependency.

This guide governs **how Swift code talks to the database**: records, mapping, repositories, querying, transactions, and tests. For **what's in the database** — file layout, schemas, indexes, PRAGMAs, migrations — see `guides/DATABASE_SCHEMA_GUIDE.md`. Both guides are non-optional and complement each other.

---

## 1. Philosophy

The boundary between Swift and SQL is thin and explicit. We use raw SQL through GRDB's typed wrappers and query interface; we do not hide SQL behind an ORM. Records are pure data; repositories are stateless conduits.

**Core rules:**

1. Every value crossing the SQL boundary is parameterised. The reviewer treats the unsafe shape as Critical; there is no "usually parameterised".
2. Every performance-critical query has a paired `EXPLAIN QUERY PLAN`-pinning test. Plan regressions break the build.
3. Every multi-statement write happens inside a single transaction and has a rollback test.
4. Records never leave the backend. Repositories return Domain values.
5. `Database` / `Statement` / `Row` / `RowCursor` never escape their closure — compile-time enforced.

### Key sources

- GRDB: [Concurrency](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Concurrency.md), [SwiftConcurrency](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/SwiftConcurrency.md), [SQLInterpolation](https://github.com/groue/GRDB.swift/blob/master/Documentation/SQLInterpolation.md), [RecordRecommendedPractices](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/RecordRecommendedPractices.md), [GRDB7MigrationGuide](https://github.com/groue/GRDB.swift/blob/master/Documentation/GRDB7MigrationGuide.md).
- SQLite: [EXPLAIN QUERY PLAN](https://sqlite.org/eqp.html), [parameter binding](https://sqlite.org/lang_expr.html#varparam).
- Project precedent: `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift` (raw-`sqlite3` actor; predates GRDB; conventions on actor scoping, `*ForTesting` seams, transaction discipline, and rollback tests are worth lifting).
- `guides/CONCURRENCY_GUIDE.md` is non-optional and governs every concurrency decision below.
- `guides/DATABASE_SCHEMA_GUIDE.md` for everything on the SQL side.

---

## 2. Concurrency Model

### Sendable boundary

| Type | Sendable | Where it can live |
|---|---|---|
| `DatabaseQueue` / `DatabasePool` | `@unchecked Sendable` | Held by repositories, services, `ProfileSession` |
| `Database` | **Not Sendable** | Inside `read` / `write` closures only |
| `Statement` | **Not Sendable** | Inside the closure that prepared it |
| `Row` | **Not Sendable** | Inside the closure that fetched it |
| `RowCursor` | **Not Sendable** | Inside the closure that iterates it |

Compiler-enforced under Swift 6 strict concurrency. `Database` / `Statement` / `Row` / `RowCursor` cannot escape their closures — they carry explicit `@available(*, unavailable) extension X: Sendable {}` annotations in GRDB's source.

### Database type: `DatabaseQueue` per database

Use `DatabaseQueue`, not `DatabasePool`, for every project database:

- Reads serialise, but the read profile is sub-millisecond — pool parallelism is unused.
- `DatabaseQueue()` (no path) gives an in-memory queue for tests with zero divergence from production.
- Pool memory cost (one connection per concurrent reader) is unjustified.

WAL mode is still on (WAL ≠ Pool — they are orthogonal).

Upgrade to `DatabasePool` only when a benchmark proves reader contention. Single-line change at the construction site.

### `try DatabaseQueue(...)` is tightly scoped

Construction sites are `Backends/GRDB/`, `ProfileSession`, and test targets. The reviewer flags any other site as Critical.

### Repository pattern

Repositories live under `Backends/GRDB/Repositories/`, are `final class`es marked `@unchecked Sendable`, and hold a `DatabaseWriter`:

```swift
final class GRDBAccountRepository: AccountRepository, @unchecked Sendable {
    let database: any DatabaseWriter

    func accounts() async throws -> [Account] {
        try await database.read { db in
            try AccountRow.fetchAll(db).map(\.domain)
        }
    }

    func upsert(_ account: Account) async throws {
        try await database.write { db in
            try AccountRow(domain: account).upsert(db)
        }
    }
}
```

- All public methods are `async throws`.
- The closure body is the only place `Database` exists. Map records to Domain values *inside* the closure. Never return `Row` / `RowCursor` / `Statement`.
- Stores stay `@MainActor` and call `await repository.x()`.

### `InferSendableFromCaptures`

Closure-shorthand uses (`database.read(Type.fetchAll)`) compile cleanly without `@Sendable` ceremony because the project ships at `SWIFT_VERSION: "6.0"` — and `InferSendableFromCaptures` ([SE-0418](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0418-inferring-sendable-for-methods.md)) is enabled by default in Swift 6 mode.

**Do not** add `-enable-upcoming-feature InferSendableFromCaptures` to `OTHER_SWIFT_FLAGS` — Swift 6 rejects it with `error: upcoming feature 'InferSendableFromCaptures' is already enabled as of Swift version 6`. The feature is only an opt-in flag for Swift 5 mode codebases.

### GRDB 7 task cancellation

In GRDB 7, async `read` / `write` honour task cancellation: cancelling the surrounding `Task` makes the access throw `CancellationError` and rolls back any open transaction. Don't write code that assumes a `write` always completes — especially in long sync loops driven by `CKSyncEngine` events.

### Non-reentrancy

`database.write { database.write { … } }` traps. Compose work inside one closure; don't nest.

### `unsafeRead` / `writeWithoutTransaction` / `unsafeReentrant*`

Forbidden without an inline justification comment naming the lifted guarantee. The reviewer treats unannotated uses as Important.

### `ValueObservation`

**Adopted for reactive store updates** (per `plans/2026-05-06-reactive-sync-refresh-design.md`, lifted 2026-05-06).

Conventions, all enforced by `database-code-review`:

1. **Tracking closure form.** Use `ValueObservation.tracking { db in … }` for queries that fetch concrete data; GRDB infers the region from the SQL/table accesses. **Empty-table caveat:** region inference only registers a table if at least one row is touched during the first fetch (SQLite's `SQLITE_READ` authorizer fires on row access, not on `SELECT 1 FROM empty_table LIMIT 1` returning zero rows). For tracking closures that may run against empty tables — most notably `Void`-emitting tick streams over cache tables — use the explicit-region form `ValueObservation.tracking(regions: [Table("name1"), Table("name2"), ...]) { _ in () }` so the regions are registered unconditionally.
   - **`WITHOUT ROWID` caveat.** SQLite's `sqlite3_update_hook` (the mechanism `ValueObservation` relies on to detect writes) does **not** fire for `WITHOUT ROWID` tables — a documented SQLite limitation. Any write site that targets a `WITHOUT ROWID` table whose region is being observed MUST call `db.notifyChanges(in: Table("name"))` inside the same `db.write { ... }` block, **after** the insert / update / delete. Without the notify the observation registers the region correctly and emits the initial value, but never re-fires on subsequent writes — every subscriber hangs. The rate-cache helper at `Backends/GRDB/Observation/RateCacheTable.swift` (`db.notifyRateCacheChange(.exchangeRate | .stockPrice | .cryptoPrice)`) is the canonical example; production write sites in `ExchangeRateService+Persistence.swift`, `StockPriceService.swift`, and `CryptoPriceService+Persistence.swift` use it after every insert / delete against the three `WITHOUT ROWID` rate-cache tables.
2. **`.removeDuplicates()` is the default** for every `observe…` method that emits a value type (relies on the row decoder being `Equatable`). **Carve-out:** streams that emit `Void` (e.g. `InstrumentConversionService.observeRates()`) MUST NOT apply `removeDuplicates` — `Void == Void` would suppress every emission.
3. **Scheduling.** `.values(in: database)` with no explicit `scheduling:` argument. The default `.task` scheduler (cooperative thread pool) is correct for `AsyncSequence` consumption inside a Swift `Task`. Do not override with a `DispatchQueue`-targeting scheduler (`.async(...)` factories on `DispatchQueue` or the `.mainActorQueued` style); those exist for the Combine `publisher(in:scheduling:)` and callback `start(in:scheduling:onError:onChange:)` paths, and using them with `.values(in:)` causes a redundant dispatch hop when the consuming `Task` is already actor-isolated.
4. **AsyncStream bridge.** All domain protocols return `AsyncStream<T>` (Foundation, `Sendable`). The bridge lives at `Backends/GRDB/Observation/AsyncValueObservation+AsyncStream.swift` and MUST wire `continuation.onTermination` to cancel the underlying observation `Task`. Without this, an `AsyncStream` consumer that cancels its `Task` would not propagate cancellation to GRDB and the observation would leak.
5. **Errors — categorise at the repository, not the bridge.** The bridge is single-shot: it delivers the first error to `onError` and completes the stream (no retry, no categorisation, no logging — see the doc comment on `toAsyncStream(onError:)`). Repositories provide an `onError` callback that distinguishes:
   - **Programmer bugs** (`SQLITE_ERROR` from malformed SQL, missing tables) — `fatalError` in debug; in release, surface to the store via the repository's `observeErrors()` channel and let the stream complete (no restart).
   - **Transient I/O** (`SQLITE_FULL`, `SQLITE_IOERR`) — log at `error` level, then re-create the observation via a restart wrapper that re-calls `repository.observeAll()` (or equivalent) with backoff (1 s, 5 s, 30 s, capped at 5 retries).
   - **Retry budget exhaustion** (5 consecutive transient failures) — surface the most recent error to `observeErrors()`, do not restart again.

   The retry-loop wrapper is implemented by repositories in subsequent stages (the first one lands in Stage 3); the bridge itself stays minimal because it only holds `self` (the `AsyncValueObservation`), not the underlying writer needed to re-create the observation.
6. **Logging contract.** Every error log includes the repository name, method name, and underlying error. Format: `GRDB observation error in <Repo>.<method> [<qualifier>]: <error>`, where `[programmer-bug]` marks fatal programming errors (malformed SQL, missing tables) and `[transient]` marks recoverable I/O errors. Examples:
   ```
   GRDB observation error in AccountRepository.observeAll [transient]: SQLITE_IOERR (errno 5)
   GRDB observation error in AccountRepository.observeAll [programmer-bug]: malformed SQL
   ```
   No bare `print()` or `logger.error("\(error)")`.
7. **Stream completion.** After the bridge surfaces an error to the store (programmer bug or budget exhausted), both `observeAll()` and `observeErrors()` complete (`continuation.finish()`). The store's `TaskGroup` child tasks exit naturally; the `TaskGroup` returns; teardown is clean.

Stores subscribe in `init` with strong `self` (the store is `@MainActor`; the task already holds an implicit strong reference). `stopObserving()` (called from `ProfileSession.cleanupSync`) cancels the observation; a `deinit { observationTask?.cancel() }` safety net protects against missed `cleanupSync` calls.

---

## 3. Records & Mapping

Records are pure `Sendable` value types under `Backends/GRDB/Records/`, named `<Name>Row`, mapped to/from Domain models by a sibling `<Name>Row+Mapping.swift` extension in the same directory. (The rate/price *cache* records — `ExchangeRateRecord`, `CryptoPriceRecord`, `StockPriceRecord` — keep the `Record` suffix; domain-mirroring records use `Row`.)

### Layout

```
Domain/Models/Account.swift                      // Sendable; no GRDB import
Backends/GRDB/Records/AccountRow.swift           // Sendable; GRDB record protocols
Backends/GRDB/Records/AccountRow+Mapping.swift   // init(domain:) + var domain: Account
```

### Record protocols

| Protocol | Use when |
|---|---|
| `TableRecord` | Free with `PersistableRecord` |
| `FetchableRecord` | Every readable record |
| `PersistableRecord` | Stable PK (UUID): non-mutating `insert`, `update`, `upsert`, `delete` |
| `MutablePersistableRecord` | Autoincrement INTEGER PK only — moolah does not use this |
| `Record` (base class) | **Forbidden.** Discouraged in GRDB 7; subclassing fails review |

Moolah uses UUID PKs throughout; records adopt `PersistableRecord` only.

### Record shape

```swift
import GRDB

struct AccountRow: Codable, Sendable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "account"

    enum Columns: String, ColumnExpression, CaseIterable {
        case id, name, type, instrumentId, position, isHidden, encodedSystemFields
    }

    var id: UUID
    var name: String
    var type: String
    var instrumentId: String
    var position: Int
    var isHidden: Bool
    var encodedSystemFields: Data?
}
```

### `databaseSelection` must be `static var`

`[any SQLSelectable]` is non-Sendable. Stored = Swift 6 hard error.

```swift
// Wrong:
// static let databaseSelection: [any SQLSelectable] = [Columns.id, Columns.name]

// Right:
static var databaseSelection: [any SQLSelectable] {
    [Columns.id, Columns.name]
}
```

### Record ↔ Domain mapping lives in the extension

```swift
extension AccountRow {
    init(domain: Account) {
        self.init(
            id: domain.id,
            name: domain.name,
            type: domain.type.rawValue,
            instrumentId: domain.instrument.id,
            position: domain.position,
            isHidden: domain.isHidden,
            encodedSystemFields: nil
        )
    }

    var domain: Account {
        Account(
            id: id,
            name: name,
            type: AccountType(rawValue: type) ?? .bank,
            instrument: .fiat(code: instrumentId),
            position: position,
            isHidden: isHidden
        )
    }
}
```

### Records never leave `Backends/GRDB/`

Repositories return Domain values. Any `Record` type appearing in `Domain/`, `Features/`, or `App/` is Critical (backend isolation rule, mirrors the existing `CloudKit/` rule).

### `import GRDB` is forbidden under `Domain/` and `Features/`

Backend isolation. The reviewer treats either as Critical.

### `Decimal` is forbidden in record structs

GRDB stores `Decimal` as TEXT — string comparisons sort lexically and aggregations through implicit numeric coercion lose precision. Money is stored as a scaled `Int64` (the `Int64 × 10^8` representation behind `InstrumentAmount`); rates are `Double` stored as REAL. Any `Decimal` property in a record struct under `Backends/GRDB/Records/` is flagged.

### Date encoding

The project default is GRDB's Codable default: ISO-8601 TEXT. `databaseDateEncodingStrategy(for:)` overrides require an inline justifying comment per record. Every override is reviewed.

---

## 4. Querying

### Query interface vs raw SQL

Default to GRDB's **query interface** (`AccountRow.filter(Column.id == accountId).fetchOne(db)`) for simple lookups. Reach for **raw SQL** when:

- The query uses a SQL feature the interface can't express (window functions, recursive CTEs, complex aggregates).
- Performance demands a hand-tuned join or covering-index lookup.

### Parameterise. Always.

There is **exactly one unsafe shape**: a Swift `String` (built with `\()`, `String(format:)`, or `+`) passed to any GRDB API with the argument label `sql:`.

| Pattern | Verdict |
|---|---|
| `db.execute(sql: "UPDATE x SET n = ? WHERE id = ?", arguments: [n, id])` | Safe (positional bind) |
| `db.execute(sql: "UPDATE x SET n = :n WHERE id = :id", arguments: ["n": n, "id": id])` | Safe (named bind) |
| `db.execute(literal: "UPDATE x SET n = \(n) WHERE id = \(id)")` | Safe (`SQL` literal interpolation parameterises) |
| `AccountRow.filter(Column("id") == id).fetchOne(db)` | Safe (query interface) |
| `db.execute(sql: "UPDATE x SET n = '\(n)' WHERE id = \(id)")` | **Critical: SQL injection** |
| `db.execute(sql: someStringVariable)` (not a string literal) | **Critical: dynamic SQL** |
| `db.execute(sql: String(format: "SELECT %@", x))` | **Critical** |

**Project rule, greppable**: any `\.execute\(sql:` / `\.makeStatement\(sql:` / `\.fetch[A-Za-z]+\([^,]*,\s*sql:` / `cachedStatement\(sql:` whose `sql:` argument is not a string literal fails review.

For dynamic SQL composition use the `SQL` literal type (`db.execute(literal: "...\(value)...")`) — its interpolation parameterises automatically.

### Identifiers (table and column names)

SQLite cannot parameterise identifiers. For dynamic identifier substitution, validate against an allowlist before concatenation, in the same expression as the use:

```swift
guard let sortColumn = AccountRow.Columns(rawValue: userInput) else {
    throw RepositoryError.invalidSortColumn
}
let request = AccountRow.order(Column(sortColumn.rawValue))  // safe: closed set
```

Dynamic ORDER BY / table / column name from outside the data layer without an immediately-preceding allowlist assertion is Critical.

The `quote()` SQL function is for administrative dumping, never for substituting user-supplied values where binding works.

### Cursor row reuse

`RowCursor` recycles a single `Row` instance across iterations. Never store rows from a cursor:

```swift
// Wrong — yields N references to the same recycled row:
let rows = Array(try Row.fetchCursor(db, sql: "SELECT * FROM account"))

// Right — fetch as records, or copy:
let records = try AccountRow.fetchAll(db)
let rows = try Row.fetchCursor(db, sql: "...").map { $0.copy() }
```

Reference: [GRDB issue #303](https://github.com/groue/GRDB.swift/issues/303).

### Statement caching

Record CRUD methods (`insert`, `update`, `upsert`, `delete`, `fetchAll`, `fetchOne`) cache their statements internally. No manual caching needed.

For raw SQL inside a tight loop (e.g. CKSyncEngine batch upsert), use `db.cachedStatement(sql:)` instead of `db.makeStatement(sql:)` to skip re-preparation:

```swift
try database.write { db in
    let statement = try db.cachedStatement(sql: "INSERT INTO leg (id, ...) VALUES (?, ...)")
    for leg in legs {
        try statement.execute(arguments: [leg.id, ...])
    }
}
```

### Batch writes go in one transaction

```swift
// Wrong — opens N transactions, N fsyncs:
for record in records {
    try await database.write { db in try record.insert(db) }
}

// Right — one transaction, one fsync:
try await database.write { db in
    for record in records { try record.insert(db) }
}
```

### `SELECT *` and column-less `INSERT`

- `SELECT *` is forbidden in production data-layer code (test fixtures excepted). Column order shifts on migration; raw consumers break silently.
- `INSERT INTO t VALUES(...)` without an explicit column list is forbidden. Adding a column to the table breaks unrelated INSERT sites silently.

---

## 5. Transactions

- `database.write { ... }` opens an `IMMEDIATE` transaction. Default deferred transactions are not used — they fail with `SQLITE_BUSY` on first write under any concurrent writer.
- Every multi-statement write must be inside the same `write` closure (one transaction, one rollback boundary).
- Every multi-statement write must have a paired test asserting that a thrown error inside the closure leaves the database unchanged.
- `database.read { ... }` opens a deferred read transaction with snapshot isolation. Compiler refuses mutating methods inside.

```swift
func payScheduledTransaction(_ tx: Transaction) async throws -> PayResult {
    try await database.write { db in
        let saved = try TransactionRow(domain: tx).insert(db)
        // Clear the recurrence on the scheduled template (recurrence is
        // stored as fields on TransactionRow, not a separate table).
        try TransactionRow
            .filter(Column("id") == tx.scheduledId)
            .updateAll(db, Columns.recurPeriod.set(to: nil))
        return PayResult(...)
    }
}
```

A `BEGIN` or `BEGIN DEFERRED` for any write-bearing transaction is Critical. Loops that open one transaction per row are Important.

---

## 6. Query Plan Tests

Index decisions are a schema concern (see `DATABASE_SCHEMA_GUIDE.md` §4). Whether a query *uses* the right index is a code concern, verified by `EXPLAIN QUERY PLAN`-pinning unit tests.

### Why mandatory

Reviewers run pre-PR against the working tree only; they cannot read PR descriptions or commit messages. The unit test is the auditable artefact that says "this query is indexed correctly". Plan regressions break the build immediately rather than going unnoticed until production.

### Diagnostic tokens to recognise

- `SCAN <table>` — full or index-ordered scan. Bad for selective reads.
- `SEARCH <table> USING INDEX <name> (col=?)` — index used.
- `SEARCH <table> USING COVERING INDEX <name> (col=?)` — covering, no row fetch. Best.
- `USE TEMP B-TREE FOR ORDER BY` — the sort wasn't avoidable with the current indexes; consider extending.

### Pattern

```swift
@Test
func incomeAndExpenseUsesCoveringIndex() async throws {
    let queue = try await MigratedTestQueue.profileDB()
    try await queue.read { db in
        let plan = try Row.fetchAll(db, sql: """
            EXPLAIN QUERY PLAN
            SELECT t.date, l.amount
            FROM "transaction" t
            JOIN leg l ON l.transaction_id = t.id
            WHERE t.is_scheduled = 0
            """).map { $0[0] as String }
        #expect(plan.contains { $0.contains("USING COVERING INDEX") })
        #expect(!plan.contains { $0.contains("SCAN") })
    }
}
```

### Rules

- A perf-critical query without a paired plan-pinning test is Important.
- A plan test that allows `SCAN <table>` or `USE TEMP B-TREE FOR ORDER BY` without a justifying comment is Important.
- "Perf-critical" includes any query that runs on the main path of an analysis screen, sidebar total, list refresh, or sync-merge loop. When in doubt, write the test.

---

## 7. Testing

### `:memory:` for behaviour tests

```swift
import GRDB
import Testing
@testable import Moolah

@Suite
final class GRDBAccountRepositoryTests {
    let queue: DatabaseQueue

    init() throws {
        queue = try DatabaseQueue()  // in-memory
        try ProfileSchema.migrator.migrate(queue)
    }

    @Test
    func upsertAndFetchRoundTrip() async throws {
        let repo = GRDBAccountRepository(database: queue)
        let account = Account(name: "Checking", ...)
        try await repo.upsert(account)
        let loaded = try await repo.accounts()
        #expect(loaded == [account])
    }
}
```

`DatabaseQueue()` (no path) is the canonical in-memory form. Don't pass `":memory:"` explicitly.

### Per-test temp dir for tests that exercise the open path

Tests that exercise schema-version mismatch handling, sidecar cleanup, file-recreation paths, or migrations against a real on-disk file must use a per-test temp directory:

```swift
@Suite
final class ProfileDBOpenTests {
    let tempDir: URL

    init() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: tempDir) }
}
```

Reference: `MoolahTests/Backends/SQLiteCoinGeckoCatalogStorageTests.swift:11-23`.

### `@Suite(.serialized)`

Required on any suite that mutates process-global state — `URLProtocol` registrations, unscoped `UserDefaults.standard`, or file handles outside the temp directory.

### Test seams: `*ForTesting` accessor pattern

Production stores expose only their public API. Test seams (counters, fixture loaders, internal-state inspectors) live in a documented test-seam extension named with the `…ForTesting` suffix:

```swift
extension GRDBAccountRepository {
    func accountCountForTesting() async throws -> Int {
        try await database.read { db in try AccountRow.fetchCount(db) }
    }
}
```

Tests never poke private state via `@testable` for behaviour they could exercise through public API + a `ForTesting` seam. Production methods never carry the `ForTesting` suffix.

### Rollback tests

Every multi-statement write has a rollback test: seed prior state, trigger a constraint violation mid-transaction, assert the database is unchanged. Reference: `SQLiteCoinGeckoCatalogStorageTests.testReplaceAllRollsBackOnConstraintFailure`.

### Plan-pinning tests

See §6.

---

## 8. CKSyncEngine integration (boundary)

The full sync model lives in `guides/SYNC_GUIDE.md`. Code-side specifics:

- Each apply-remote-changes batch is a single `database.write` transaction. A partial apply must roll back; the next sync cycle re-delivers the failed batch.
- `encoded_system_fields` bytes are bit-for-bit copies; never decode or interpret them outside the `Backends/CloudKit/Sync/` boundary.
- Use `db.cachedStatement(sql:)` for the per-record upsert in batch-apply loops.

---

## 9. Adding-a-table checklist (code side)

When adding a new table to the profile DB:

- [ ] One record type under `Backends/GRDB/Records/<Name>Row.swift`, `Sendable`, `Codable`, conforms to `FetchableRecord, PersistableRecord`.
- [ ] `enum Columns: String, ColumnExpression, CaseIterable` matching the SQL columns.
- [ ] Domain ↔ Row mapping under `Backends/GRDB/Records/<Name>Row+Mapping.swift`.
- [ ] Repository in `Backends/GRDB/Repositories/GRDB<Name>Repository.swift`, a `final class` marked `@unchecked Sendable`, async-only.
- [ ] No `Decimal` properties on the record.
- [ ] `databaseSelection` (if overridden) is `static var`.
- [ ] No `import GRDB` outside `Backends/GRDB/`; no record types referenced from `Domain/`, `Features/`, `App/`.
- [ ] Behaviour tests using in-memory `DatabaseQueue`.
- [ ] Rollback test for any multi-statement write.
- [ ] Plan-pinning test for any perf-critical query.
- [ ] `database-code-review` agent run before opening the PR.

For the schema-side checklist (migrations, indexes, PRAGMAs, lifecycle), see `DATABASE_SCHEMA_GUIDE.md` §10.
