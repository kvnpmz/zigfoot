# Performance after the Zig 0.17 migration

Date: **2026-11-26**. Tree: `6957641e` (Zig 0.17 target). C oracle:
`6b3f557daaae17f4572fd7e850767f5c607a3caa` (the ref used by
`scripts/render-parity.sh`). Compiler: Zig **0.17.0**; the 0.16.0 baseline is a
worktree at `f0a7a8fe` (last pre-migration revision). Machine: i5-1235U, 12
logical CPUs, x86_64 Linux, no compositor.

This document measures two things independently:

1. **Toolchain effect**: is 0.17 slower or faster than 0.16 for the same
   source? Measured by running both trees' harnesses in the same session.
2. **Port cost**: how does Zig compare to the C oracle? Measured in the same
   interleaved session, with CPU pinning.

## Why not just re-run `scripts/perf-compare.sh`

`perf-compare.sh` measures variants **sequentially** (C -O3, C -O2, Zig RS,
Zig RF) and does **not pin** the CPU. On this Alder Lake-U part, an unpinned
process may land on a 4.4 GHz P-core or a 3.3 GHz E-core, so the same C
binary measured 5.5–12.0 µs/sequence across sessions and the Zig/C ratio
ranged from 1.23× to 1.67× for identical code. The published 1.28×/1.08×
figures in `doc/perf-1.2.md` come from one such single sequential run; they
are not reproducible as a controlled figure. The measurement below replaces
them for the VT claim and keeps `perf-1.2.md` as the historical record.

Method used here:

* The harness binaries already built by `perf-compare.sh` are reused
  (`.../out/{render,config,vt}-{c-o3,c-o2,zig-rs,zig-fast}`); nothing is
  rebuilt, so both trees see the identical corpus and build flags.
* All eight binaries (4 variants × 2 trees) are measured **interleaved**: the
  order is rotated by one position every repetition, so each variant samples
  every position and linear drift cancels.
* The whole driver and its children are pinned to one P-core
  (`sched_setaffinity`), cores 0 and 2 were used and agree.
* Repetitions: render 21, config 10–15, VT 40. Medians are reported.
* VT additionally separates **process launch** from **work**: each binary is
  timed with 1 and with 2000 sequences in the same process, and the
  per-sequence figure is `(t2000 − t1) / 1999`.
* The C/C control (same C code from both trees) is included as a noise floor.

Reproduce with `scripts/perf-pinned.py` (tracked) against the builds that
`scripts/perf-compare.sh` cached:

```sh
./scripts/perf-compare.sh                       # builds, once (cached)
scripts/perf-pinned.py --cpu 0 --baseline f0a7a8fe --reps 20 vt
```

## Results

Medians, pinned to core 0. "016" is the Zig 0.16.0 build of `f0a7a8fe`; "017"
is the Zig 0.17.0 build of `6957641e`. The C row is the same C binary family
in both runs and is the control.

### Render corpus (1058 cells × 3 scales, 10 corpus runs/process)

| Variant | 016 ms/run | 017 ms/run | 017/016 | 017 vs C |
|---|---:|---:|---:|---:|
| C `-O3` | 41.442 | 40.968 | 0.99 | — |
| C `-O2` | 41.139 | 41.296 | 1.00 | 1.01 |
| Zig ReleaseSafe | 44.624 | 44.354 | 0.99 | **1.083** |
| Zig ReleaseFast | 42.642 | 42.795 | 1.00 | **1.045** |

Process launch is included in these numbers. The VT decomposition below puts
launch at ≈1.2 ms (C) / 4.3 ms (Zig RS) / 2.7 ms (Zig RF); subtracting those
puts Zig render work at **parity** with C (`1.007×` RS, `1.010×` RF).

### Config parsing (23 shared `test_section_*`, 100 suites/process)

| Variant | 016 ms/run | 017 ms/run | 017/016 | 017 vs C |
|---|---:|---:|---:|---:|
| C `-O3` | 2221.2 | 2199.6 | 1.00 | — |
| Zig ReleaseSafe | 2113.9 | 2093.5 | 0.99 | **0.952** (5% faster) |
| Zig ReleaseFast | 1950.9 | 1952.1 | 1.00 | **0.888** (11% faster) |

Config is dominated by parsing, not launch (<0.2% of the 2.2 s run).

### VT input (one 173-byte escape stream × 2000, 8×80 grid)

| Variant | launch ms | 2000 seq ms | per seq µs | vs C (work) | vs C (whole process) |
|---|---:|---:|---:|---:|---:|
| C `-O3` | 1.23 | 6.51 | 2.64 | — | — |
| C `-O2` | 1.28 | 6.67 | 2.70 | 1.02 | 1.02 |
| Zig ReleaseSafe | 4.27 | 11.46 | **3.54–3.59** | **1.30–1.36** | **1.70–1.76** |
| Zig ReleaseFast | 2.71 | 9.22 | **3.25–3.26** | **1.20–1.24** | **1.40–1.42** |

The ranges are across repeated runs on cores 0 and 2 (`perf-pinned.py`).

The 0.16 build measures the same: RS 3.60 µs/seq (1.37× C), RF 3.28 µs/seq
(1.24× C), launch 4.23 / 2.72 ms. All four variants produce the same grid
hash (`346edf2968805e68`), so they perform the same work.

### Toolchain verdict

0.17 vs 0.16, normalized to the C control measured in the same session:
render +0.6%, config ±0.0–1.1%, VT +0–2%. The C/C control differs by 1.0–1.2%
between trees, which is the noise floor. **The toolchain migration costs no
measurable performance.**

### Port-cost verdict

* Render: parity once process launch is excluded; +8% RS / +4.5% RF wall-clock.
* Config: Zig is 5% (RS) / 11% (RF) faster than C.
* VT: ~1.3× (RS) / ~1.2× (RF) of C per sequence; whole-process ~1.7× / ~1.4×
  because the Zig binary starts ~1.5–3.0 ms slower. Stripping changes launch
  time by only ~0.2 ms (4.26 → 4.10 ms RS), so this is not debug-info paging;
  it is Zig runtime start-up plus relocation of the much larger image
  (96 MB RS / 57 MB RF unstripped, 19 MB / 9 MB stripped, vs 0.66 MB for C).

## Limitations

* One machine, one microarchitecture, one core at a time; no frequency
  counters, no `perf`, no compositor. Absolute numbers are not transferable.
* The VT corpus is a single fixed escape stream; it exercises SGR, cursor
  movement, erase and UTF-8, not sixel, reflow or scroll-heavy work.
* Render and config compare the harnesses built by `perf-compare.sh`; the
  release-mode mapping (RS/RF) and the 1058-cell corpus are pinned by that
  script's own assertions.
* No frame-rate, input-latency or startup-to-first-frame claim is made.
