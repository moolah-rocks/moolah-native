# MCP reporting improvements

User-requested order, each delivered with its own review and validation boundary:

1. Spending summaries exclude current net worth by default. Explicit
   include_net_worth requests it; omitted net worth is explicit in the response.
   A narrow spending query must succeed with over 10,000 unrelated lifetime legs.
2. Balances use signed account-keyset cursors, default/maximum page limits and a
   compact account-total mode. No manual account batching is necessary.
3. Stream and aggregate larger histories inside a consistent database snapshot.
   Bound work, aggregate cardinality and encoded response size independently;
   preserve exact Decimal arithmetic, signs, cancellation and instrument separation.
4. Distinguish calculation limits from response size. Errors identify the operation,
   limit and usable next action without exposing query contents or financial data.
5. Include category names, hierarchy/parent totals and monthly breakdowns. Keep
   report-day price conversion distinct from local-calendar month grouping.

Localhost HTTP only. No HTTPS, certificate, proxy or remote-exposure instructions.

Streaming/pagination design review constraints:

- Count every raw joined leg (including scheduled/excluded report types) against
  the processing cap; filter only after counting. Preserve selective date/owner
  query plans, fixed SQL and no pre-cap sort/materialisation.
- Aggregate only the selected account page, excluding its sentinel. Validate
  explicit account IDs separately in the same snapshot. Bind IDs, reporting
  currency, mode, limit and timezone into signed cursors.
- Keep a monotonic distinct-key computation cap, sort complete outputs, then
  remove zero quantities. Sum Decimal values, never aggregate through Int64.
  Apply the shared fix to earmark positions too.
- UTC historical price days and requested-zone calendar months are separate key
  dimensions. Do not convert monthly totals at a single rate. Keep transaction
  searches at one year; a larger summary horizon needs a separate range policy.
- Benchmark queue occupancy and cancellation at realistic density before choosing
  the processing ceiling. RowCursor/Row never escape their database read closure.

Step 1 complete: 17 targeted tests across five suites pass, including 10,001
out-of-range historical legs with one requested expense, explicit net-worth opt-in,
wire omission and unchanged flow classifications/plans. iOS build, full formatting
and strict lint pass. Code, concurrency, database, instruments and help reviews have
no remaining findings. Net worth remains bounded by the existing limits when
explicitly requested; later steps address those limits independently.

Step 2 complete: account UUID cursors automatically traverse the full profile,
including more than 500 accounts. Compact account_totals retains identical
valuations and clearly marks positions as omitted. 37 tests across seven suites
pass, including 501-account traversal, sentinel isolation, complete selected-ID
validation, exact production query-plan pins, and cursor invalidation after data
or filter changes. iOS build, full formatting/strict lint and compiler warning
sweep pass. Code, concurrency, database, instruments and help reviews are clear.

Step 3 complete: balances, earmarks and report flows stream raw rows inside one
read snapshot and fold exact Decimal quantities. Work is capped at 250,000 raw
legs (including exclusions); 10,000 monotonic calculation groups separately
bound memory and match output-array schemas. Encoded responses retain their
separate transport limits. Transaction-detail responses retain their raw-leg cap.
48 tests across ten suites pass, including dense histories, totals beyond SQLite
Int64 SUM range, raw/excluded-row and key bounds, cancellation checkpoints,
exact query plans and three-zone month/UTC-day boundaries. The 250,000-leg
read-only probes took 0.87 seconds for balances and 1.66 seconds for summary
folding on this Mac (queue occupancy, excluding seeding and conversion). These
measurements support the bounded ceiling; they are not a cross-device guarantee.
iOS build, strict lint, formatting and warning sweep pass. Required code,
concurrency, database, instruments, datetime and copy reviews are clear.
