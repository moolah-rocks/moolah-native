# Benchmarking Guide

Reference guide for writing, running, and interpreting performance benchmarks in this project.

## First Principle: Measure, Don't Assume

Never guess at performance. Don't assume what's fast or slow, don't set targets from intuition, don't skip benchmarking because something "should" be fine. Run the benchmark, read the numbers. If a result surprises you, that's the benchmark doing its job. Every optimization decision must start with a measurement and end with a measurement that confirms the improvement.

## Running Benchmarks

```bash
# Ensure the temp directory exists
mkdir -p .agent-tmp

# Run all benchmarks and capture output
just benchmark 2>&1 | tee .agent-tmp/benchmark-output.txt

# Run a specific benchmark class
just benchmark TransactionFetchBenchmarks 2>&1 | tee .agent-tmp/benchmark-output.txt

# Run a specific test method
just benchmark TransactionFetchBenchmarks/testFetchByAccount_1x 2>&1 | tee .agent-tmp/benchmark-output.txt

# Check results
grep -A2 "measured" .agent-tmp/benchmark-output.txt

# Get context around a specific benchmark
grep -B5 -A10 'testFetchByAccount' .agent-tmp/benchmark-output.txt

# Clean up when done
rm .agent-tmp/benchmark-output.txt
```

**Always pipe output to a file** in `.agent-tmp/` so you can inspect results without re-running. Benchmarks take minutes — don't waste time re-running just to re-read output.

Benchmarks run on macOS only (no simulator overhead). They use an in-memory GRDB database via `TestBackend`, so they measure computation and SQLite query cost — not disk I/O.

## When to Write a Benchmark

Add a benchmark when:

- **Adding a new repository method** that fetches or aggregates data. Any `fetch`, `fetchAll`, or computed query needs a benchmark at realistic scale.
- **Changing sync batch processing** — upsert logic, record lookups, balance invalidation.
- **Changing a hot-path data transformation** — `toDomain()`, `from()`, `fieldValues(from:)`.
- **Suspecting a performance problem** — write the benchmark first to get a baseline, then optimize.

You do not need a benchmark for:
- Single-record CRUD operations (create, update, delete one record).
- UI-only changes with no data layer impact.
- Changes to code that runs once at startup (not in a loop or called per-record).

## Writing Effective Benchmarks

### Structure

Each benchmark class focuses on one operation group. Data is seeded once in `setUpWithError()`, not per-test. Each test method measures one specific scenario.

```swift
final class TransactionFetchBenchmarks: XCTestCase {
  private var backend: CloudKitBackend!
  private var database: DatabaseQueue!

  override func setUpWithError() throws {
    let result = try TestBackend.create()
    backend = result.backend
    database = result.database
    BenchmarkFixtures.seed(scale: .oneX, in: database)
  }

  override func tearDownWithError() throws {
    backend = nil
    database = nil
  }

  func testFetchByAccount_1x() {
    let repo = backend.transactions
    let filter = TransactionFilter(accountId: BenchmarkFixtures.heavyAccountId)

    let options = XCTMeasureOptions()
    options.iterationCount = 10

    measure(metrics: [XCTClockMetric(), XCTMemoryMetric()], options: options) {
      _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
    }
  }
}
```

### Naming Convention

`test<Operation>_<Variant>_<Scale>`

Examples:
- `testFetchByAccount_1x` / `testFetchByAccount_2x`
- `testBatchUpsert_insertHeavy_1x`
- `testBuildRecordLookup_400records`
- `testToDomain_5000records`

### Data Seeding Rules

1. **Use `BenchmarkFixtures`** for all data seeding. It produces realistic distributions matching the live iCloud profile.
2. **Seed once per class** in `setUpWithError()`. Re-seeding per test wastes time and the data doesn't change.
3. **Use deterministic data.** Fixed UUIDs, sequential dates, predictable payee/category assignment. This makes results reproducible.
4. **Two scale tiers:** 1x (current real data) and 2x (growth target). Always benchmark both to observe scaling.

### Measurement Rules

1. **Always use `XCTClockMetric()` and `XCTMemoryMetric()`** together. Wall clock tells you what the user feels; memory tells you if you're loading too much into RAM.

2. **Use 10 iterations** (`options.iterationCount = 10`). XCTest's default of 5 is too few for noisy operations.

3. **No per-iteration store reset is needed for fetch benchmarks.** GRDB decodes a fresh value-type row on every fetch and keeps no cross-fetch identity map or change tracker, so later iterations don't drift the way SwiftData's accumulated objects did. Reuse the same in-memory database from `TestBackend.create()` across iterations:

   ```swift
   measure(metrics: metrics, options: options) {
     _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
   }
   ```

4. **Use `autoreleasepool`** in tight conversion loops to prevent memory accumulation:

   ```swift
   measure(metrics: metrics, options: options) {
     autoreleasepool {
       let results = records.map { $0.toDomain() }
       _ = results.count  // prevent dead-code elimination
     }
   }
   ```

5. **Prevent dead-code elimination.** The compiler may optimize away unused results. Assign results to `_` or access `.count` to ensure the work actually happens.

6. **Don't mix setup with measurement.** If a benchmark needs specific state (e.g., nil cachedBalances), set that up before the `measure` block, not inside it.

### Async Bridging

Repository methods are `async`. XCTest `measure` blocks are synchronous. Use the `awaitSync` helper (defined in `MoolahBenchmarks/Support/BenchmarkHelpers.swift`) to bridge:

```swift
measure(metrics: metrics, options: options) {
  _ = try! awaitSync { try await repo.fetch(filter: filter, page: 0, pageSize: 50) }
}
```

The helper uses RunLoop spinning to keep the main thread responsive while async work (including `MainActor.run`) completes. **Do not use semaphores** — they deadlock because XCTest runs measure blocks on the main thread, and our repositories dispatch to `MainActor`.

## Adding Signposts

When you add a new repository method or sync operation, add signpost instrumentation.

### Coarse Signposts (Required)

Every public repository or sync method gets a begin/end pair:

```swift
import os

func fetch(filter: TransactionFilter, page: Int, pageSize: Int) async throws -> TransactionPage {
  let signpostID = OSSignpostID(log: Signposts.repository)
  os_signpost(.begin, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID)
  defer { os_signpost(.end, log: Signposts.repository, name: "TransactionRepo.fetch", signpostID: signpostID) }

  return try await MainActor.run {
    // ... existing implementation
  }
}
```

### Fine-Grained Signposts (Hot Paths Only)

Inside methods that show up as slow in benchmarks, mark sub-steps:

```swift
os_signpost(.begin, log: Signposts.repository, name: "fetch.predicateQuery", signpostID: signpostID)
let primaryRecords = try fetchRecords(...)
os_signpost(.end, log: Signposts.repository, name: "fetch.predicateQuery", signpostID: signpostID)

os_signpost(.begin, log: Signposts.repository, name: "fetch.postFilter", signpostID: signpostID)
// ... filtering code
os_signpost(.end, log: Signposts.repository, name: "fetch.postFilter", signpostID: signpostID)
```

### Signpost Metadata

For operations with variable input size, include the count:

```swift
os_signpost(.begin, log: Signposts.sync, name: "batchUpsert",
  signpostID: signpostID, "%{public}d records", ckRecords.count)
```

This appears in Instruments and is invaluable for correlating timing with batch size.

### What NOT to Signpost

- Single-record CRUD (the overhead would dominate the measurement)
- Pure domain model operations (no I/O, no database access)
- Anything in the Domain layer (signposts belong in Backends and Sync only)

## Interpreting Results

### Reading XCTest Output

XCTest `measure` reports:

```
Test Case '-[TransactionFetchBenchmarks testFetchByAccount_1x]' measured
  [Time, seconds] average: 0.045, relative standard deviation: 8.234%,
  values: [0.048, 0.044, 0.046, 0.043, 0.044, 0.047, 0.043, 0.045, 0.044, 0.046]
```

Key numbers:
- **Average** — the headline number. This is what the user feels.
- **Relative standard deviation (stddev%)** — how noisy the measurement is. Under 10% is reliable. Over 20% means the benchmark is too noisy to trust — investigate why.
- **Values array** — look for outliers. A single high value with 9 consistent ones suggests a one-time cost (cache miss, JIT). Consistently high variance suggests contention or non-determinism.

### Establishing Baselines

**Do not guess at performance targets.** Run the benchmarks, read the numbers, set baselines from reality.

1. Run `just benchmark` on a clean machine with minimal background activity.
2. Record the actual averages and stddev for each operation.
3. Set Xcode baselines from these real numbers (see "Setting Baselines" below).
4. Performance targets come from the measured baseline plus your tolerance for regression — not from assumptions about what "should" be fast.

If a number surprises you (faster or slower than expected), that's the point. The benchmark exists to replace intuition with measurement.

### Scaling Analysis

Always compare 1x vs 2x results for the same operation:

- **Linear scaling** (2x data = ~2x time): expected for operations that scan all records. Acceptable.
- **Sub-linear scaling** (2x data = < 2x time): good — indicates effective indexing or early-exit.
- **Super-linear scaling** (2x data = > 2.5x time): problem — indicates O(n^2) behavior, excessive allocation, or SQLite query plan degradation. Investigate.

### Common Patterns to Watch For

**"First iteration is 10x slower"** — GRDB connection / migration setup or SQLite page cache warmup. If this only affects the first call after app launch, it may be acceptable. If it recurs on every iteration, it's a problem.

**"Memory grows linearly with dataset"** — Expected for operations that load all records (e.g., batch upsert fetches all existing records). A problem if memory doesn't drop after the operation completes (retained references).

**"stddev is 30%+"** — The benchmark is measuring something non-deterministic. Common causes: background thread contention, autorelease pool buildup, system memory pressure. Fix the benchmark before trusting the numbers.

**"Page 10 is much slower than page 0"** — Offset-based pagination scans all preceding records. This is inherent to the approach but the magnitude matters.

### When to Use Instruments Instead

Benchmarks tell you *what* is slow. Instruments tells you *why*. Reach for Instruments when:

- A benchmark shows a regression but the code change seems unrelated
- You need to know which line of code dominates the time
- Memory benchmarks show unexpected growth and you need allocation stacks
- You want to see how operations interleave during a real sync session

Open Instruments, select the **os_signpost** instrument, filter to `com.moolah.app`, and run the app. The signpost regions show up as intervals on a timeline, broken down by category (Repository, Sync, Balance).

### Setting Baselines

After the first benchmark run, set baselines in Xcode:

1. Run `just benchmark`
2. Open the test report in Xcode
3. Click the diamond icon next to each benchmark result
4. Click "Set Baseline"

Future runs will show green/red pass/fail against the baseline. The default tolerance is 10% — a benchmark fails if average exceeds baseline + 10%. Adjust tolerance per-test if needed (some operations are inherently noisier).
