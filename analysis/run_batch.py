from __future__ import annotations

import argparse
import json
import subprocess
import sys
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run LambLife across many seeds and store outputs in per-seed directories.")
    parser.add_argument("--output-root", type=Path, required=True, help="Directory that will contain one subdirectory per seed")
    parser.add_argument("--seeds", type=int, nargs="+", required=True, help="Explicit seed list")
    parser.add_argument("--ticks", type=int, required=True, help="Ticks to run per seed")
    parser.add_argument(
        "--command",
        nargs="+",
        default=["zig", "build", "-Doptimize=ReleaseFast", "run", "--"],
        help="Command prefix used to launch the simulator before LambLife arguments are appended",
    )
    parser.add_argument(
        "--extra-arg",
        action="append",
        default=[],
        help="Extra simulator argument like --width=100. May be repeated.",
    )
    parser.add_argument(
        "--stream",
        action="store_true",
        help="Mirror each run's output to stdout while still writing run.log",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    args.output_root.mkdir(parents=True, exist_ok=True)

    manifest: list[dict[str, object]] = []

    for seed in args.seeds:
        run_dir = args.output_root / f"seed_{seed}"
        run_dir.mkdir(parents=True, exist_ok=True)

        metrics_path = run_dir / "metrics.csv"
        lineage_path = run_dir / "lineage.csv"
        snapshot_dir = run_dir / "snapshots"
        command_path = run_dir / "command.txt"
        log_path = run_dir / "run.log"

        cmd = [
            *args.command,
            f"--seed={seed}",
            f"--ticks={args.ticks}",
            f"--metrics={metrics_path}",
            f"--lineage={lineage_path}",
            f"--snapshot-dir={snapshot_dir}",
            *args.extra_arg,
        ]

        print(f"[run_batch] seed={seed} -> {run_dir}")
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
            raise SystemExit(f"[run_batch] seed={seed} failed with exit code {result_code}. See {log_path}")
        manifest.append(
            {
                "seed": seed,
                "run_dir": str(run_dir),
                "metrics": str(metrics_path),
                "lineage": str(lineage_path),
                "snapshots": str(snapshot_dir),
                "command": str(command_path),
                "log": str(log_path),
            }
        )

    (args.output_root / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    print(f"[run_batch] wrote manifest to {args.output_root / 'manifest.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
