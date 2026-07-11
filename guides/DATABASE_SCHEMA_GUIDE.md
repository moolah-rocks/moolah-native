# Moolah Database Schema Guide

**Version:** 1.0
**Platform targets:** macOS 26+ (primary), iOS 26+ (secondary)
**Engine:** SQLite (system-provided), accessed via [GRDB.swift](https://github.com/groue/GRDB.swift).

This guide governs **what's in the database**: file layout, schemas, indexes, PRAGMAs, migrations, and on-disk lifecycle. For **how Swift code talks to the database** — records, repositories, queries, transactions, tests — see `guides/DATABASE_CODE_GUIDE.md`. Both guides are non-optional and complement each other; a typical "add a new table" change touches both.

---

## 1. Philosophy

Schema is contract. Once a table or column has shipped to a tagged release, the only legal way to change it is a forward-only, named migration that runs on every existing install. Indexes, PRAGMAs, and CHECK constraints are part of the contract too.

**Core rules:**

1. Every table is `STRICT`. Financial data must never silently coerce.
2. Migrations are immutable once shipped. Edits to a shipped migration are Critical.
3. Drop-and-recreate is forbidden for the profile DB. It is allowed only for derived caches whose source of truth is elsewhere (network, CloudKit).
4. One DB per data domain. Never split a single profile across files.
5. Every CloudKit-synced table has UNIQUE on the record-name column. Without it, sync convergence yields silent duplicates.

### Key sources

- SQLite documentation: [STRICT](https://sqlite.org/stricttables.html), [WITHOUT ROWID](https://sqlite.org/withoutrowid.html), [WAL](https://sqlite.org/wal.html), [PRAGMA](https://sqlite.org/pragma.html), [ALTER TABLE](https://sqlite.org/lang_altertable.html), [datatype](https://sqlite.org/datatype3.html), [CREATE INDEX](https://sqlite.org/lang_createindex.html), [foreign keys](https://sqlite.org/foreignkeys.html).
- GRDB documentation: [Migrations](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/Migrations.md), [DatabaseSchemaRecommendations](https://github.com/groue/GRDB.swift/blob/master/GRDB/Documentation.docc/DatabaseSchemaRecommendations.md).
- Project precedent: `Backends/CoinGecko/SQLiteCoinGeckoCatalog.swift` and `CoinGeckoCatalogSchema.swift` (raw-`sqlite3` actor, predates GRDB).
- `guides/SYNC_GUIDE.md` governs the CKSyncEngine glue tables.

---

## 2. Database Layout

### File location

Per-profile databases:

```
~/Library/Application Support/moolah/profiles/<profile-id>/data.sqlite
                                                          /data.sqlite-wal
                                                          /data.sqlite-shm
```

Cross-profile / global SQLite caches sit elsewhere under `Application Support/moolah/` with their own subdirectory (the existing CoinGecko catalog is the precedent).

### One DB per data domain. Never split a single profile across files.

A single profile's synced data, per-profile rate caches, and CKSyncEngine glue all live in one `data.sqlite`. Splitting a profile across files would break the consistency boundary that sync, backup, and migrations rely on.

A new SQLite file is justified only when the data has materially different access patterns, durability needs, or lifetime to existing per-profile data — for example a global catalog (CoinGecko) or a future cross-profile cache. Any new database file must record its rationale in the schema file's doc comment. The reviewer flags new `*.sqlite` files without a recorded rationale.

### Lifecycle ownership

A profile's `DatabaseQueue` is owned by `ProfileSession`. Open on profile activation; close on profile switch / sign-out / delete. Each active profile has exactly one queue.

Cross-profile databases are owned by app-scoped service instances; their lifecycles are independent of `ProfileSession`.

### One `Schema.swift` per database

Each database has exactly one Swift file describing its full schema:

- `static let version: Int` (callable from open-time integrity checks).
- `static var migrator: DatabaseMigrator` for GRDB databases (`static let statements: [String]` for the legacy raw-`sqlite3` CoinGecko catalog).
- Schema is never inlined into a repository or service.

Reference: `Backends/CoinGecko/CoinGeckoCatalogSchema.swift`.

---

## 3. Schema

### `STRICT` every table

```sql
CREATE TABLE account (
    id              BLOB NOT NULL PRIMARY KEY,
    name            TEXT NOT NULL,
    type            TEXT NOT NULL CHECK (type IN ('bank', 'credit_card', 'investment', 'other')),
    instrument_id   TEXT NOT NULL,
    position        INTEGER NOT NULL CHECK (position >= 0),
    is_hidden       INTEGER NOT NULL CHECK (is_hidden IN (0, 1)),
    encoded_system_fields BLOB
) STRICT;
```

`STRICT` raises `SQLITE_CONSTRAINT_DATATYPE` on any value that cannot be losslessly stored in the declared type.

In `STRICT`, the only column types are `INT`, `INTEGER`, `REAL`, `TEXT`, `BLOB`, `ANY`. NUMERIC affinity does not exist. Use `ANY` only when a schema legitimately mixes bytes and text — never as a workaround for type uncertainty.

The only exempt tables are FTS5 virtual tables and SQLite's own `sqlite_*` tables.

### `WITHOUT ROWID` decision rule

| Table shape | `WITHOUT ROWID`? |
|---|---|
| Single `INTEGER PRIMARY KEY` | No (rowid table is faster) |
| Composite small-row keyed table (`pending_change`, `exchange_rate`) | Yes |
| Single `TEXT` / `BLOB PRIMARY KEY` lookup table | Yes |
| Encoded-system-fields blob column dominates row size | No |
| Audit / log tables with large text bodies | No |

Not a blanket policy. Decide per table.

### Column-type conventions

| Domain | SQL column type | Rationale |
|---|---|---|
| `Int` cents (money) | `INTEGER NOT NULL` | Source of truth for monetary values; never `REAL` |
| FX / stock / crypto rate (`Double`) | `REAL NOT NULL` | Bounded precision; aggregable |
| `String` | `TEXT NOT NULL` | |
| `Bool` | `INTEGER NOT NULL CHECK (col IN (0, 1))` | SQLite has no Bool; `CHECK` pins the storage |
| `Date` | `TEXT NOT NULL` (ISO-8601) | GRDB Codable default; round-trips losslessly |
| `UUID` | `BLOB NOT NULL` (16 bytes) | GRDB default; smaller than TEXT |
| `Data` (e.g. `encoded_system_fields`) | `BLOB` | |

`Decimal` is forbidden in record structs (see `DATABASE_CODE_GUIDE.md` §3). Convert to `Int` cents at the mapping boundary.

### Naming

- `snake_case` for tables and columns.
- Primary keys named `id` for record-identity tables; composite keys named after their parts.
- Foreign-key columns end in `_id` (`account_id`, `transaction_id`).
- CKSyncEngine glue: `encoded_system_fields BLOB`, `pending_change(record_type, record_name, …)`. See `guides/SYNC_GUIDE.md`.

### `CHECK` constraints

Use freely on enum-shaped TEXT columns and bounded INTEGERs. They are part of the contract, not a comment.

```sql
type TEXT NOT NULL CHECK (type IN ('income', 'expense', 'transfer', 'opening_balance')),
position INTEGER NOT NULL CHECK (position >= 0),
```

JSON-shaped columns must include `CHECK (json_valid(col))`.

### `SELECT *` and column-less `INSERT` are forbidden in migrations and DDL

- Migration `INSERT INTO new_t SELECT * FROM old_t` is acceptable in the table-rebuild pattern (see §6) only when the column lists are guaranteed identical.
- `INSERT INTO t VALUES(...)` without an explicit column list is forbidden in any production code, including data-fixup migrations. Adding a column to the table later breaks unrelated INSERT sites silently.

---

## 4. Indexes

### Indexing rules

- **Covering index**: the index contains every column the query reads, so the planner can answer from the index alone. Roughly halves selective-read time.
- **Partial index** (`CREATE INDEX … WHERE …`): indexes only matching rows. Use for sparse states (`WHERE pending_sync = 1`).
- **Composite-key column order**: equality first (most-selective first), range and ORDER BY last. The query uses the index only if it constrains a left-prefix.
- **No prefix duplicates**: if index A's columns are a prefix of index B's, drop A.
- **UNIQUE on natural keys** is mandatory for every CloudKit-synced table — without it, sync convergence yields silent duplicates.
- **FK child indexes**: every foreign-key column needs a child-side index, or parent updates / deletes scan the child table.

Each index costs storage and write amplification. ~3 indexes on a write-heavy table is a soft ceiling; reports tables can carry more.

### Index decisions are schema decisions; index *use* is a code concern

Whether the right index exists is a schema review. Whether a query uses it is a code review — verified by `EXPLAIN QUERY PLAN`-pinning unit tests, covered in `DATABASE_CODE_GUIDE.md` §6. Both reviewers should be run when adding indexes for a new query.

---

## 5. PRAGMAs

Set in GRDB's `Configuration.prepareDatabase` so every connection sees them. Values come from sqlite.org documentation; rationale below the table.

```swift
var config = Configuration()
config.prepareDatabase { db in
    try db.execute(sql: """
        PRAGMA foreign_keys = ON;
        PRAGMA synchronous = NORMAL;
        PRAGMA busy_timeout = 5000;
        PRAGMA temp_store = MEMORY;
        PRAGMA cache_size = -8000;        -- 8 MB
        PRAGMA mmap_size = 0;             -- disabled (iOS jetsam pressure)
        PRAGMA optimize = 0x10002;        -- once per long-lived connection
        """)
}
```

| PRAGMA | Value | Persistence | Rationale |
|---|---|---|---|
| `journal_mode` | `WAL` | Persistent (header) | Set once at DB creation; verified on every open |
| `synchronous` | `NORMAL` | Per-connection | Documented best balance of safety and performance under WAL |
| `foreign_keys` | `ON` | Per-connection | Off by default for back-compat — must be set explicitly |
| `busy_timeout` | `5000` ms | Per-connection | Required under WAL so writers auto-retry on `SQLITE_BUSY` |
| `temp_store` | `MEMORY` | Per-connection | Avoids disk for transient B-trees |
| `cache_size` | `-8000` (8 MB) | Per-connection | Negative argument = bytes, not pages |
| `mmap_size` | `0` (disabled) | Per-connection | iOS jetsam pressure outweighs the read benefit at moolah's data sizes; mirrors Apple's Core Data default |
| `page_size` | `4096` (default) | Persistent; only at create | Standard; do not deviate |
| `secure_delete` | `OFF` (default) | Per-connection | iOS sandboxing makes the threat model moot |

### `PRAGMA optimize` cadence

- `PRAGMA optimize = 0x10002` once when each long-lived connection opens.
- `PRAGMA optimize` (default arguments) on app resign-active and at most once per hour while active.

### Forbidden PRAGMA values

- `synchronous = OFF` — Critical.
- `journal_mode = MEMORY` or `OFF` — Critical.
- `legacy_alter_table = 1` — Critical (reverts pre-3.25 RENAME safety).
- `secure_delete = ON` without an inline justification comment — flag.

### Forbidden flags

- `SQLITE_OPEN_FULLMUTEX` — Important. The actor / queue already serialises; FULLMUTEX is wasted contention. The only existing site is `SQLiteCoinGeckoCatalog.swift:88` and it predates GRDB.

---

## 6. Migrations

### `DatabaseMigrator` with stable string IDs

```swift
enum ProfileSchema {
    static let version = 3

    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_initial") { db in
            try db.execute(sql: """
                CREATE TABLE account (...) STRICT;
                CREATE INDEX account_by_position ON account (position);
                ...
                """)
        }

        migrator.registerMigration("v2_add_account_archived_state") { db in
            try db.execute(sql: """
                ALTER TABLE account
                    ADD COLUMN archived_state TEXT NOT NULL DEFAULT 'active'
                    CHECK (archived_state IN ('active', 'archived'));
                CREATE INDEX account_by_archived_state
                    ON account (archived_state) WHERE archived_state = 'archived';
                """)
        }

        return migrator
    }
}
```

### Rules

1. **Migrations are immutable once shipped.** Never edit the body or the ID of a migration that has been on a tagged release. Doing so silently breaks installed users — GRDB persists the applied-migration IDs and skips any it has already seen, but the resulting schema diverges from the new code's expectations. CI runs a golden test diffing `sqlite_master` after a full migrator run on an empty queue; any change requires the diff to update with intent.
2. **IDs are string literals.** `"v1_initial"`, not `Schema.v1.rawValue`. The literal is the stable ID; it must not flow through a Swift type.
3. **One transaction per migration.** GRDB wraps each migration; if the body throws, the migration rolls back and subsequent migrations don't run. Nesting `BEGIN` / `COMMIT` inside a migration is forbidden.
4. **Migration code is decoupled from app code.** Use string table / column names, never `AccountRecord.databaseTableName`. The v1 migration must keep compiling unchanged through every later refactor.
5. **`eraseDatabaseOnSchemaChange = true` is forbidden for app/user databases.** Debug builds can open meaningful Development profiles, so automatic database recreation is data loss. Recover branch-local Development schema experiments with `just reset-development-data`, not app startup code.
6. **Foreign-key handling.** `DatabaseMigrator` disables FK enforcement, runs the migration, runs `PRAGMA foreign_key_check` before commit. For migrations that **rename FK columns**, set `foreignKeyChecks: .immediate`. For migrations that **recreate a table** (the standard ALTER workaround), do not use `.immediate`.

   **Per-profile schema is FK-free.** As of `v5_drop_foreign_keys`, the per-profile `data.sqlite` schema declares no foreign keys. CKSyncEngine has no parent-before-child guarantee within or across batches, and an FK-enforced child insert can fault the entire write transaction and trap the sync coordinator in an infinite re-fetch loop. Integrity is enforced at the application boundary — repository sync entry points (`applyRemoteChangesSync`) and domain `delete(...)` methods replicate the cascade / null-out semantics the FKs used to provide. See `guides/SYNC_GUIDE.md` "Per-profile schema does not enforce FKs" for the contract.

7. **Drop-and-recreate is forbidden for the profile DB.** Allowed only for derived caches whose source of truth is elsewhere (network, CloudKit) — currently CoinGecko. A `DROP TABLE` outside a `DatabaseMigrator` registration on a profile DB is Critical.

### `ALTER TABLE` and the rebuild pattern

SQLite's native operations cover most changes:

- `RENAME TABLE`, `RENAME COLUMN`, `ADD COLUMN`, `DROP COLUMN`.
- `ADD COLUMN` restrictions: no PRIMARY KEY / UNIQUE; no `CURRENT_*` defaults; NOT NULL needs a constant default; REFERENCES must default NULL when FKs are on; no `GENERATED ALWAYS … STORED`.

For changes the native operations can't cover (column type change, adding NOT NULL with no default, dropping an indexed/referenced column, reordering, adding/removing CHECK), use the documented table-rebuild:

```sql
PRAGMA foreign_keys = OFF;
BEGIN;
  CREATE TABLE new_X ( ... );
  INSERT INTO new_X SELECT ... FROM X;  -- explicit column list when columns differ
  DROP TABLE X;
  ALTER TABLE new_X RENAME TO X;
  -- recreate indexes, triggers, views
  PRAGMA foreign_key_check;
COMMIT;
PRAGMA foreign_keys = ON;
```

`DatabaseMigrator` wraps each migration in a transaction for you. Do not use `PRAGMA legacy_alter_table` — it reverts pre-3.25 RENAME safety.

---

## 7. Lifecycle & Backup

### No automatic data loss

App startup and migration code must never delete, truncate, replace,
drop-and-recreate, or auto-erase user/profile databases as recovery from a
schema mismatch. This includes Debug-only code: local Development profiles can
hold real imported data and must fail loudly instead of being silently reset.

The only approved local recovery path for branch-local schema experiments is
explicit developer tooling with hard Development/Production path guards. Use
`just reset-development-data` to wipe the local Development zone when a
rolled-back migration leaves it unrecoverable.

### System backup is the default

Per-profile databases live in `Application Support/`, which is included in iOS device backup and captured atomically by Time Machine on macOS. **No `VACUUM INTO` scaffolding is needed for everyday backup.** The SQLite "WAL backup safety" warnings apply to user-initiated single-file copies, not to filesystem-level backup primitives.

### In-app copy / export must use `VACUUM INTO`

Any code path that copies a SQLite file at runtime (export, debug snapshot, support bundle) **must** use `VACUUM INTO 'path'` or `db.backup(to:)`, not `FileManager.copyItem`. Reasons:

- Copying `data.sqlite` while the WAL holds uncommitted-to-main pages produces a stale snapshot.
- Copying without the `-wal` and `-shm` sidecars can lose committed transactions.
- `VACUUM INTO` produces a fresh, self-contained, sidecar-free file safe to archive immediately.

### Sidecar cleanup on file removal

Any `FileManager.removeItem` on a SQLite file path **must** also `try?` remove the `-wal` and `-shm` sidecars. Reference: `SQLiteCoinGeckoCatalog.swift:71-76`.

### iOS suspend / resume

iOS apps can be suspended at any time, with the WAL still open. GRDB's `DatabaseQueue` handles suspension correctly out of the box (it serialises through its queue and re-acquires file locks on resume). Do not hand-roll close / reopen on `applicationDidEnterBackground`.

If a future code path explicitly suspends the queue, mirror NetNewsWire's pattern: `assertionFailure` on double-suspend and double-resume.

### `wal_checkpoint`

Auto-checkpoint runs PASSIVE on commit when the WAL crosses 1000 pages (~4 MB). Do not call `wal_checkpoint(TRUNCATE)` on every commit — that defeats WAL. Call it only before an out-of-band file copy (which we do not do; see above).

---

## 8. CKSyncEngine integration (boundary)

The full sync model lives in `guides/SYNC_GUIDE.md`. Schema-side specifics:

- Every synced record table carries an `encoded_system_fields BLOB` column for the CloudKit system fields. The bytes are bit-for-bit copies; never decode or interpret them outside the `Backends/CloudKit/Sync/` boundary.
- Every synced table requires a UNIQUE index on the column the engine uses as `CKRecord.ID.recordName` (typically `id`). Without it, sync convergence yields silent duplicates.
- The `pending_change` table is the local outbox for queued sends. CKSyncEngine's `stateSerialization` blob lives in a dedicated `sync_state` row.

---

## 9. Cache table conventions

Cache tables (rate caches, future derived caches) follow extra rules on top of the schema rules above:

- **Documented retention policy.** Either a TTL with a scheduled purge migration / job, or an explicit "kept forever" doc-comment justifying it (rate data is kept forever for historic-conversion correctness). Tables with no policy are flagged.
- **Refresh ordering.** `last_fetched`-equivalent metadata is written *after* the data write succeeds. A network failure leaves prior state intact and the next launch retries. Reference: `SQLiteCoinGeckoCatalog+Refresh.swift:55-62`.
- **"No change" modelled as a sum type.** Refresh paths never overload `[]` to mean "use previous snapshot". Use a sum type — `unchanged` vs `replace([])` — at the boundary that takes the snapshot. Reference: `CoinsUpdate` in `SQLiteCoinGeckoCatalog+Refresh.swift:97-105`.
- **Drop-and-recreate is acceptable** for cache tables where source of truth is elsewhere, but the recreate path must remove `-wal` / `-shm` sidecars too (see §7).

---

## 10. Adding-a-table checklist (schema side)

When adding a new table to the profile DB:

- [ ] Migration registered in `ProfileSchema.migrator` with the next stable string ID per §6.
- [ ] Schema is `STRICT`; types match §3.
- [ ] `WITHOUT ROWID` decision made per §3 rule.
- [ ] Indexes for: every UNIQUE natural key; every foreign-key column; every WHERE / ORDER-BY column on a perf-critical query.
- [ ] No prefix-duplicate indexes.
- [ ] If synced via CKSyncEngine: `encoded_system_fields BLOB` column, UNIQUE on the record-name column.
- [ ] If a cache table: documented retention policy per §9.
- [ ] `database-schema-review` agent run before opening the PR.

When adding a new SQLite file (cross-profile cache, etc.):

- [ ] Justification recorded in the schema file's doc comment per §2.
- [ ] One `Schema.swift` per file (§2).
- [ ] PRAGMAs match §5.
- [ ] Sidecar cleanup on file removal (§7).
- [ ] Lifecycle owner documented (which `actor` / service holds the queue).

For the Swift-side checklist (records, mapping, repository, tests), see `DATABASE_CODE_GUIDE.md` §9.
