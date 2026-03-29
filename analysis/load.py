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
    resource_injection_attempts: int = 0
    resources_injected: int = 0
    resource_injection_blocked: int = 0
    total_births: int = 0
    total_novel_placements: int = 0
    total_deaths_energy: int = 0
    total_deaths_age: int = 0
    total_resources_consumed: int = 0
    total_interactions: int = 0
    net_energy_delta: float = 0.0


@dataclass(frozen=True)
class LineageRow:
    tick: int
    child_lineage: int
    parent_lineage: int | None
    generation: int
    expr_hash: str
    birth_kind: str = "reproduction"


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


def _raw_value(row: dict[str, str], key: str) -> str:
    value = row.get(key)
    return value if value is not None else ""


def load_metrics(path: Path) -> list[MetricRow]:
    rows: list[MetricRow] = []
    with path.open("r", newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        for raw in reader:
            rows.append(
                MetricRow(
                    tick=_parse_int(_raw_value(raw, "tick")),
                    population=_parse_int(_raw_value(raw, "population")),
                    resources=_parse_int(_raw_value(raw, "resources")),
                    empty=_parse_int(_raw_value(raw, "empty")),
                    mean_energy=_parse_float(_raw_value(raw, "mean_energy")),
                    max_energy=_parse_float(_raw_value(raw, "max_energy")),
                    mean_size=_parse_float(_raw_value(raw, "mean_size")),
                    max_size=_parse_int(_raw_value(raw, "max_size")),
                    mean_age=_parse_float(_raw_value(raw, "mean_age")),
                    max_age=_parse_int(_raw_value(raw, "max_age")),
                    births=_parse_int(_raw_value(raw, "births")),
                    deaths_energy=_parse_int(_raw_value(raw, "deaths_energy")),
                    deaths_age=_parse_int(_raw_value(raw, "deaths_age")),
                    interactions=_parse_int(_raw_value(raw, "interactions")),
                    resources_consumed=_parse_int(_raw_value(raw, "resources_consumed")),
                    novel_placements=_parse_int(_raw_value(raw, "novel_placements")),
                    unique_structures=_parse_int(_raw_value(raw, "unique_structures")),
                    max_generation=_parse_int(_raw_value(raw, "max_generation")),
                    resource_injection_attempts=_parse_int(_raw_value(raw, "resource_injection_attempts")),
                    resources_injected=_parse_int(_raw_value(raw, "resources_injected")),
                    resource_injection_blocked=_parse_int(_raw_value(raw, "resource_injection_blocked")),
                    total_births=_parse_int(_raw_value(raw, "total_births")),
                    total_novel_placements=_parse_int(_raw_value(raw, "total_novel_placements")),
                    total_deaths_energy=_parse_int(_raw_value(raw, "total_deaths_energy")),
                    total_deaths_age=_parse_int(_raw_value(raw, "total_deaths_age")),
                    total_resources_consumed=_parse_int(_raw_value(raw, "total_resources_consumed")),
                    total_interactions=_parse_int(_raw_value(raw, "total_interactions")),
                    net_energy_delta=_parse_float(_raw_value(raw, "net_energy_delta")),
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
                    tick=_parse_int(_raw_value(raw, "tick")),
                    child_lineage=_parse_int(_raw_value(raw, "child_lineage")),
                    parent_lineage=(
                        _parse_int(_raw_value(raw, "parent_lineage"))
                        if _raw_value(raw, "parent_lineage").strip()
                        else None
                    ),
                    generation=_parse_int(_raw_value(raw, "generation")),
                    expr_hash=_raw_value(raw, "expr_hash").strip(),
                    birth_kind=_raw_value(raw, "birth_kind").strip() or "reproduction",
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
