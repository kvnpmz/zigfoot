# foot C → Zig migration: release 1.2

Status: **1.2 final**, measured on `ab5f4261` (2026-11-26). This document
reports measured numbers only; older release numbers are labelled historical
in `MIGRATION_PLAN.md` §§15.5–15.9. The per-command matrix is
`doc/endgame-verification.md`.

## What 1.2 is

1.2 is the release in which the migration's gate, ABI checks and documented
divergences were made reproducible from a clean checkout. It is cut from
`00cdb2c0` and finalized at `ab5f4261`; the `zig-migration-1.1` tag is left
untouched as an audit snapshot, but its generated `FOOT_MAJOR/MINOR/PATCH`
were not numeric and a clean clone of it did not compile. In 1.2,
`generate-version.sh` restricts `git describe` to semver tags,
`scripts/check-version.sh` prints `check-version: ok` for
`FOOT_VERSION` **1.28.0-345-gab5f4261** with macros **1/28/0**, and
`scripts/check-clean-clone.sh` reports `Ok: 9 Fail: 0`.

## What changed since 1.1

Measured from the commit history (`git log --oneline --all --grep=...`) and
the source/probe commands cited with each result in `MIGRATION_PLAN.md` §15.10:

- **Build and gate.** Semver-only version parsing; `full-check.sh` deletes
  stale logs, fails on a build error, requires both the registered suite list
  and the summary count to equal `EXPECTED_SUITES=9`, with `Fail: 0` and no
  skips, invokes render parity and propagates its failure. `smoke.sh` no
  longer passes with zero window launches unless `FOOT_ALLOW_NO_COMPOSITOR=1`.
  Commits: `8428e287`, `0ab3728b`, `907d484e`, `4caf6851`.
- **ABI probes.** Eight config element mirrors got direct `expectAbi` calls;
  fixed-size arrays of mirrors recurse; Linux `epoll_event` is probed natively;
  the tll seat node/head are probed. `python3 scripts/gen_abi_probe.py --check`
  is clean. Commits: `f9a50dce`, `12fd8025`, `151064b3`.
- **execvpe edge cases.** Empty file → `ENOENT`, empty PATH → cwd,
  `ESTALE`/`ENODEV`/`ETIMEDOUT` continue the search; the envp-PATH vs
  `getenv`/`environ` divergence is documented in `doc/execvpe.md`. Eleven
  cases pass. Commit: `0e9505df`.
- **Restored error logging.** Dropped `LOG_ERRNO` sites in
  `selection.fdmReceive` and the terminal flash/blink/cursor-blink timers are
  back (`rg -n 'logErrno|log_errno' terminal.zig`). Commit: `0e9505df`.
- **Shim tests.** `tests/test-shims.c` drives the real memfd/seal/punch-hole
  and URL-regex paths: 39 checks, all pass. Commits: `feec9225`, `97d3d2aa`.
- **url-shim over-read fix.** `url_shim_regex_match()` no longer reads
  `matches[1]` when the pattern has no capture group. Commits: `e4fc52e9`,
  `ee778d41`, `bb5bcfb9`.
- **Leak-free harness.** `valgrind -q --error-exitcode=99 --leak-check=full
  ./build/tests/test-terminal` now exits 0 (main process 0 definite/indirect
  loss). Commit: `c0445a3e`.
- **Widened parity corpus.** 1,058 cells across three scales, adding cursor
  styles, integer HiDPI 2.0, wide/spacer and shaped clusters, CSD bottom/right
  and a sixel pass against `ORACLE_REF=6b3f557d`. Commit: `cdfabe9f`.

## Verification matrix summary

All rows measured on `ab5f4261`; full commands and caveats are in
`doc/endgame-verification.md`.

| Check | Result |
|---|---|
| `sh scripts/full-check.sh` | exit 0; 9/9 in `build`, `build-disabled`, `build-release`; parity PASS; six smoke launches |
| Harness `ok:` lines | 1,040 = 990 terminal-harness + 39 shims + 11 regex; 875 `check()` sites in `test-terminal.c` |
| Render parity | PASS; 1,058 cells / 3 scales; totals `e5184e0fe5898153`, `b7cebabc45627f13`, `87c0bab0d0d6829b` |
| Leak gate | full-leak-check valgrind on `test-terminal` exits 0; 8 residual 320 B records (2,048 direct + 512 indirect) in non-main logs only |
| Fuzz | `bash scripts/fuzz-vt.sh 120` → PASS, seeds=120, iterations=24,000 |
| Cross targets | `sh scripts/check-targets.sh` → 10 combinations, 0 SKIP (compile-only) |
| ABI check | `python3 scripts/gen_abi_probe.py --check` clean; 3,838 probe lines, 2,552 shim lines, 55,293 Zig lines |
| Version / clean clone | `check-version: ok` (1/28/0, 1.28.0-345-gab5f4261); `check-clean-clone: ok` (9/9) |

## What the C claims actually mean

The following statement is TRUE on `ab5f4261` (measured by `wc -l` over the
tracked sources and generated build outputs):

> 0 module-C lines; the foot/footclient binaries contain no hand-written C except the 11 class-(a) *-shim.c files (2,552 lines); a default build also compiles generated C (6,117 lines: srgb.c 518 + abi_probe.c 3,838 + 17 protocol stubs 1,761) and test/tool C that is not linked into the binaries; 1,218 lines (PGO 441 + fuzz 777) build only on demand.

Measured break-out: the unlinked test C is 11,805 lines
(`test-terminal.c` 8,473, `test-config.c` 2,091, `test-config-stubs.c` 28,
`test-execvpe.c` 279, `test-regex.c` 109, `test-render-parity.c` 575,
`test-shims.c` 250), plus `utils/xtgettcap.c` 199; unique C compiled by a
default build is therefore 20,673 lines. "100% Zig" is true of module logic,
not of every C line in a build.

## Known limitations

- Render parity cannot cover sixel escape decoding, real image cache rescaling or shm/compositor presentation.
- The corpus does not cover per-codepoint fallback or every cursor enum.
- Valgrind still shows fontconfig residue in non-main logs.
- FreeBSD/aarch64 remain compile-only claims.
- ASan is broken in this container.

Detail: the sixel pass uses prebuilt pixman images through
`render_sixel_images()`/`sixel_sync_cache()`, not the VT parser or shm;
the corpus uses three cursor styles with grapheme shaping enabled; the fontconfig
residue is 8 × 320 B in non-main logs (2,560 B total, 2,048 direct + 512
indirect) with no foot frame; the cross gate compiles without linking; and the
ASan observation is historical and was **not re-run** on `ab5f4261`.
