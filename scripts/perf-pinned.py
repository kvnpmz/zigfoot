#!/usr/bin/env -S python3 -u
"""Interleaved, CPU-pinned comparison of the perf-compare harness binaries.

`scripts/perf-compare.sh` measures variants sequentially (C -O3, C -O2, Zig
ReleaseSafe, Zig ReleaseFast) and does not pin the CPU. On a hybrid CPU the
same binary can land on a P-core or an E-core, and drift biases later
variants, so the Zig/C ratio it prints is not reproducible. This driver reuses
the binaries that perf-compare.sh built and measures all variants round-robin
on one core, rotating the order every repetition so drift cancels.

It also separates process launch from work for `vt`: each binary is timed with
1 and with INNER iterations in the same process, and the per-sequence figure
is (t_inner - t_1) / (INNER - 1).

Prerequisite: one `scripts/perf-compare.sh` run so the cache exists, e.g.

    ./scripts/perf-compare.sh
    scripts/perf-pinned.py --baseline f0a7a8fe vt

Usage:
    perf-pinned.py [--head SHA] [--baseline SHA] [--oracle REF]
                   [--cache DIR] [--cpu N] [--reps N] BENCH

BENCH is render, config or vt. --baseline is optional: without it only the
current HEAD is measured. The cache layout is the one perf-compare.sh writes:
$PERF_CACHE_DIR/head-<sha>-oracle-<sha>/out/<bench>-<variant>.

Output: one JSON object on stdout (medians, p95, raw samples, ratios). Nothing
is written to disk and no tracked file is touched.
"""

import argparse
import json
import math
import os
import statistics
import subprocess
import sys
import time
from typing import Any

VARIANTS = ("c-o3", "c-o2", "zig-rs", "zig-fast")
INNER: dict[str, int | None] = {"render": None, "config": 100, "vt": 2000}
EXPECT = {
    "render": "render: ok",
    "config": "config: iterations=",
    "vt": "vt: iterations=",
}


def git_sha(ref: str) -> str:
    return subprocess.run(
        ["git", "rev-parse", ref], capture_output=True, text=True, check=True
    ).stdout.strip()


def out_dir(cache: str, head: str, oracle: str) -> str:
    return os.path.join(cache, f"head-{head}-oracle-{oracle}", "out")


def measure(path: str, bench: str, inner: int | None) -> tuple[float, str]:
    args = [path] + ([str(inner)] if inner else [])
    start = time.perf_counter_ns()
    proc = subprocess.run(args, check=False, capture_output=True, text=True)
    elapsed = (time.perf_counter_ns() - start) / 1e6
    if proc.returncode != 0 or EXPECT[bench] not in proc.stdout:
        sys.exit(
            f"measurement failed: {path} rc={proc.returncode}\n"
            f"{proc.stdout[-400:]}\n{proc.stderr[-400:]}"
        )
    return elapsed, proc.stdout


def summarize(samples: list[float]) -> dict[str, Any]:
    ordered = sorted(samples)
    return {
        "median_ms": round(statistics.median(ordered), 3),
        "p95_ms": round(
            ordered[min(len(ordered) - 1, math.ceil(len(ordered) * 0.95) - 1)], 3
        ),
        "min_ms": round(ordered[0], 3),
        "max_ms": round(ordered[-1], 3),
        "samples_ms": [round(x, 2) for x in ordered],
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("bench", choices=sorted(INNER))
    parser.add_argument("--head", default="HEAD")
    parser.add_argument("--baseline")
    parser.add_argument("--oracle", default="6b3f557d")
    parser.add_argument(
        "--cache", default=os.environ.get("PERF_CACHE_DIR", "/tmp/foot-perf-cache")
    )
    parser.add_argument("--cpu", type=int)
    parser.add_argument("--reps", type=int, default=15)
    args = parser.parse_args()

    if args.cpu is not None:
        try:
            os.sched_setaffinity(0, {args.cpu})
        except OSError as exc:
            sys.exit(f"cannot pin to cpu {args.cpu}: {exc}")

    head = git_sha(args.head)
    oracle = git_sha(args.oracle)
    trees = {"head": (head, out_dir(args.cache, head, oracle))}
    if args.baseline:
        base = git_sha(args.baseline)
        trees["baseline"] = (base, out_dir(args.cache, base, oracle))

    entries: list[tuple[str, str, str]] = []
    for tree, (_sha, directory) in trees.items():
        for variant in VARIANTS:
            path = os.path.join(directory, f"{args.bench}-{variant}")
            if not os.access(path, os.X_OK):
                sys.exit(
                    f"missing {path}; run scripts/perf-compare.sh once to build "
                    "the cache (or pass --cache)"
                )
            entries.append((tree, variant, path))

    inner = INNER[args.bench]
    launch: dict[tuple[str, str], float] = {}
    if args.bench == "vt":
        for tree, variant, path in entries:
            measure(path, args.bench, 1)
            launch[(tree, variant)] = statistics.median(
                measure(path, args.bench, 1)[0] for _ in range(15)
            )
    for _tree, _variant, path in entries:
        measure(path, args.bench, inner)

    samples: dict[tuple[str, str], list[float]] = {
        (tree, variant): [] for tree, variant, _path in entries
    }
    hashes = set()
    for rep in range(args.reps):
        offset = rep % len(entries)
        for tree, variant, path in entries[offset:] + entries[:offset]:
            elapsed, out = measure(path, args.bench, inner)
            samples[(tree, variant)].append(elapsed)
            if "hash=" in out:
                hashes.add(out.split("hash=")[1].split()[0])

    results: dict[str, dict[str, Any]] = {}
    for key, values in samples.items():
        place = f"{key[0]}/{key[1]}"
        stats = summarize(values)
        if args.bench == "vt":
            assert inner is not None
            stats["launch_ms"] = round(launch[key], 3)
            stats["per_unit_us"] = round(
                (stats["median_ms"] - launch[key]) * 1000 / (inner - 1), 3
            )
        elif inner:
            stats["per_unit_us"] = round(stats["median_ms"] * 1000 / inner, 3)
        results[place] = stats

    # Ratios are only meaningful within one tree (same session, same core).
    for tree in trees:
        c_ms = results[f"{tree}/c-o3"]["median_ms"]
        for variant in VARIANTS[2:]:
            place = f"{tree}/{variant}"
            results[place]["ratio_vs_c_o3"] = round(
                results[place]["median_ms"] / c_ms, 4
            )
            if args.bench == "vt":
                results[place]["ratio_work_vs_c"] = round(
                    results[place]["per_unit_us"]
                    / results[f"{tree}/c-o3"]["per_unit_us"],
                    4,
                )

    print(
        json.dumps(
            {
                "bench": args.bench,
                "reps": args.reps,
                "inner": inner,
                "cpu": args.cpu,
                "trees": {tree: sha for tree, (sha, _dir) in trees.items()},
                "hashes": sorted(hashes),
                "results": results,
            },
            indent=2,
        )
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
