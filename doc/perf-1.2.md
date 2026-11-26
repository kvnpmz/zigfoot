# Post-port performance comparison (1.2)

Date of measurement: **2026-11-26T09:11:17Z**. HEAD:
`66a61615ade98711419b6a343e6bc5b5c30c6fa1`. C oracle:
`6b3f557daaae17f4572fd7e850767f5c607a3caa` (the ref used by
`scripts/render-parity.sh`). All numbers below come from one end-to-end run of
`scripts/perf-compare.sh`; none are estimated or copied from elsewhere.

## Scope and methodology

There is no compositor, Wayland socket, `hyperfine`, `perf`, or `weston`/`sway`
in the measurement container. End-to-end frame rate, input latency and
startup-to-first-frame are therefore **not measurable here** and are not
claimed. The harness measures only deterministic, headless work that both
implementations actually perform:

1. **Render corpus**: `tests/test-render-parity.c` paints the same deterministic
   corpus (1058 cells at 3 scales) against the C oracle painters and the Zig
   painters, using the same `--wrap` protocol stubs as `scripts/render-parity.sh`.
   The private copy skips FNV hashing/printing so the timing reflects painting;
   the unmodified Zig harness was run once to count the 1058 `CELL` lines.
   One process performs 10 corpus runs (30 scale runs); 12 processes are timed.
2. **Config parsing**: the 23 `test_section_*` functions common to the oracle's
   `tests/test-config.c` and HEAD's copy are called 100 times in one process
   (23 000 parser test-section runs), with assertions forced on via
   `-UNDEBUG`. Each copy is compiled against its own parser; test bodies that
   were extended during the port are still the respective side's own bodies,
   so this compares the whole tested parse path, not a byte-identical test C
   file.
3. **VT input**: one shared driver (`tests/fuzz-vt.c`-style minimal fixture: one
   PTY, 8x80 grid, no seat/config file) feeds the same fixed 173-byte escape
   stream in 1–3 chunks, 2000 times per process. Its final FNV hash of the
   normal grid is printed and checked: all four variants produced
   `346edf2968805e68`, so the same work was done.
4. **RSS**: `resource.getrusage(RUSAGE_CHILDREN).ru_maxrss` from the fresh Python
   process that timed that harness (peak RSS of the child, KiB).

Each configuration is run 12 times in separate processes. The script reports
the median and p95 (nearest-rank) per process and per unit of work, plus all
raw samples; no single-run claims are made. Runs are sequential per benchmark
in the order C(-O3), C(-O2), Zig ReleaseSafe, Zig ReleaseFast, so drift affects
later variants; the full sample list makes that visible.

Builds are hermetic: `git archive` snapshots of HEAD and the oracle are
extracted under `TMPDIR` (default `/tmp`), meson builds go under `BUILD_DIR`
(default inside the same work area), and a trap removes both on exit. Zig
`release` maps to ReleaseSafe via `compile_zig.py`; a private copy of that file
in the ReleaseFast tree is patched to map `release` to ReleaseFast, and the
script asserts the mapping is present (47 Zig modules compiled). No tracked
file other than the two deliverables was changed by this work.

## Exact commands

```sh
cd /workspace
sh scripts/perf-compare.sh                 # default: 12 reps
# tunable example:
# PERF_REPS=20 PERF_CONFIG_ITERS=50 BUILD_DIR=/tmp/perf-builds \
#   ZIG_GLOBAL_CACHE_DIR=/tmp/zig-global-cache sh scripts/perf-compare.sh
```

Output of the successful run (verbatim `perf:` lines; `date` is UTC):

```text
perf: mode_check=zig-fast optimize=ReleaseFast zig_modules=47
perf: benchmark=cells count=1058 scales=3 head=66a61615ade98711419b6a343e6bc5b5c30c6fa1 oracle=6b3f557daaae17f4572fd7e850767f5c607a3caa
perf: settings reps=12 render_iters=10 config_iters=100 vt_iters=2000 date=2026-11-26T09:11:17Z
perf: env cpu=12th Gen Intel(R) Core(TM) i5-1235U cpus=12 zig=0.16.0 cc=cc (GCC) 14.2.1 20250405 meson=1.12.0 python=3.14.8
perf: c_variant=o3 cc_flags=-O3 -fno-asynchronous-unwind-tables
perf: c_variant=o2 cc_flags=-O3 -fno-asynchronous-unwind-tables -O2
perf: benchmark=render variant=c-o3 reps=12 inner=10 unit=corpus_runs median_ms_per_run=45.913 p95_ms_per_run=52.495 median_us_per_unit=4591.28 p95_us_per_unit=5249.47 rss_kib=13008 samples_ms=45.03,45.28,45.48,45.62,45.79,45.87,45.96,47.07,49.48,50.10,52.12,52.49
perf: benchmark=render variant=c-o2 reps=12 inner=10 unit=corpus_runs median_ms_per_run=46.461 p95_ms_per_run=53.965 median_us_per_unit=4646.13 p95_us_per_unit=5396.50 rss_kib=12952 samples_ms=45.47,45.50,45.53,45.64,46.07,46.29,46.64,46.64,48.68,49.70,51.82,53.96
perf: benchmark=render variant=zig-rs reps=12 inner=10 unit=corpus_runs median_ms_per_run=50.492 p95_ms_per_run=69.831 median_us_per_unit=5049.23 p95_us_per_unit=6983.06 rss_kib=23604 samples_ms=49.01,49.64,49.65,49.81,49.89,50.47,50.51,50.90,51.75,53.19,57.25,69.83
perf: benchmark=render variant=zig-fast reps=12 inner=10 unit=corpus_runs median_ms_per_run=50.558 p95_ms_per_run=55.830 median_us_per_unit=5055.82 p95_us_per_unit=5583.05 rss_kib=17396 samples_ms=46.79,46.82,47.08,47.46,49.55,50.37,50.74,50.80,51.21,51.46,54.99,55.83
perf: benchmark=config variant=c-o3 reps=12 inner=100 unit=config_suites median_ms_per_run=1097.609 p95_ms_per_run=1141.639 median_us_per_unit=10976.09 p95_us_per_unit=11416.39 rss_kib=247676 samples_ms=1049.51,1057.02,1066.77,1080.02,1093.70,1097.40,1097.82,1106.30,1106.61,1107.37,1110.69,1141.64
perf: benchmark=config variant=c-o2 reps=12 inner=100 unit=config_suites median_ms_per_run=1075.954 p95_ms_per_run=1092.519 median_us_per_unit=10759.54 p95_us_per_unit=10925.19 rss_kib=246960 samples_ms=1047.66,1051.74,1054.41,1058.36,1062.39,1074.60,1077.31,1083.93,1085.59,1087.75,1091.38,1092.52
perf: benchmark=config variant=zig-rs reps=12 inner=100 unit=config_suites median_ms_per_run=1086.698 p95_ms_per_run=1184.565 median_us_per_unit=10866.98 p95_us_per_unit=11845.65 rss_kib=238832 samples_ms=1049.77,1062.26,1071.95,1072.09,1074.44,1082.88,1090.51,1090.79,1114.93,1117.71,1125.88,1184.57
perf: benchmark=config variant=zig-fast reps=12 inner=100 unit=config_suites median_ms_per_run=980.554 p95_ms_per_run=1023.663 median_us_per_unit=9805.54 p95_us_per_unit=10236.63 rss_kib=233756 samples_ms=965.53,968.16,970.72,974.65,975.25,976.27,984.84,995.92,999.75,1000.09,1014.37,1023.66
perf: benchmark=vt variant=c-o3 reps=12 inner=2000 unit=vt_sequences median_ms_per_run=10.963 p95_ms_per_run=14.782 median_us_per_unit=5.48 p95_us_per_unit=7.39 rss_kib=12816 samples_ms=9.30,10.22,10.30,10.50,10.78,10.96,10.97,11.42,11.55,11.58,14.32,14.78 result_hash=346edf2968805e68
perf: benchmark=vt variant=c-o2 reps=12 inner=2000 unit=vt_sequences median_ms_per_run=10.885 p95_ms_per_run=11.880 median_us_per_unit=5.44 p95_us_per_unit=5.94 rss_kib=13032 samples_ms=8.10,8.21,8.55,9.62,9.92,10.60,11.17,11.49,11.63,11.64,11.79,11.88 result_hash=346edf2968805e68
perf: benchmark=vt variant=zig-rs reps=12 inner=2000 unit=vt_sequences median_ms_per_run=14.038 p95_ms_per_run=20.015 median_us_per_unit=7.02 p95_us_per_unit=10.01 rss_kib=16680 samples_ms=12.69,12.78,12.83,13.43,13.58,13.96,14.11,14.83,14.88,15.95,17.15,20.01 result_hash=346edf2968805e68
perf: benchmark=vt variant=zig-fast reps=12 inner=2000 unit=vt_sequences median_ms_per_run=11.798 p95_ms_per_run=12.199 median_us_per_unit=5.90 p95_us_per_unit=6.10 rss_kib=13008 samples_ms=10.62,11.13,11.53,11.73,11.78,11.78,11.82,11.84,11.91,11.93,11.95,12.20 result_hash=346edf2968805e68
perf: not_measured=startup_to_first_frame reason=no_compositor
perf: not_measured=fps_input_latency reason=no_compositor
perf-compare: complete
```

## Result table (medians; smaller is better)

| Benchmark | unit | C `-O3` | C `-O2` | Zig ReleaseSafe | Zig ReleaseFast |
|---|---|---:|---:|---:|---:|
| Render corpus (1058 cells x 3 scales) | µs/corpus run | 4591.28 | 4646.13 | 5049.23 | 5055.82 |
| Render p95 | µs/corpus run | 5249.47 | 5396.50 | 6983.06 | 5583.05 |
| Config parsing (23 shared test sections) | µs/test-suite | 10976.09 | 10759.54 | 10866.98 | 9805.54 |
| Config p95 | µs/test-suite | 11416.39 | 10925.19 | 11845.65 | 10236.63 |
| VT input (fixed 173-byte stream) | µs/sequence | 5.48 | 5.44 | 7.02 | 5.90 |
| VT p95 | µs/sequence | 7.39 | 5.94 | 10.01 | 6.10 |
| Peak RSS, render harness | KiB | 13008 | 12952 | 23604 | 17396 |
| Peak RSS, config harness | KiB | 247676 | 246960 | 238832 | 233756 |
| Peak RSS, VT harness | KiB | 12816 | 13032 | 16680 | 13008 |

The `-O2` C build was meson `release` plus `-Dc_args=-O2`; the logged compile
line contains both `-O3 -O2`, so the last (`-O2`) wins. It is not a separate
`-O0`/debug build.

## Interpretation

* **Safety-check tax is workload dependent, not a flat number.** In VT
  parsing, ReleaseSafe is 7.02 vs 5.90 µs/sequence for ReleaseFast: about 19%
  slower, consistent with bounds checks in hot parser/grid code, and its p95
  tail is worse (10.01 vs 6.10 µs). In config parsing the tax is about 11%
  (10867 vs 9806 µs/suite). In the render corpus it is invisible: ReleaseSafe
  and ReleaseFast are both ~5.05 ms/corpus, within noise. That path spends
  most of its time in the unchanged C pixman/fcft libraries, so Zig code
  generation hardly moves the total.
* **Against C**, the same numbers say: render is ~10% slower in either Zig
  mode; config is ~1% faster in ReleaseSafe and ~11% faster in ReleaseFast
  than C `-O3`; VT is ~28% slower in ReleaseSafe and ~8% slower in ReleaseFast
  (5.48 µs baseline). C `-O2` is essentially equal to `-O3` on these tasks
  (within 2%), so the C comparison is not an artifact of an unusual C build.
* **RSS** tracks the Zig runtime/artifacts: ReleaseSafe uses ~10 MB more than
  ReleaseFast on render and ~3.7 MB more on VT; config is dominated by
  fontconfig and all four variants are in the 234–248 MB range.
* All four VT harnesses produced the same grid hash, so the VT comparison is
  apples-to-apples. The config suite runs the 23 shared test functions; the
  ported copy has additional assertions inside some of them, so treat its
  comparison as a whole-path comparison rather than a microbenchmark of one
  parser function.

## Not measured (and why)

* **No compositor / Wayland socket**: no FPS, frame time, startup-to-first-frame,
  input latency, resize latency or Wayland protocol throughput. `foot --version`
  was deliberately **not** timed: it exits before config parsing, terminal
  creation or any Wayland connection, so its process startup would mostly
  measure dynamic linking and would be misleading as "foot startup".
* **No `hyperfine`, `perf` or equivalent**: timings are wall-clock medians of
  process runs; no CPU pinning, no isolation, no instruction/branch counters
  and no confidence intervals beyond the printed samples.
* **No end-to-end terminal throughput**: the upstream `scripts/benchmark.py`
  writer needs a live terminal and was not usable headless.
* **No wall-clock build-time comparison**: the harness builds all four
  variants but does not time those builds.

## Flakiness notes

The run is reproducible but not noise-free. The render ReleaseSafe sample set
contains one 69.83 ms outlier against a 50 ms median; the config suites vary
~10% between fastest and slowest samples; VT C `-O3` has a 14.78 ms tail
against an 11 ms median. Medians and p95 are reported precisely because single
runs would be misleading. Re-run with `PERF_REPS=20` or more when deciding a
close call, and keep the machine otherwise idle; the script exits non-zero if
any measurement process fails or if its expected completion marker is missing.
