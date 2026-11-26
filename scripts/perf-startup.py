#!/usr/bin/env python3
"""Measure foot startup-to-child-exec and full process lifetime.

Requires a live Wayland compositor (XDG_RUNTIME_DIR + WAYLAND_DISPLAY).
Each variant is run interleaved with the others so drift affects all equally.

Usage:
  scripts/perf-startup.py --builds /tmp/foot-perf-cache/.../builds --reps 15
  ... --scrollback 10000 --workers 12 --extra '-o,tweak.slow-blur=1'
"""
import argparse
import os
import statistics
import subprocess
import sys
import tempfile
import time

VARIANTS = ("c-o3", "c-o2", "zig-rs", "zig-fast")


def stat(xs):
    xs = sorted(xs)
    med = statistics.median(xs)
    p95 = xs[min(len(xs) - 1, int(round(0.95 * (len(xs) - 1))))]
    return med, p95


def main() -> int:
    p = argparse.ArgumentParser()
    p.add_argument("--builds", required=True,
                   help="directory containing c-o3/, c-o2/, zig-rs/, zig-fast/")
    p.add_argument("--reps", type=int, default=15)
    p.add_argument("--scrollback", type=int, default=None)
    p.add_argument("--workers", type=int, default=None)
    p.add_argument("--variants", default=",".join(VARIANTS))
    args = p.parse_args()

    variants = [v for v in args.variants.split(",") if v]
    missing = [v for v in variants if not os.access(f"{args.builds}/{v}/foot", os.X_OK)]
    if missing:
        print(f"perf-startup: no foot binary for {', '.join(missing)}", file=sys.stderr)
        return 2
    if not os.environ.get("WAYLAND_DISPLAY") or not os.environ.get("XDG_RUNTIME_DIR"):
        print("perf-startup: WAYLAND_DISPLAY and XDG_RUNTIME_DIR are required",
              file=sys.stderr)
        return 2

    opts = []
    if args.scrollback is not None:
        opts += ["-o", f"scrollback.lines={args.scrollback}"]
    if args.workers is not None:
        opts += ["-o", f"workers={args.workers}"]

    res = {v: {"exec": [], "life": []} for v in variants}
    for _ in range(args.reps):
        for v in variants:
            fd, stamp = tempfile.mkstemp(prefix="foot-start-", suffix=".ns")
            os.close(fd)
            os.unlink(stamp)
            try:
                t0 = time.time_ns()
                p0 = time.perf_counter_ns()
                subprocess.run(
                    [f"{args.builds}/{v}/foot", *opts, "-e", "sh", "-c",
                     f"date +%s%N > {stamp}"],
                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    timeout=30, check=False)
                p1 = time.perf_counter_ns()
                try:
                    with open(stamp) as f:
                        t_child = int(f.read().strip())
                    res[v]["exec"].append((t_child - t0) / 1e6)
                except (FileNotFoundError, ValueError):
                    res[v]["exec"].append(float("nan"))
                res[v]["life"].append((p1 - p0) / 1e6)
            finally:
                try:
                    os.unlink(stamp)
                except FileNotFoundError:
                    pass

    print("variant reps exec_med_ms exec_p95_ms life_med_ms life_p95_ms")
    for v in variants:
        em, ep = stat(res[v]["exec"])
        lm, lp = stat(res[v]["life"])
        print(f"{v} {args.reps} {em:.2f} {ep:.2f} {lm:.2f} {lp:.2f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
