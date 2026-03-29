# LambLife Analysis

This directory contains the first-pass Python tooling for evaluating whether a run is:

- dead
- static
- drifting
- evolving

This is intentionally conservative. With the current simulator logs, the report can estimate persistence, activity, novelty, and a retention proxy from lineage branching, but it cannot yet prove adaptive novelty.

## Requirements

- Python `3.11+`
- no third-party packages

## Expected Run Layout

The analysis tools expect either:

1. one run directory containing `metrics.csv` and `lineage.csv`
2. one parent directory containing many run directories, each with those two files

Example:

```text
runs/
  seed_1/
    metrics.csv
    lineage.csv
  seed_2/
    metrics.csv
    lineage.csv
```

## Batch Running

To generate runs in a consistent layout:

```bash
python3 -m analysis.run_batch \
  --output-root runs/baseline_001 \
  --seeds 1 2 3 4 5 \
  --ticks 100000
```

By default this uses:

```bash
zig build -Doptimize=ReleaseFast run --
```

so experiment batches run with the fast optimized build unless you override `--command`.

If you want to see simulator progress in the terminal while still saving `run.log`, add:

```bash
--stream
```

You can pass simulator config overrides with repeated `--extra-arg`:

```bash
python3 -m analysis.run_batch \
  --output-root runs/small_grid \
  --seeds 11 12 13 \
  --ticks 50000 \
  --extra-arg=--width=80 \
  --extra-arg=--height=80 \
  --extra-arg=--log_interval=50
```

## Reporting

Analyze a single run:

```bash
python3 -m analysis.report . --window 10000
```

Analyze a batch and write report artifacts:

```bash
python3 -m analysis.report runs/baseline_001 \
  --window 10000 \
  --output runs/baseline_001/report.md \
  --json-output runs/baseline_001/report.json
```

## What The Current Report Means

The report computes:

- persistence: whether population stays meaningfully above zero late in the run
- activity: whether births and interactions remain active late
- novelty: whether late generation growth, novel placements, and late hashes still appear
- retention proxy: whether late-born lineages themselves go on to produce descendants

Classification meanings:

- `dead`
  - extinction or effective extinction
- `static`
  - population survives but late births and generation growth stop
- `drifting`
  - some novelty remains, but little evidence that late novelty is retained
- `evolving`
  - late births, generation growth, and descendant-producing late lineages all remain present

## Current Limitations

The present simulator logs do not yet support:

- survival time of new hashes
- species abundance over time
- turnover of dominant species
- direct innovation success tracking
- ecological role inference from interaction outcomes

Those require the next instrumentation layer from [evaluation_plan.md](/home/phagmaier/Desktop/Code/LambLife/evaluation_plan.md).
