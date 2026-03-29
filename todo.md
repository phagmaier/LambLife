# LambLife Performance And Analysis Checklist

## Phase 0: Baseline

- [ ] Add `PERF_BASELINE.md` with standard benchmark scenarios.
- [ ] Record small baseline: `30x30`, `1_000` ticks.
- [ ] Record medium baseline: `80x80`, `5_000` ticks.
- [ ] Record target-ish baseline: `150x150`, `10_000` ticks.
- [ ] Capture runtime, ticks/sec, final population, total births, total interactions, total beta steps, metrics size, and lineage size for each baseline.

## Phase 1: Analysis Throughput

- [x] Rewrite `analysis/window_metrics.py` to compute windows in a single pass.
- [x] Remove avoidable full-list rescans in `analysis/report.py` for late-run summaries.
- [x] Add optional lightweight timing output to the analysis entrypoint.
- [x] Add a `--summary-only` analysis mode if report generation is still too slow.
- [x] Re-test analysis time on representative large CSVs.

## Phase 2: Simulator Profiling

- [x] Add per-tick timing buckets for inject, decay, interactions, death sweep, metrics, and snapshot save.
- [x] Add cumulative counters for organisms processed, reductions attempted, beta steps, size-limit aborts, and step-limit exits.
- [x] Log profiling counters at `log_interval`.
- [ ] Add a low-noise mode so profiling output stays readable.

## Phase 3: Reduction Allocation Rewrite

- [x] Introduce a per-interaction arena allocator for temporary reduction trees.
- [x] Refactor reduction APIs so intermediate trees are released in bulk.
- [x] Remove redundant `Expr.deepCopy` calls in the interaction path where ownership allows.
- [ ] Re-benchmark after allocator changes before changing semantics further.

## Phase 4: Expression Metadata Caching

- [ ] Cache organism expression size.
- [ ] Cache organism expression hash.
- [ ] Reuse cached metadata for maintenance, simplification, similarity, and metrics.
- [ ] Update caches on mutation, reproduction, novel placement, and organism replacement.

## Phase 5: Simulation Loop Cleanup

- [ ] Merge death and age sweeps into one pass.
- [ ] Track population/resource/energy totals incrementally where practical.
- [ ] Reduce repeated full-grid scans during metric collection.
- [ ] Re-evaluate diversity sampling frequency.

## Phase 6: Output Cost Control

- [ ] Make diversity collection optional or less frequent.
- [ ] Make snapshots optional in performance runs.
- [ ] Add a low-overhead headless mode for trial runs.
- [ ] Re-test long runs with reduced logging overhead.

## Phase 7: Representation Rewrite Only If Still Needed

- [ ] Evaluate arena-backed node IDs or another compact expression representation.
- [ ] Evaluate hash-consing / DAG sharing only after allocator and cache improvements are measured.
- [ ] Decide whether a deeper rewrite is justified from measured bottlenecks, not intuition.

## Current Execution Order

- [x] Convert the roadmap into a concrete checklist.
- [x] Implement Phase 1 single-pass analysis windowing.
- [x] Trim avoidable report rescans.
- [x] Verify analysis behavior still matches expected outputs.
- [x] Move to simulator profiling instrumentation.
