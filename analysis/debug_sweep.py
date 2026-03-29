from __future__ import annotations

import argparse
import itertools
import json
import subprocess
import sys
from pathlib import Path


def parse_assignment(value: str) -> tuple[str, list[str]]:
    if "=" not in value:
        raise argparse.ArgumentTypeError(f"expected NAME=v1,v2,..., got: {value!r}")
    name, raw_values = value.split("=", 1)
    values = [item.strip() for item in raw_values.split(",") if item.strip()]
    if not name.strip() or not values:
        raise argparse.ArgumentTypeError(f"expected NAME=v1,v2,..., got: {value!r}")
    return name.strip(), values


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a small cartesian parameter sweep for LambLife debugging.")
    parser.add_argument("--output-root", type=Path, required=True, help="Directory where one run directory per parameter combo will be created")
    parser.add_argument("--seed", type=int, default=1, help="Seed used for all runs")
    parser.add_argument("--ticks", type=int, default=200, help="Ticks per run")
    parser.add_argument(
        "--command",
        nargs="+",
        default=["zig", "build", "-Doptimize=ReleaseFast", "run", "--"],
        help="Command prefix used to launch the simulator",
    )
    parser.add_argument(
        "--param",
        action="append",
        default=[],
        type=parse_assignment,
        help="Parameter sweep assignment in the form name=v1,v2,...; may be repeated",
    )
    parser.add_argument(
        "--base-arg",
        action="append",
        default=[],
        help="Extra simulator argument applied to every run, such as --log_interval=1",
    )
    parser.add_argument("--stream", action="store_true", help="Mirror simulator output to stdout while writing run.log")
    return parser.parse_args()


def combo_name(names: list[str], values: tuple[str, ...]) -> str:
    return "__".join(f"{name}_{value}" for name, value in zip(names, values, strict=True))


def main() -> int:
    args = parse_args()
    args.output_root.mkdir(parents=True, exist_ok=True)

    param_names = [name for name, _ in args.param]
    param_value_lists = [values for _, values in args.param]
    combos = list(itertools.product(*param_value_lists)) if param_value_lists else [()]

    manifest: list[dict[str, object]] = []

    for combo_values in combos:
        run_name = combo_name(param_names, combo_values) if combo_values else "baseline"
        run_dir = args.output_root / run_name
        run_dir.mkdir(parents=True, exist_ok=True)

        metrics_path = run_dir / "metrics.csv"
        lineage_path = run_dir / "lineage.csv"
        snapshot_dir = run_dir / "snapshots"
        command_path = run_dir / "command.txt"
        log_path = run_dir / "run.log"

        sweep_args = [f"--{name}={value}" for name, value in zip(param_names, combo_values, strict=True)]
        cmd = [
            *args.command,
            f"--seed={args.seed}",
            f"--ticks={args.ticks}",
            f"--metrics={metrics_path}",
            f"--lineage={lineage_path}",
            f"--snapshot-dir={snapshot_dir}",
            *args.base_arg,
            *sweep_args,
        ]

        print(f"[debug_sweep] {run_name} -> {run_dir}")
        command_path.write_text(" ".join(str(part) for part in cmd) + "\n", encoding="utf-8")

        with log_path.open("w", encoding="utf-8") as log_handle:
            if args.stream:
                process = subprocess.Popen(
                    cmd,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                )
                assert process.stdout is not None
                for line in process.stdout:
                    log_handle.write(line)
                    log_handle.flush()
                    sys.stdout.write(line)
                    sys.stdout.flush()
                result_code = process.wait()
            else:
                result = subprocess.run(cmd, stdout=log_handle, stderr=subprocess.STDOUT, text=True)
                result_code = result.returncode

        if result_code != 0:
            raise SystemExit(f"[debug_sweep] {run_name} failed with exit code {result_code}. See {log_path}")

        manifest.append(
            {
                "name": run_name,
                "run_dir": str(run_dir),
                "seed": args.seed,
                "ticks": args.ticks,
                "params": dict(zip(param_names, combo_values, strict=True)),
                "metrics": str(metrics_path),
                "lineage": str(lineage_path),
                "log": str(log_path),
            }
        )

    (args.output_root / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"[debug_sweep] wrote manifest to {args.output_root / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
