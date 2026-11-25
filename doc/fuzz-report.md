# VT fuzz harness report

Date: 2026-11-25 (UTC)

## Scope and method

`tests/fuzz-vt.c` is a standalone harness with its own `main()`. It exercises
the migrated VT core through `vt_from_slave()` (the current name of the VT
entry point referred to as `vt_parse()` in the task), plus reachable keyboard,
IME, and key-binding helpers.

The terminal fixture follows `tests/test-terminal.c:term_new()`: zeroed
`struct terminal`, 5×5 screen, 16-row grids, synthetic rows, and selection
sentinels. It adds an initialized alternate grid, an empty Wayland/seat model,
a dummy window, real render timer descriptors, and a real pty. The pty master
and slave are nonblocking, and slave output is drained after each iteration.
The headless title/app-id and unused selection-source destructors are no-op
linker wrappers; they are UI boundaries, not VT behavior.

Each process uses a deterministic xorshift64* PRNG. It joins and mutates a
corpus covering CSI/SGR, scroll regions, alternate screen, DECAWM, wide and
combining text, invalid UTF-8, OSC 8/52/title, DCS, terminated and unterminated
sixel, kitty keyboard flags, huge parameters, unterminated CSI/OSC, and a
trailing ESC. Input is fed in random chunks of at most 512 bytes.

Every 11 iterations the harness calls keymap lookup, legacy/kitty keyboard
encoders, modifier formatting, and pending IME callbacks. Every 7 iterations
it unloads/reloads and looks up the key-binding set. Every 17 iterations it
calls `term_view_to_text()` and frees the result. SIGSEGV, SIGABRT, SIGBUS,
SIGILL, and SIGFPE write the exact raw input to the failure artifact and the
seed/iteration header to stderr.

## Build and run

No build target was invoked. `ninja -C build -t commands` was used read-only to
copy compile definitions/includes and link libraries. The script snapshots
`libfootlib.a`, the other static libraries, and generated headers under
`/tmp/fuzz-vt/`. Thin archives are normalized to regular archives so linking
cannot read a concurrently rebuilt `build/` member.

Exact commands:

```sh
cd /workspace
ninja -C build -t commands foot | tail -1
bash /tmp/once.sh 'scripts/fuzz-vt.sh'
bash /tmp/once.sh 'valgrind --error-exitcode=99 --leak-check=no /tmp/fuzz-vt/fuzz-vt 1 200 > /tmp/fuzz-vt/valgrind.stdout 2> /tmp/fuzz-vt/valgrind.stderr'
```

The exact expanded compile/link command is saved in
`/tmp/fuzz-vt/build-command.txt`. Snapshot hashes are in
`/tmp/fuzz-vt/snapshot.sha256`; the final `libfootlib.a` SHA-256 was
`e7ab31ccf7ca63153935ba5bd87beb5f3dea3d6940ebbe20928ba8b86105edea`.

## Result

- Final driver run: **40 seeds**, seeds 1 through 40, 200 iterations each.
- Total final iterations: **8,000**.
- Crashes, Zig panics, asserts, and timeouts: **0**.
- Driver summary: `fuzz-vt: PASS seeds=40 iterations=8000`.
- Additional Valgrind run: seed 1, 200 iterations, **0 errors from 0
  contexts**. Leak checking was not enabled.

No product failure remains from this run. This is a bounded headless fuzz
run, not proof of absence of bugs. A live compositor, font/render pipeline,
and nonempty configured binding lists are outside this harness.

## Development-only fixture failures

These were found while qualifying the new harness. They were null-pointer
failures caused by omitted headless fixture state, not defects in a shared
source file. The fixture was corrected; no product source was patched.

| Seed | Minimized input (escaped) | Triage |
| --- | --- | --- |
| 1 | `\x1b]52;c;SGVsbG8=\x07` | OSC 52 reached `osc_seat_with_focus()` with `term->wl == NULL`. Added the empty Wayland model. |
| 2 | `\x1b]0;x\x07` | OSC 0 reached title rendering with `term->window == NULL`. Added a dummy window, real timerfds, and no-op UI wrappers. |

## How to reproduce

Build and run all default seeds:

```sh
cd /workspace
bash /tmp/once.sh 'scripts/fuzz-vt.sh 40'
```

Run one seed directly:

```sh
FUZZ_VT_FAIL=/tmp/fuzz-vt/repro timeout 30 /tmp/fuzz-vt/fuzz-vt 7 200
```

Replay a saved raw failure artifact (the optional fourth argument forces one
iteration):

```sh
FUZZ_VT_FAIL=/tmp/fuzz-vt/replay-fail timeout 30 \
    /tmp/fuzz-vt/fuzz-vt 7 1 /tmp/fuzz-vt/fail-7
```

Inspect a panic under gdb:

```sh
gdb -batch -ex run -ex bt --args \
    /tmp/fuzz-vt/fuzz-vt 7 1 /tmp/fuzz-vt/fail-7
```

The driver stops at the first failed seed, prints the stderr tail, saves
`/tmp/fuzz-vt/fail-<seed>`, and exits 1. A passing run prints one summary line.

## Agent B extended campaign — 2026-11-25

Command:

```sh
cd /workspace-b
export ZIG_GLOBAL_CACHE_DIR=/tmp/agent-b/zig-cache
bash scripts/fuzz-vt.sh 120
```

Result: **PASS**, 120 seeds, 24,000 iterations, no product crashes or panics.

The first attempt stopped at seed 71 because the harness evaluated
`current_input[next_random() % current_len]` after mutation produced an empty
input. This was a divide-by-zero in the fuzz driver, not in foot. The empty-input IME path now
leaves the text buffer empty. The repeated campaign passed all 120 seeds.
