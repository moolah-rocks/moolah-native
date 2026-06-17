# Task 1 Report: v8 Migration `first_traded_on` Column

## Implementation Summary

Successfully implemented the v8 database migration that adds a nullable `first_traded_on` TEXT column to the `crypto_token_meta` table in the app-scoped `profile-index.sqlite` database. This column stores the confirmed cross-provider first-trade date (ISO YYYY-MM-DD format) for crypto tokens. NULL values indicate "not yet confirmed" dates. Pre-first-trade prices are valued at $0 (.knownZero) by the crypto price path.

## Files Created/Modified

### Created Files
1. **`Backends/GRDB/ProfileIndexSchema+CryptoFirstTradedOn.swift`** — Migration body file containing:
   - `addCryptoFirstTradedOn(_:)` function that executes the `ALTER TABLE` statement
   - Detailed doc comment explaining the feature and design context

2. **`MoolahTests/Backends/CryptoFirstTradedOnMigrationTests.swift`** — Test suite with two test cases:
   - `addsColumnPreservingRows()` — verifies v8 adds the column and preserves existing rows
   - `columnIsWritable()` — verifies the new column can be written to after v8

### Modified Files
1. **`Backends/GRDB/ProfileIndexSchema.swift`**:
   - Added v8 migration to the doc comment history
   - Bumped `static let version = 7` to `static let version = 8`
   - Registered the v8 migration: `migrator.registerMigration("v8_crypto_first_traded_on", migrate: addCryptoFirstTradedOn)`

2. **`MoolahTests/Backends/GRDB/ProfileIndexSchemaV3Tests.swift`**:
   - Updated version assertion from 7 to 8 with updated comment

## TDD Evidence

### RED State (Test Failures Before Implementation)
```
Command: just test-mac CryptoFirstTradedOnMigrationTests
Output snippet:
  Test "v8 adds nullable first_traded_on and preserves existing rows" failed 
    Error: SQLite error 1: no such column: first_traded_on
  Test "first_traded_on is writable after v8" failed
    Error: SQLite error 1: table crypto_token_meta has no column named first_traded_on
Reason: Migration not yet implemented; column didn't exist.
```

### GREEN State (All Tests Passing)
```
Command: just test-mac CryptoFirstTradedOnMigrationTests ProfileIndexSchemaV3Tests
Final Output:
  Test run with 11 tests in 2 suites passed after 0.037 seconds.
All 11 tests passed:
  - 2 new tests in CryptoFirstTradedOnMigrationTests (both passed)
  - 9 existing tests in ProfileIndexSchemaV3Tests (all still passed)
```

## Format Check Verification

```
Command: just format-check
Result: All Swift files are correctly formatted.
```

Initial SwiftLint violations for short variable names (`db`, `c`, `f`) were fixed by renaming:
- `db` → `database`
- `c` → `rowCount`
- `f` → `firstTradedValue`

## Self-Review Findings

### Strengths
1. **TDD discipline**: Created failing test first, verified failure for correct reason, then implemented
2. **Migration body isolation**: Follows project convention using sibling `+CryptoFirstTradedOn.swift` file
3. **Backward compatibility**: ALTER TABLE ADD COLUMN with NULL default preserves existing rows
4. **Schema versioning**: Version correctly bumped and consistent across all three locations (schema, test assertion, migration history doc comment)
5. **Documentation**: Clear doc comments explaining purpose and design context

### Code Quality
- Migration body is minimal and focused (single-line SQL execution)
- Test coverage includes both happy path and edge cases (preserve on existing rows, write new values)
- Proper nullable column type (TEXT not TEXT NOT NULL) as specified
- All tests pass without warnings
- Swift formatting and linting compliance achieved

### Database Design Notes
- Column is nullable by design (NULL = "not yet confirmed" per design spec)
- ISO date format (TEXT) is consistent with other date columns in the schema
- No CHECK constraints, indexes, or foreign keys needed at this stage
- Future plan logic will convert pre-first-trade prices to $0 (.knownZero)

## Concerns

None. Task completed cleanly with:
- All tests RED then GREEN per TDD
- Format check passing
- Commit created successfully
- No schema design issues or constraint violations
- No dependency issues on the v7_purge_crypto_price_cache migration

## Commit

```
468e084d feat(crypto): add crypto_token_meta.first_traded_on (v8)
```

Changes:
- 4 files modified (2 created, 2 updated)
- 76 insertions, 3 deletions
- All files committed atomically in one commit
