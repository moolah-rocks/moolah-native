---
name: profile-performance
description: Use when diagnosing performance issues in the running Moolah app — UI freezes, beachballs, main-thread hangs, slow sync sessions, laggy navigation, any `⚠️ PERF:` warning in the app logs, or any user report of "the app feels slow".
---

# Profile Performance

Diagnose UI freezes and performance issues in the running macOS app using stack sampling, performance logging, and Instruments.

## Quick diagnosis: Stack sampling

When the app is frozen/unresponsive, capture what the main thread is doing:

```bash
# Get the app's PID
PID=$(pgrep -f "Moolah.app/Contents/MacOS/Moolah")

# Capture a 3-second stack sample
sample $PID 3 -f .agent-tmp/sample-output.txt

# Read the output — the call graph shows where time is spent
# Look at Thread_*  DispatchQueue_1: com.apple.main-thread
# The deepest frames with highest sample counts are the bottleneck
```

The `sample` tool captures stack traces every 1ms. The call graph shows sample counts — higher counts = more time spent there. Focus on the main thread (`com.apple.main-thread`).

## Performance logging

The app has built-in performance logging in key sync operations. To capture it:

```bash
# Launch with log capture (see run-mac-app-with-logs skill)
just run-mac-with-logs &

# Monitor for performance warnings
tail -f .agent-tmp/app-logs.txt | grep -E --line-buffered "PERF|SYNC SESSION|Store reloads"
```

### What the logs tell you

- **`⚠️ PERF: applyRemoteChanges blocked main thread for Xms`** — Per-batch sync timing with breakdown (upsert vs context.save)
- **`📊 SYNC SESSION COMPLETE`** — End-of-session summary with total records, batch count, cumulative times per phase
- **`⚠️ PERF: balance invalidation took Xms`** — Post-sync balance recomputation cost
- **`📊 Store reloads after sync completed in Xms`** — Time to reload stores after sync
- **`⚠️ PERF: *Store.reloadFromSync took Xms`** — Per-store reload timing
- **`⚠️ PERF: flushSystemFieldsCache took Xms`** — System fields cache serialization (should be off main thread)

### Existing os_signpost instrumentation

These show up in Instruments under the "os_signpost" instrument:

| Category | Signpost Name | What it measures |
|----------|--------------|------------------|
| Sync | `applyRemoteChanges` | Full batch processing (saves + deletes + balance + save) |
| Sync | `applyBatchSaves` | Record upsert by type |
| Sync | `applyBatchDeletions` | Record deletion by type |
| Sync | `queueAllExistingRecords` | Initial record scanning for upload |
| Sync | `nextRecordZoneChangeBatch` | Building upload batch |
| Balance | `invalidateCachedBalances` | Clearing cached balances after sync |
| Repository | `fetch.*` | Repository fetch operations with sub-signposts |
| Repository | `recomputeAllBalances` | Full balance recomputation |

## Instruments profiling via CLI

To record an Instruments trace with `xctrace`:

```bash
# List available templates
xctrace list templates

# Record with Time Profiler (general CPU profiling)
xctrace record --template 'Time Profiler' \
  --attach $(pgrep -f "Moolah.app/Contents/MacOS/Moolah") \
  --time-limit 10s \
  --output .agent-tmp/profile.trace

# Record with os_signpost (shows the custom signpost intervals)
xctrace record --template 'os_signpost' \
  --attach $(pgrep -f "Moolah.app/Contents/MacOS/Moolah") \
  --time-limit 10s \
  --output .agent-tmp/signpost.trace

# Open the trace in Instruments
open .agent-tmp/profile.trace
```

Note: `xctrace` traces can only be viewed in Instruments.app — they are binary format and cannot be read by Claude. Use stack sampling (`sample`) or performance logs for automated diagnosis.

## Workflow for diagnosing a freeze

1. **Launch the app with log capture** — `just run-mac-with-logs &`
2. **Trigger the freeze** — e.g., navigate to a profile with many transactions
3. **While frozen, capture a stack sample** — `sample $(pgrep -f "Moolah.app/Contents/MacOS/Moolah") 3 -f .agent-tmp/sample-output.txt`
4. **Read the sample** — look for the main thread call graph, find the deepest frame with the most samples
5. **Check performance logs** — `grep "PERF\|SYNC SESSION" .agent-tmp/app-logs.txt`
6. **If needed, record an Instruments trace** for visual timeline analysis

## Clean up

```bash
rm -f .agent-tmp/sample-output.txt .agent-tmp/app-logs.txt
rm -rf .agent-tmp/*.trace
pkill -f "Moolah.app/Contents/MacOS/Moolah" 2>/dev/null || true
pkill -f "log stream.*com.moolah.app" 2>/dev/null || true
```
