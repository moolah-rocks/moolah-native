---
name: interpret-benchmarks
description: Use when `just benchmark` output needs to be read or acted on — investigating a suspected performance regression, setting or updating baselines, comparing 1x vs 2x scaling, evaluating whether a stddev is reliable enough to trust, or deciding whether a reported number warrants optimisation.
---

# Interpreting Benchmark Results

Follow this process when analyzing benchmark output. Read `guides/BENCHMARKING_GUIDE.md` for detailed reference.

## Step 1: Run the Benchmarks

If you haven't already, run and capture the output:

```bash
mkdir -p .agent-tmp
just benchmark 2>&1 | tee .agent-tmp/benchmark-output.txt
```

## Step 2: Extract the Numbers

For each benchmark, identify:
- **Average time** (seconds)
- **Relative standard deviation** (percentage)
- **Individual values** (the array of per-iteration measurements)
- **Memory** (peak physical memory from XCTMemoryMetric, if reported)

```bash
grep -A2 "measured" .agent-tmp/benchmark-output.txt
```

## Step 3: Assess Reliability

**Before interpreting any result, check the stddev.**

| Stddev | Interpretation |
|---|---|
| < 5% | Highly reliable. Safe to compare small differences. |
| 5-10% | Reliable. Normal for database (GRDB) operations. |
| 10-20% | Marginal. Can detect large regressions but not subtle ones. |
| > 20% | Unreliable. Do not draw conclusions. Fix the benchmark first. |

If stddev is high, check:
- Is other work running on the machine?
- Is setup or teardown leaking into the measure block?
- Is the in-memory GRDB database growing across iterations? (Reset / recreate the database between iterations)
- Is there autorelease pool buildup? (Add `autoreleasepool {}`)

## Step 4: Scaling Analysis

Compare 1x vs 2x results for the same operation:

```
Ratio = (2x average) / (1x average)
```

| Ratio | Scaling | Interpretation |
|---|---|---|
| ~1.0 | Constant | Operation doesn't depend on dataset size (e.g., indexed lookup) |
| 1.5-2.2 | Linear | Expected for full-scan operations. Acceptable. |
| 2.5-4.0 | Super-linear | Likely O(n log n) or worse. Worth investigating. |
| > 4.0 | Quadratic or worse | Performance bug. Investigate immediately. |

## Step 5: Identify Anomalies

Look at the individual values array for each benchmark:

- **One high outlier, rest consistent** — likely a one-time cost (cache miss, JIT warmup). Usually not actionable unless it happens on every app launch.
- **Steadily increasing values** — database growth across iterations or memory pressure. The benchmark setup may need fixing (reset the in-memory database between iterations, autoreleasepool).
- **Bimodal distribution** (some fast, some slow) — contention or a code path that sometimes hits a slow branch. Investigate with Instruments.

## Step 6: Compare Against Baselines

If baselines are set in Xcode:
- **Green (pass):** Within tolerance. No action needed.
- **Red (fail):** Exceeds baseline + tolerance. This is a regression — investigate what changed.

If no baselines are set yet:
- These are your first real numbers. Record them. Set baselines in Xcode.
- Do not assume any number is "too slow" or "fast enough" without context. Compare against the user experience: does the app feel responsive during these operations?

## Step 7: Decide Next Steps

Based on the results:

**Numbers look reasonable, app feels responsive:**
- Set baselines if not already set
- No further action needed
- Clean up: `rm .agent-tmp/benchmark-output.txt`

**A specific operation is slow:**
- Do NOT guess at the cause. Use Instruments with the os_signpost instrumentation to find where time is actually spent.
- Open Instruments > os_signpost, filter to `com.moolah.app`, run the app, trigger the operation
- The signpost regions show which sub-step dominates
- Once you've identified the bottleneck with evidence, then optimize and re-benchmark to confirm improvement

**A regression appeared after a code change:**
- Compare the benchmark output to the previous baseline
- Check `git diff` for what changed in the relevant code path
- Run Instruments to confirm the regression and identify the cause
- Fix, re-benchmark, verify the numbers are back to baseline

**Benchmarks are too noisy to be useful:**
- Close other apps, disable Spotlight indexing temporarily
- Ensure context.reset() is called between iterations
- Ensure autoreleasepool is used for conversion benchmarks
- If still noisy, increase `iterationCount` to 20

## Reporting

When reporting benchmark results (in a PR, commit message, or conversation), include:

1. What operation was measured
2. The average and stddev at each scale tier
3. The scaling ratio (2x / 1x)
4. What action was taken (or why none was needed)

Example:
```
TransactionFetchByAccount:
  1x: 45ms avg (stddev 7%)
  2x: 88ms avg (stddev 9%)
  Scaling ratio: 1.96x (linear, as expected)
  
  Action: Set as baseline. No optimization needed.
```

After reviewing, clean up temp files:
```bash
rm .agent-tmp/benchmark-output.txt
```
