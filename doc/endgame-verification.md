# Endgame verification

Base: `9f4f1def` (Agent A's merge, includes the D6 server port).
Toolchain: `/opt/zig/zig` 0.16.0, GCC 14.2.1, Clang 21.1.8.
Date: 2026-11-25.

> **Refreshed after integration @ `98f999c6`.** Shims are 2,554 lines in 11
> files, and the only remaining class-(c) body is the exit-time
> `log_presentation_statistics()` destructor (MIGRATION_PLAN §15.3). The
> 99-line argument below is unchanged and still the reason those lines stay.

## Remaining C

**None that a human wrote.** `config.c` and `slave.c` were the last two files
(99 lines between them); both are Zig as of `zig-migration-1.1` — `regex_t`
lives behind the ABI probe in `config.zig`, and `execvpe`'s glibc semantics
are written down and tested in `slave.zig`. The sections below keep the
original arguments for the record. What a build still compiles as C is
generated: wayland-scanner protocol stubs and `abi_probe.c`.

### `slave.c` — 64 lines, `slave_execvpe()`

- Zig 0.16 has no `execvpeZ` or `execvpe`. `rg -n 'execvpe|execvp' /opt/zig/lib/std --glob '*.zig'` finds only comments in `std/Io/Threaded.zig`, `std/Io/Uring.zig` and `std/Io/Dispatch.zig`; there is no declaration. `std.posix` exposes no exec wrapper, and `std.c` exposes only `execve` (`/opt/zig/lib/std/c.zig:10705`).
- `slave.zig:148` declares `extern fn slave_execvpe(file, argv, envp)`; `slave.zig:430` calls it after building the NULL-terminated `argv`/`envp` arrays and rewriting `argv[0]` for a login shell.
- On glibc (`EXECVPE` defined) the helper calls `execvpe(file, argv, envp)`. The PATH search must use the caller's `envp`, not `getenv("PATH")`. The portable `#else` branch uses `getenv("PATH")`, `confstr(_CS_PATH)`, `strtok`, `access(F_OK)` and one `execve`; it does not implement the glibc retry semantics.
- A Zig PATH walk would have to reproduce: PATH taken from `envp`; one `execve` attempt per `:`-separated candidate; continue on `EACCES` and remember the last error; on `ENOEXEC` retry the file through `/bin/sh`; preserve the NULL-terminated `argv` layout, `argv[0]` and `envp` unchanged; return `-1` with the same errno.
- Rule from SKILLS: keep a C helper when Zig lacks the API. That is why these 64 lines stay.

### `config.c` — 35 lines, `config_regex_compile()`

- `regex_t` is libc-private. glibc and musl disagree on its layout, so Zig keeps `Config.url.preg` opaque and pins only its size through `abi.Config_url_preg__size`. `config.zig` calls `regcomp()`/`regfree()` directly where only the opaque object is needed.
- The one operation that reads libc-private state stays C: `regcomp(preg, regex, REG_EXTENDED)`; on failure, `regerror()` into `err_buf` and return `-1`; if `preg->re_nsub == 0`, `regfree()` and return `-2`; otherwise return `0`.
- `config.zig:841-858` and `config.zig:3761-3768` map those three return values. No second regex implementation is needed.

### Definition of Done

"No module-specific C left" now means: no C source file for any module, with exactly two named exceptions — `slave.c` (`execvpe()`, 64 lines) and `config.c` (`regex_t` wrapper, 35 lines). Total: 99 lines. Both exceptions are libc-API boundaries, not migration debt.

## Verification

Commands run from `/workspace-c` with `ZIG_GLOBAL_CACHE_DIR=/tmp/agent-c/zig-cache`.

### Full matrix

Command: `scripts/full-check.sh`. It builds `build` (debug), `build-disabled` (grapheme clustering off) and `build-release` (ReleaseSafe), runs `meson test --no-rebuild` in each, then runs `scripts/smoke.sh`.

```
build            Ok: 5  Fail: 0
build-disabled   Ok: 5  Fail: 0
build-release    Ok: 5  Fail: 0
--- smoke ---
smoke: ./build/foot --version
smoke: ./build/foot -C -c <temp config>
warn: main.zig:206: 'C' is not a UTF-8 locale, falling back to 'C.UTF-8'
smoke: launching at 80x24
smoke: launching at 132x43
smoke: launching at 20x5
smoke: launching at 80x24
smoke: launching at 80x24
smoke: launching at 80x24
smoke: ok
```

Result: 5/5 in all three directories; 6/6 window launches. The locale warning is pre-existing and harmless. Full script exit status: 0.

### Valgrind

Command: `valgrind -q --error-exitcode=99 ./build/tests/test-terminal`.

Result: exit 0; last line `terminal harness: all checks passed`. No valgrind errors. The log still carries the pre-existing Zig DWARF line-info warnings from earlier builds; they do not affect the exit status.

### ASAN

Setup: `CC=clang meson setup build-asan --buildtype=debug -Db_sanitize=address`. Meson warned that Clang ASAN with `b_lundef` may not link; that warning was not reached.

`ninja -C build-asan` exits 1. `meson test -C build-asan` exits 125 with "Could not rebuild /workspace-c/build-asan". Exact failing command:

```
clang -Itests/test-terminal.p -Itests -I../tests -I. -I.. -I/usr/include/pixman-1 -I/usr/include/freetype2 -I/usr/include/libpng16 -I/usr/include/harfbuzz -I/usr/include/glib-2.0 -I/usr/lib64/glib-2.0/include -fdiagnostics-color=always -fsanitize=address -fno-omit-frame-pointer -D_FILE_OFFSET_BITS=64 -Wall -Winvalid-pch -Werror -std=c11 -O0 -g -Wno-c2y-extensions -DMEMFD_CREATE -DEXECVPE -DSIGABBREV_NP -D_GNU_SOURCE=200809L '-DFOOT_DEFAULT_TERM="foot"' '-DUTMP_ADD="add"' '-DUTMP_DEL="del"' '-DUTMP_DEFAULT_HELPER_PATH="/usr/lib/utempter/utempter"' -D_DEBUG -DFOOT_IME_ENABLED=1 -pedantic -fstrict-aliasing -Wstrict-aliasing -fmacro-prefix-map=../= -DFOOT_GRAPHEME_CLUSTERING=1 -DHAVE_PIXMAN_RGBA_16 -DHAVE_XDG_TOPLEVEL_TAG=1 -DHAVE_EXT_BACKGROUND_EFFECT=1 -DUTF8PROC_EXPORTS -pthread -MD -MQ tests/test-terminal.p/test-terminal.c.o -MF tests/test-terminal.p/test-terminal.c.o.d -o tests/test-terminal.p/test-terminal.c.o -c ../tests/test-terminal.c
```

Diagnostic: `tests/test-terminal.c:5854:45: error: shifting a negative signed value is undefined [-Werror,-Wshift-negative-value]` for `wl_pointer_axis(&seat, NULL, 0, 0, -120 << 8);`. The prompt expected line 5505; merges moved it to 5854. `git blame` attributes the line to `79bd8dc3` (D4d2b pointer-listener harness), not to upstream foot and not to E3 work.

**Resolved after this run.** The owner (A) fixed the line to `(-120) * 256`
(same value, defined behaviour), and the ASAN build now completes. Two
further results:

- `test-config` under ASAN: **clean** (exit 0, no sanitizer output) — but only
  after a real leak it exposed was fixed. LeakSanitizer (and valgrind,
  which reproduced it reliably: 8,411 B direct + 60,912 B indirect,
  `re_compile_internal` via `config_regex_compile()`) showed that the new
  `test_config_load_from_xdg` never freed the partially loaded config after
  its expected fatal-load failure, so the URL regex and the default
  key/search/url/mouse bindings leaked. Added the missing `config_free()`.
  `valgrind --leak-check=full ./build/tests/test-config` is now 0 bytes lost,
  0 errors.
- `test-terminal` under ASAN: still cannot complete in this container. After
  ~600 checks ASAN's own allocator aborts (`AddressSanitizer failed to
  deallocate 0x40000 bytes ... error code 22` / `Failed to munmap`), with
  and without `quarantine_size_mb=0`. A trivial clang-ASAN binary runs fine
  and `test-config` passes, so this is the mixed C-ASAN/uninstrumented-Zig
  build in this environment, not a product finding. GCC ASAN is not
  reachable: meson refuses `-Db_sanitize=address` with gcc here ("Linker gcc
  does not support sanitizer arguments"). The gate's valgrind run covers
  the harness instead.

### ReleaseSafe vs ReleaseFast

Measurement: three wall-clock runs of the ReleaseSafe harness in `build-release`:

```
release_harness_wall=4.376 s
release_harness_wall=4.259 s
release_harness_wall=4.251 s
```

Mean 4.30 s. `build-release` maps to Zig `ReleaseSafe` in `compile_zig.py`; Meson has no `ReleaseFast` buildtype, and editing build files is outside this task, so no ReleaseFast binary was measured.

Recommendation: keep `ReleaseSafe` as the default. The measured harness is 4.3 s with integer-overflow, bounds and pointer-safety checks active; those checks are the reason several port bugs were caught during D2-D6. `ReleaseFast` removes them without a measured gain, so the trade is one-way risk. If a real hot path is later identified, build one target with `ReleaseFast`, benchmark that path against `ReleaseSafe`, and only then consider a per-module exception.

### execvpe coverage

All six smoke launches run `foot -e sh -c 'printf "smoke\n"; exit 0'` at 80x24, 132x43, 20x5, 80x24 maximized, 80x24 fullscreen, and 80x24 with `render-timer=osd` + `scrollback-indicator=percentage`. Each launch spawns the shell through `slave.zig` and `slave_execvpe()`, using the caller's envp. The harness also drives the failure path: `tests/test-terminal.c:6969` checks `slave_execvpe("/foot-fuzz-missing", argv, envp) == -1` with `errno == ENOENT`. Result: launch coverage intact, failure-path check green.
