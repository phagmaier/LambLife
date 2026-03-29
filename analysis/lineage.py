from __future__ import annotations

from collections import defaultdict
from dataclasses import dataclass

from .load import LineageRow


@dataclass(frozen=True)
class LineageSummary:
    total_births: int
    unique_lineages: int
    unique_expr_hashes: int
    max_generation: int
    roots_with_descendants: int
    branching_parents: int
    productive_lineages: int


@dataclass(frozen=True)
class LateLineageSummary:
    start_tick: int
    births: int
    unique_lineages: int
    unique_expr_hashes: int
    productive_lineages: int
    branching_parents: int
    fraction_productive: float


def summarize_lineage(rows: list[LineageRow]) -> LineageSummary:
    if not rows:
        return LineageSummary(
            total_births=0,
            unique_lineages=0,
            unique_expr_hashes=0,
            max_generation=0,
            roots_with_descendants=0,
            branching_parents=0,
            productive_lineages=0,
        )

    children_by_parent: dict[int, list[int]] = defaultdict(list)
    all_children: set[int] = set()
    productive: set[int] = set()

    for row in rows:
        children_by_parent[row.parent_lineage].append(row.child_lineage)
        all_children.add(row.child_lineage)
        productive.add(row.parent_lineage)

    return LineageSummary(
        total_births=len(rows),
        unique_lineages=len(all_children),
        unique_expr_hashes=len({row.expr_hash for row in rows}),
        max_generation=max(row.generation for row in rows),
        roots_with_descendants=len({row.parent_lineage for row in rows if row.parent_lineage not in all_children}),
        branching_parents=sum(1 for children in children_by_parent.values() if len(children) > 1),
        productive_lineages=len(productive),
    )


def summarize_late_lineages(rows: list[LineageRow], start_tick: int) -> LateLineageSummary:
    late_rows = [row for row in rows if row.tick >= start_tick]
    if not late_rows:
        return LateLineageSummary(
            start_tick=start_tick,
            births=0,
            unique_lineages=0,
            unique_expr_hashes=0,
            productive_lineages=0,
            branching_parents=0,
            fraction_productive=0.0,
        )

    late_child_ids = {row.child_lineage for row in late_rows}
    productive_late_lineages = {row.parent_lineage for row in late_rows if row.parent_lineage in late_child_ids}
    children_by_parent: dict[int, list[int]] = defaultdict(list)
    for row in late_rows:
        children_by_parent[row.parent_lineage].append(row.child_lineage)

    return LateLineageSummary(
        start_tick=start_tick,
        births=len(late_rows),
        unique_lineages=len(late_child_ids),
        unique_expr_hashes=len({row.expr_hash for row in late_rows}),
        productive_lineages=len(productive_late_lineages),
        branching_parents=sum(1 for children in children_by_parent.values() if len(children) > 1),
        fraction_productive=len(productive_late_lineages) / len(late_child_ids) if late_child_ids else 0.0,
    )

