# VT fuzz harness report — 1.2 final

Measured on `ab5f4261` (2026-11-26). Earlier campaigns at the bottom are
historical and are not 1.2 evidence.

## Scope and method

`tests/fuzz-vt.c` is a standalone harness with its own `main()`. It drives
the migrated VT core through `vt_from_slave()` plus reachable keyboard, IME,
key-binding, clipboard, primary, DnD and IPC-framing paths. The fixture is a
zeroed `struct terminal`, 5×5 screen, 16-row grids, synthetic rows, an
alternate grid, an empty Wayland/seat model, a dummy window, real timerfds and
a nonblocking pty; headless UI boundaries are no-op linker wrappers. Each
process uses a deterministic xorshift64* PRNG and mutates a corpus of
CSI/SGR, scroll regions, alternate screen, DECAWM, wide and combining text,
invalid UTF-8, OSC 8/52/title, DCS, sixel, kitty keyboard flags, huge
parameters and unterminated controls. SIGSEGV/SIGABRT/SIGBUS/SIGILL/SIGFPE
write the exact raw input to a seed-specific failure artifact.

## 1.2 final run

Command (measured on `ab5f4261`):

    bash scripts/fuzz-vt.sh 120

Result: `fuzz-vt: PASS seeds=120 iterations=24000`, exit 0, wall **8.0 s**
(the supplied 8.4 s figure is timing variance). No product crash, Zig panic,
assert or timeout. Nowhere in this run was a build target invoked: the script
snapshots `libfootlib.a`, the other static archives and generated headers
from `build/` before compiling and running the driver.

**Per-invocation work dir.** Verified by source inspection
(`rg -n 'mktemp|trap' scripts/fuzz-vt.sh`): the script creates
`$(mktemp -d "${TMPDIR:-/tmp}/fuzz-vt.XXXXXX")` and removes it via an
`EXIT`/`HUP`/`INT`/`TERM` trap, so concurrent runs cannot reuse another
run's archives, objects or failure artifacts. This is the 1.2 replacement for
the older shared `/tmp/fuzz-vt/` snapshot path.

This is a bounded headless fuzz run, not proof of absence of bugs. A live
compositor, font/render pipeline and nonempty configured binding lists are
outside the harness.

## Historical campaigns (not 1.2 evidence)

- Initial 40-seed run (8,000 iterations), PASS; one valgrind run with
  `--leak-check=no`, 0 errors from 0 contexts.
- Agent B extended campaign: 120 seeds / 24,000 iterations, PASS after an
  empty-input divide-by-zero in the **driver** was fixed.
- Agent B merged-tree regression campaign at `9f4f1def`: the first run failed
  at seed 1 because `receiveChunk()` passed a zero-length URI chunk to
  `fdmReceiveDecoderUri()`; the fix landed in `selection.zig` on another
  branch. Driver fixes in that campaign removed stale thin-archive members
  and corrected the completion callback used for selection/DnD.

To replay a single seed from the current tree, run the driver built by the
script directly with `FUZZ_VT_FAIL=<artifact> <work>/fuzz-vt <seed> 200`;
the script's per-invocation `work` directory is deleted on exit, so copy any
artifact you want to keep before then.
