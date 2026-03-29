from __future__ import annotations

import argparse
import json
from dataclasses import asdict, dataclass
from pathlib import Path
from statistics import fmean

from .lineage import LateLineageSummary, LineageSummary, summarize_late_lineages, summarize_lineage
from .load import RunData, require_runs
from .window_metrics import WindowSummary, compute_windows


@dataclass(frozen=True)
class RunScore:
    persistence: float
    novelty: float
    retention_proxy: float
    activity: float


@dataclass(frozen=True)
class RunAssessment:
    run_name: str
    ticks_observed: int
    final_population: int
    final_max_generation: int
    classification: str
    caveats: list[str]
    score: RunScore
    lineage: LineageSummary
    late_lineage: LateLineageSummary
    latest_window: WindowSummary | None
    final_window: WindowSummary | None


def clamp01(value: float) -> float:
    return max(0.0, min(1.0, value))


def assess_run(run: RunData, *, window_ticks: int, late_fraction: float) -> RunAssessment:
    metrics = run.metrics
    lineage_rows = run.lineage
    windows = compute_windows(metrics, window_ticks)

    if not metrics:
        return RunAssessment(
            run_name=run.name,
            ticks_observed=0,
            final_population=0,
            final_max_generation=0,
            classification="dead",
            caveats=["No metric rows were found; only CSV headers exist."],
            score=RunScore(0.0, 0.0, 0.0, 0.0),
            lineage=summarize_lineage(lineage_rows),
            late_lineage=summarize_late_lineages(lineage_rows, 0),
            latest_window=None,
            final_window=None,
        )

    last_tick = metrics[-1].tick
    late_start_tick = int(last_tick * (1.0 - late_fraction))
    late_metrics = [row for row in metrics if row.tick >= late_start_tick]
    late_windows = [window for window in windows if window.start_tick >= late_start_tick]
    final_window = late_windows[-1] if late_windows else (windows[-1] if windows else None)

    final_population = metrics[-1].population
    final_max_generation = metrics[-1].max_generation
    lineage_summary = summarize_lineage(lineage_rows)
    late_lineage_summary = summarize_late_lineages(lineage_rows, late_start_tick)

    min_late_population = min((row.population for row in late_metrics), default=0)
    late_nonzero_birth_fraction = fmean(row.births > 0 for row in late_metrics) if late_metrics else 0.0
    late_nonzero_interaction_fraction = fmean(row.interactions > 0 for row in late_metrics) if late_metrics else 0.0
    late_novel_placements = sum(row.novel_placements for row in late_metrics)
    late_generation_gain = late_metrics[-1].max_generation - late_metrics[0].max_generation if len(late_metrics) >= 2 else 0

    persistence = clamp01(min_late_population / 50.0)
    activity = clamp01((late_nonzero_birth_fraction + late_nonzero_interaction_fraction) / 2.0)
    novelty = clamp01(
        0.5 * clamp01(late_generation_gain / 10.0)
        + 0.3 * clamp01(late_novel_placements / 50.0)
        + 0.2 * clamp01(late_lineage_summary.unique_expr_hashes / 25.0)
    )
    retention_proxy = clamp01(
        0.7 * late_lineage_summary.fraction_productive + 0.3 * clamp01(late_lineage_summary.branching_parents / 10.0)
    )

    caveats: list[str] = []
    caveats.append("Retention is proxied from descendant-producing late lineages because survival-by-hash is not logged yet.")
    caveats.append("Species turnover is not directly measurable from current CSVs because per-tick per-hash abundances are not logged.")

    if final_population == 0 or min_late_population == 0:
        classification = "dead"
    elif late_nonzero_birth_fraction < 0.1 and late_generation_gain == 0:
        classification = "static"
    elif novelty < 0.25 or retention_proxy < 0.15:
        classification = "drifting"
    else:
        classification = "evolving"

    return RunAssessment(
        run_name=run.name,
        ticks_observed=last_tick,
        final_population=final_population,
        final_max_generation=final_max_generation,
        classification=classification,
        caveats=caveats,
        score=RunScore(
            persistence=round(persistence, 3),
            novelty=round(novelty, 3),
            retention_proxy=round(retention_proxy, 3),
            activity=round(activity, 3),
        ),
        lineage=lineage_summary,
        late_lineage=late_lineage_summary,
        latest_window=windows[-1] if windows else None,
        final_window=final_window,
    )


def summarize_batch(assessments: list[RunAssessment]) -> dict[str, object]:
    if not assessments:
        return {
            "run_count": 0,
            "classifications": {},
            "mean_scores": {},
        }

    classes: dict[str, int] = {}
    for assessment in assessments:
        classes[assessment.classification] = classes.get(assessment.classification, 0) + 1

    return {
        "run_count": len(assessments),
        "classifications": classes,
        "mean_scores": {
            "persistence": round(fmean(a.score.persistence for a in assessments), 3),
            "novelty": round(fmean(a.score.novelty for a in assessments), 3),
            "retention_proxy": round(fmean(a.score.retention_proxy for a in assessments), 3),
            "activity": round(fmean(a.score.activity for a in assessments), 3),
        },
    }


def format_markdown(assessments: list[RunAssessment], batch_summary: dict[str, object], *, window_ticks: int, late_fraction: float) -> str:
    lines: list[str] = []
    lines.append("# LambLife Evolution Report")
    lines.append("")
    lines.append(f"- Window size: `{window_ticks}` ticks")
    lines.append(f"- Late-run fraction: `{late_fraction:.2f}`")
    lines.append(f"- Runs analyzed: `{batch_summary['run_count']}`")
    lines.append("")
    lines.append("## Batch Summary")
    lines.append("")

    classifications = batch_summary.get("classifications", {})
    if classifications:
        for key in sorted(classifications):
            lines.append(f"- `{key}`: {classifications[key]}")
    else:
        lines.append("- No runs found")

    mean_scores = batch_summary.get("mean_scores", {})
    if mean_scores:
        lines.append("")
        lines.append("Mean scores:")
        for key in ("persistence", "novelty", "retention_proxy", "activity"):
            lines.append(f"- `{key}`: {mean_scores[key]:.3f}")

    for assessment in assessments:
        lines.append("")
        lines.append(f"## Run `{assessment.run_name}`")
        lines.append("")
        lines.append(f"- Classification: `{assessment.classification}`")
        lines.append(f"- Observed ticks: `{assessment.ticks_observed}`")
        lines.append(f"- Final population: `{assessment.final_population}`")
        lines.append(f"- Final max generation: `{assessment.final_max_generation}`")
        lines.append(
            f"- Scores: persistence `{assessment.score.persistence:.3f}`, novelty `{assessment.score.novelty:.3f}`, retention proxy `{assessment.score.retention_proxy:.3f}`, activity `{assessment.score.activity:.3f}`"
        )
        lines.append(
            f"- Lineage births: `{assessment.lineage.total_births}`, unique late hashes: `{assessment.late_lineage.unique_expr_hashes}`, productive late lineages: `{assessment.late_lineage.productive_lineages}`"
        )
        if assessment.final_window:
            lines.append(
                f"- Final window [{assessment.final_window.start_tick}, {assessment.final_window.end_tick}] mean population `{assessment.final_window.mean_population:.1f}`, births `{assessment.final_window.total_births}`, generation gain `{assessment.final_window.generation_gain}`, novel placements `{assessment.final_window.total_novel_placements}`"
            )
        if assessment.caveats:
            lines.append("- Caveats:")
            for caveat in assessment.caveats:
                lines.append(f"  - {caveat}")

    return "\n".join(lines) + "\n"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Analyze LambLife metrics.csv and lineage.csv outputs.")
    parser.add_argument("input", type=Path, help="A run directory or a parent directory containing many run directories")
    parser.add_argument("--window", type=int, default=10_000, help="Fixed window size in ticks for time-window summaries")
    parser.add_argument(
        "--late-fraction",
        type=float,
        default=0.25,
        help="Fraction of the run treated as late-run for continued-evolution checks",
    )
    parser.add_argument("--output", type=Path, help="Write a Markdown report to this path")
    parser.add_argument("--json-output", type=Path, help="Write machine-readable JSON summary to this path")
    parser.add_argument("--metrics-name", default="metrics.csv", help="Metrics filename to discover")
    parser.add_argument("--lineage-name", default="lineage.csv", help="Lineage filename to discover")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    runs = require_runs(args.input, metrics_name=args.metrics_name, lineage_name=args.lineage_name)
    assessments = [assess_run(run, window_ticks=args.window, late_fraction=args.late_fraction) for run in runs]
    batch_summary = summarize_batch(assessments)

    markdown = format_markdown(assessments, batch_summary, window_ticks=args.window, late_fraction=args.late_fraction)
    print(markdown, end="")

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(markdown, encoding="utf-8")

    if args.json_output:
        payload = {
            "batch_summary": batch_summary,
            "runs": [asdict(assessment) for assessment in assessments],
        }
        args.json_output.parent.mkdir(parents=True, exist_ok=True)
        args.json_output.write_text(json.dumps(payload, indent=2), encoding="utf-8")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())

