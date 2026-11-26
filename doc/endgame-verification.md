# Endgame verification — 1.2 final

Base: `ab5f4261` (measured in a clean worktree, 2026-11-26).
Toolchain: `/opt/zig/zig` 0.16.0, GCC 14.2.1, Clang 21.1.8.

This is the 1.2 verification matrix. Every result below was reproduced on
`ab5f4261`; historical 1.0/1.1 results are kept at the bottom, explicitly
labelled, and are not evidence for 1.2. The full ledger with per-number
provenance is `MIGRATION_PLAN.md` §15.10.

| Check | Command | Result (measured on ab5f4261) |
|---|---|---|
| Full gate | `sh scripts/full-check.sh` | Exit 0. `build`, `build-disabled`, `build-release`: **9/9**, `Fail: 0`, no skips; render parity invoked; six smoke launches, `smoke: ok`. |
| Debug suite list | `meson test -C build` | **9/9**: `execvpe`, `regex`, `shims`, `config`, `abi-probe-up-to-date`, `render-parity`, `zig-grid`, `zig-terminal_types`, `terminal-harness`. |
| Disabled-features config | `meson test -C build-disabled` | **9/9**, `Fail: 0` (grapheme clustering off). |
| ReleaseSafe config | `meson test -C build-release` | **9/9**, `Fail: 0`; the config test overrides `b_ndebug=false`. |
| Harness assertions | `awk '/^test: /{s=$2}/^ok:/{n[s]++}END{for(k in n)print k,n[k]}' build/meson-logs/testlog.txt` | **1,040 `ok:` lines** = 990 terminal-harness + 39 shims + 11 regex. `test-terminal.c` has 875 `check()` sites (67 `check_text()` sites in addition; 942 combined), measured by `rg -o '\bcheck\s*\('`. |
| execvpe | `meson test -C build` (testlog `foot:execvpe`) | **11/11 PASS**: empty file → `ENOENT`, empty PATH → cwd, `ESTALE`/`ENODEV`/`ETIMEDOUT` continue, PATH from `envp` beats `getenv`/`environ` (documented divergence). |
| Shim regressions | `meson test -C build` (testlog `foot:shims`) | **39 checks**, all pass (memfd/seal/punch-hole, regex without a capture group). |
| Render parity | `ORACLE_REF=6b3f557d bash scripts/render-parity.sh` | **PASS, 1,058 cells across 3 scales** (362/348/348). `TOTAL e5184e0fe5898153` (1.04999995), `TOTAL b7cebabc45627f13` (0.833333313), `TOTAL 87c0bab0d0d6829b` (scale 2). Script uses a fresh `$TMPDIR` work dir and removes its pinned oracle worktree via an `EXIT` trap. |
| Leak gate | `valgrind -q --error-exitcode=99 --leak-check=full ./build/tests/test-terminal` | Exit **0**; main process **0 definitely/indirectly lost**. Residual: **8 records × 320 B (2,560 B total = 2,048 direct + 512 indirect)** in non-main (worker/child) logs only, stacks in libfontconfig/libexpat `XML_ParseBuffer`, no foot frame. |
| Other leak gates | `valgrind -q --error-exitcode=99 --leak-check=full ./build/tests/test-shims` and `./build/tests/test-execvpe` | Both exit 0, no definitely/indirectly lost lines. |
| Fuzz | `bash scripts/fuzz-vt.sh 120` | `fuzz-vt: PASS seeds=120 iterations=24000`; 8.0 s wall here (the supplied 8.4 s is timing variance). The script takes its own `mktemp` work dir per invocation, so concurrent runs are safe. |
| Cross targets | `sh scripts/check-targets.sh` | Exit 0: **10 combinations** (x86_64-freebsd and aarch64-linux-gnu × fdm/spawn/slave/main/server), **0 SKIP**. Compile-only (`zig build-obj -fno-emit-bin`). |
| ABI freshness | `python3 scripts/gen_abi_probe.py --check` | Clean. `abi_probe.c` 3,838 lines; 11 `*-shim.c` files 2,552 lines; tracked Zig 55,293 lines (all by `wc -l`). |
| ABI coverage | `rg -n 'expectAbi\(' terminal_types.zig`; `rg -n 'EpollEvent' build/c_layout.zig` | Eight config element mirrors have direct `expectAbi`; fixed arrays recurse (`Config.fonts[4]`, `Terminal.notification_icons[32]`, `KeySet.vmods[8]`, `WlWindow.csd.surface[]`, `Vt.params.v[16]`); native probe: Linux `epoll_event` 12 bytes / `data` at 4; FreeBSD 16/8 is cross-derived. Accepted gaps: pointer-reached element types rely on direct `expectAbi`; tll node is probed only via the seat instantiation. |
| Version | `scripts/check-version.sh`; `sh generate-version.sh 1.28.0 . <tmp>` | `check-version: ok`, `FOOT_VERSION` **1.28.0-345-gab5f4261**, macros **1/28/0**. Plain `git describe --always --tags` prints `zig-migration-1.1-29-gab5f4261`; the version macro uses the semver-only describe. |
| Clean clone | `sh scripts/check-clean-clone.sh` | `check-clean-clone: ok`, `Ok: 9 Fail: 0`; a clone with `.git` builds at `ab5f4261` (the 1.1 defect is fixed). |
| Real launch | `scripts/smoke.sh` | Six window launches (80x24, 132x43, 20x5, maximized, fullscreen, OSD+scrollback), `smoke: ok`. Source inspection (`rg -n FOOT_ALLOW_NO_COMPOSITOR scripts/smoke.sh`) confirms it fails when no window can be launched unless that variable is explicitly 1. |

## What the gate actually enforces

Verified by source inspection on `ab5f4261` (`rg -n 'EXPECTED_SUITES|listed|rm -f|render-parity.sh' scripts/full-check.sh`):
`EXPECTED_SUITES=9`; the registered suite count and the Meson summary count
must both equal 9; `Fail: 0` and no skips are required; stale logs are deleted
before each run; parity is invoked and a failure propagates. `scripts/smoke.sh`
requires a real window launch unless `FOOT_ALLOW_NO_COMPOSITOR=1` is set
explicitly.

## Known limitations (1.2 final)

- Render parity cannot cover sixel escape decoding, real image cache rescaling
  or shm/compositor presentation: the corpus feeds two prebuilt pixman images
  into the real `render_sixel_images()`/`sixel_sync_cache()` path; no VT
  parser, shm pool or compositor is involved (source inspection of
  `tests/test-render-parity.c`).
- The corpus does not cover per-codepoint fallback or every cursor enum
  (source inspection: three cursor styles, grapheme shaping enabled).
- Valgrind still shows fontconfig residue in non-main logs (measured above).
- FreeBSD/aarch64 remain compile-only claims (measured by
  `scripts/check-targets.sh`); no FreeBSD headers or aarch64 C probe run here.
- ASan is broken in this container — historical observation recorded below;
  **unverified on ab5f4261** (not re-run in this pass).

## Historical (not 1.2 evidence)

- 1.0 snapshot: 6 meson suites, 988 harness checks, 2,554 shim lines, 3,472
  probe lines, 54,961 Zig lines; 6/6 in three dirs; parity 447 cells across two
  scales (`MIGRATION_PLAN.md` §15.7).
- 1.1 snapshot: 8 suites, 1,001 `ok:` lines, 2,540 shim lines, 3,478 probe
  lines, 55,184 Zig lines; parity 447 cells; the tag did not build from a clean
  clone (`MIGRATION_PLAN.md` §15.9).
- Pre-final 1.2 integration snapshot: leak gate exited 99 with fixture records
  and parity was 447 cells (`MIGRATION_PLAN.md` §15.5). Both are fixed in the
  matrix above.
- ASAN (historical, not re-run here): clang ASAN could not complete the terminal
  harness in this container (allocator `munmap` failure); GCC ASAN is not
  reachable via Meson. `test-config` was clean under ASAN after a missing
  `config_free()` was added. Do not present any of this as a 1.2 measurement.
