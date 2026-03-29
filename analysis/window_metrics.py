from __future__ import annotations

from dataclasses import dataclass
from statistics import fmean

from .load import MetricRow


@dataclass(frozen=True)
class WindowSummary:
    index: int
    start_tick: int
    end_tick: int
    rows: int
    mean_population: float
    min_population: int
    max_population: int
    mean_energy: float
    mean_size: float
    total_births: int
    total_deaths: int
    total_interactions: int
    total_resources_consumed: int
    total_novel_placements: int
    nonzero_birth_fraction: float
    nonzero_interaction_fraction: float
    generation_gain: int
    first_max_generation: int
    last_max_generation: int
    max_unique_structures: int


def _window_bounds(rows: list[MetricRow], window_ticks: int) -> range:
    if not rows:
        return range(0)
    first_tick = rows[0].tick
    last_tick = rows[-1].tick
    return range(first_tick, last_tick + 1, max(window_ticks, 1))


def compute_windows(rows: list[MetricRow], window_ticks: int) -> list[WindowSummary]:
    if not rows:
        return []

    width = max(window_ticks, 1)
    windows: list[WindowSummary] = []
    row_idx = 0

    for idx, start_tick in enumerate(_window_bounds(rows, width)):
        end_tick = start_tick + width
        bucket_start = row_idx
        while row_idx < len(rows) and rows[row_idx].tick < end_tick:
            row_idx += 1

        if bucket_start == row_idx:
            continue

        bucket = rows[bucket_start:row_idx]

        windows.append(
            WindowSummary(
                index=idx,
                start_tick=start_tick,
                end_tick=bucket[-1].tick,
                rows=len(bucket),
                mean_population=fmean(row.population for row in bucket),
                min_population=min(row.population for row in bucket),
                max_population=max(row.population for row in bucket),
                mean_energy=fmean(row.mean_energy for row in bucket),
                mean_size=fmean(row.mean_size for row in bucket),
                total_births=sum(row.births for row in bucket),
                total_deaths=sum(row.deaths_energy + row.deaths_age for row in bucket),
                total_interactions=sum(row.interactions for row in bucket),
                total_resources_consumed=sum(row.resources_consumed for row in bucket),
                total_novel_placements=sum(row.novel_placements for row in bucket),
                nonzero_birth_fraction=sum(1 for row in bucket if row.births > 0) / len(bucket),
                nonzero_interaction_fraction=sum(1 for row in bucket if row.interactions > 0) / len(bucket),
                generation_gain=bucket[-1].max_generation - bucket[0].max_generation,
                first_max_generation=bucket[0].max_generation,
                last_max_generation=bucket[-1].max_generation,
                max_unique_structures=max(row.unique_structures for row in bucket),
            )
        )

    return windows
