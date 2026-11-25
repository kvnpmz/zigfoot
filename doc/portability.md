# Portability and ABI notes

Scope: PL-03, PL-04 and the portability half of PL-08. Linux behaviour must
stay byte-identical; FreeBSD must compile with the libc and epoll-shim the
C build uses.

## Rules used

- Constants come from `std.posix` (or `std.os.linux` inside a Linux-only
  branch). No hard-coded Linux signal, open, fcntl, socket or permission
  numbers remain in the owned plumbing files.
- Signal masks and `sigaction` use `std.c.sigset_t` and `std.c.Sigaction`.
  That avoids a private mirror of an ABI whose layout differs between
  glibc, musl and FreeBSD.
- Only private C macros that Zig does not expose (`TIOCSCTTY`, `_CS_PATH`,
  `struct utsname`) go through a narrow `@cImport`. Do not pull in
  `fcntl.h`: glibc's `open()` macro checks make the import fail.
- `errno` goes through `std.c._errno()`, which resolves to the target's libc
  accessor.

## Private ABI kept local

- `fdm.zig`: Linux `epoll_event` is packed (`events` and `data` both
  `align(1)`, 12 bytes, `data` at 4) on every Linux architecture. FreeBSD
  uses the epoll-shim ABI (natural alignment, 16 bytes, `data` at 8). Both
  shapes have comptime size/offset checks.
- `terminal_types.zig`: `sockaddr_un.sun_path` is 108 bytes on Linux and
  104 bytes on FreeBSD. The native C probe checks the selected layout;
  the cross check compiles it but does not link C.
- `server.zig`: FreeBSD has no `SOCK_CLOEXEC`/`SOCK_NONBLOCK` open flags;
  the socket is created plain and the flags are applied with `fcntl()`.

## Gate

  debug build:     ninja -C build -j4 && meson test -C build --print-errorlogs
  release build:   ninja -C build-release -j4 && meson test -C build-release --print-errorlogs
  ABI probe:       python3 scripts/gen_abi_probe.py --check
  cross targets:   scripts/check-targets.sh

`check-targets.sh` compiles `fdm.zig`, `spawn.zig`, `slave.zig`, `main.zig`
and `server.zig` for `x86_64-freebsd` and `aarch64-linux-gnu`. On the
pre-fix tree it exits 1 at `fdm.zig`'s Linux-only compile error. It needs a
native `c_layout.zig` for the main/slave/server imports; standard build
directories are found automatically.

## Not fixed here

`client.zig`, `config.zig` and `terminal.zig` still hold private `Stat`,
`Passwd` and `sigaction` mirrors. Those files are outside this worktree's
ownership. They are Linux-only mirrors and do not block the two cross
targets used by the gate.

## What is verified, and how

| Claim | Status | Evidence / limit |
|---|---|---|
| FreeBSD cross-compile: 5 files x 1 target | verified | `scripts/check-targets.sh` compiles fdm.zig, spawn.zig, slave.zig, main.zig and server.zig for x86_64-freebsd with zig build-obj; same 5 files also compile for aarch64-linux-gnu. |
| aarch64 epoll_event: Zig mirror size 12, events offset 0, data offset 4 | verified | comptime assertions at `fdm.zig:14-21` run during the aarch64 cross compile; a mismatch fails the gate. |
| aarch64 epoll_event: C ABI match | inferred | The 12/4 layout comes from the packed C struct and the audit, not from an aarch64 C probe run on this host. |
| Runtime ABI probe | verified | `abi_probe.c` is compiled and executed by meson on Linux only. No FreeBSD headers exist in the cross gate, so no FreeBSD probe runs. |
| FreeBSD EpollEvent layout | inferred | `fdm.zig:9` and `fdm.zig:22-26` pin 16 bytes and data offset 8 by comptime constants instead of a FreeBSD C probe. |
| FreeBSD epoll-shim constants | unverified | `server.zig:104` and `fdm.zig:30-49` use explicit Linux-compatible API values; no FreeBSD C header value is checked here. |
| Private layout mirrors in unowned files | unverified | `client.zig:82` Stat, `client.zig:100` sockaddr_un, `config.zig:4486` Passwd and `terminal.zig:4550` sigaction have no C_TYPES entry or expectAbi call on this branch. Native Linux tests exercise behaviour, not those layouts. |
