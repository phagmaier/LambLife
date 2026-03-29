from __future__ import annotations

import csv
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable


@dataclass(frozen=True)
class MetricRow:
    tick: int
    population: int
    resources: int
    empty: int
    mean_energy: float
    max_energy: float
    mean_size: float
    max_size: int
    mean_age: float
    max_age: int
    births: int
    deaths_energy: int
    deaths_age: int
    interactions: int
    resources_consumed: int
    novel_placements: int
    unique_structures: int
    max_generation: int


@dataclass(frozen=True)
class LineageRow:
    tick: int
    child_lineage: int
    parent_lineage: int
    generation: int
    expr_hash: str


@dataclass(frozen=True)
class RunData:
    name: str
    base_dir: Path
    metrics_path: Path
    lineage_path: Path
    metrics: list[MetricRow]
    lineage: list[LineageRow]


def _parse_int(value: str) -> int:
    return int(value.strip()) if value.strip() else 0


def _parse_float(value: str) -> float:
    return float(value.strip()) if value.strip() else 0.0


def load_metrics(path: Path) -> list[MetricRow]:
    rows: list[MetricRow] = []
    with path.open("r", newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for raw in reader:
            rows.append(
                MetricRow(
                    tick=_parse_int(raw["tick"]),
                    population=_parse_int(raw["population"]),
                    resources=_parse_int(raw["resources"]),
                    empty=_parse_int(raw["empty"]),
                    mean_energy=_parse_float(raw["mean_energy"]),
                    max_energy=_parse_float(raw["max_energy"]),
                    mean_size=_parse_float(raw["mean_size"]),
                    max_size=_parse_int(raw["max_size"]),
                    mean_age=_parse_float(raw["mean_age"]),
                    max_age=_parse_int(raw["max_age"]),
                    births=_parse_int(raw["births"]),
                    deaths_energy=_parse_int(raw["deaths_energy"]),
                    deaths_age=_parse_int(raw["deaths_age"]),
                    interactions=_parse_int(raw["interactions"]),
                    resources_consumed=_parse_int(raw["resources_consumed"]),
                    novel_placements=_parse_int(raw["novel_placements"]),
                    unique_structures=_parse_int(raw["unique_structures"]),
                    max_generation=_parse_int(raw["max_generation"]),
                )
            )
    return rows


def load_lineage(path: Path) -> list[LineageRow]:
    rows: list[LineageRow] = []
    with path.open("r", newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for raw in reader:
            rows.append(
                LineageRow(
                    tick=_parse_int(raw["tick"]),
                    child_lineage=_parse_int(raw["child_lineage"]),
                    parent_lineage=_parse_int(raw["parent_lineage"]),
                    generation=_parse_int(raw["generation"]),
                    expr_hash=raw["expr_hash"].strip(),
                )
            )
    return rows


def load_run(metrics_path: Path, lineage_path: Path, *, name: str | None = None) -> RunData:
    base_dir = metrics_path.parent
    return RunData(
        name=name or base_dir.name,
        base_dir=base_dir,
        metrics_path=metrics_path,
        lineage_path=lineage_path,
        metrics=load_metrics(metrics_path),
        lineage=load_lineage(lineage_path),
    )


def discover_runs(root: Path, *, metrics_name: str = "metrics.csv", lineage_name: str = "lineage.csv") -> list[RunData]:
    root = root.resolve()

    def pair_from_dir(directory: Path) -> tuple[Path, Path] | None:
        metrics_path = directory / metrics_name
        lineage_path = directory / lineage_name
        if metrics_path.is_file() and lineage_path.is_file():
            return metrics_path, lineage_path
        return None

    discovered: list[RunData] = []

    direct_pair = pair_from_dir(root) if root.is_dir() else None
    if direct_pair:
        metrics_path, lineage_path = direct_pair
        return [load_run(metrics_path, lineage_path, name=root.name)]

    if root.is_file():
        raise FileNotFoundError(f"{root} is a file, but a run directory was expected")

    seen_dirs: set[Path] = set()
    for metrics_path in sorted(root.rglob(metrics_name)):
        directory = metrics_path.parent.resolve()
        if directory in seen_dirs:
            continue
        lineage_path = directory / lineage_name
        if not lineage_path.is_file():
            continue
        seen_dirs.add(directory)
        discovered.append(load_run(metrics_path, lineage_path, name=directory.relative_to(root).as_posix()))

    return discovered


def require_runs(root: Path, *, metrics_name: str = "metrics.csv", lineage_name: str = "lineage.csv") -> list[RunData]:
    runs = discover_runs(root, metrics_name=metrics_name, lineage_name=lineage_name)
    if not runs:
        raise FileNotFoundError(
            f"No run directories containing {metrics_name!r} and {lineage_name!r} were found under {root}"
        )
    return runs


def iter_run_paths(root: Path, *, metrics_name: str = "metrics.csv", lineage_name: str = "lineage.csv") -> Iterable[tuple[Path, Path]]:
    for run in require_runs(root, metrics_name=metrics_name, lineage_name=lineage_name):
        yield run.metrics_path, run.lineage_path

