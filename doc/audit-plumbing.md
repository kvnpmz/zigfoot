# Audit 3 — process plumbing, entry points, config and utilities

> **Status (endgame, 2026-11-25, base `98f999c6`).** Body unchanged.
>
> | id | status |
> |---|---|
> | PL-01, PL-02 | fixed `674e62d2` |
> | PL-05, PL-06, PL-12 | fixed `75be865f` |
> | PL-07 | fixed `4a5f3382` (pushed with the S-03/S-08 batch) |
> | PL-03, PL-04 | open — Agent B, `port-abi` (the tag blocker) |
> | PL-08 | open — Agent B |
> | PL-09, PL-10, PL-11 | open — Agent B |

Base: `187548718ce4103c5ecb8c208749a8ea6dec6a1c` (`feature/zig-migration`).
C oracle: `origin/master`.
Audit date: 2026-11-25.
Scope: the files in the Audit 3 brief. This audit made no product edits.

## Result

The plumbing port is complete. Every non-trivial C function has a Zig owner or a documented C exception. The normal Linux x86-64 path passes the build, the five Meson tests, the config oracle under Valgrind, and a fake-socket IPC test.

The audit found 12 defects:

| Severity | Count |
|---|---:|
| High | 4 |
| Medium | 5 |
| Low | 3 |

The two most serious defects are a config-triggered double free and a URI port overflow that aborts the process. The port also breaks the advertised FreeBSD target and has a wrong `epoll_event` layout on Linux aarch64.

## Findings

| id | file:line | C ref | class | severity | evidence | fix |
|---|---|---|---|---|---|---|
| PL-01 | `uri.zig:126-129` | `origin/master:uri.c:117-124` | Arithmetic panic | High | C wraps the port in `uint16_t`. Zig checks the arithmetic in ReleaseSafe. `foot -C -D 'file://localhost:65536/tmp'` aborts with `integer overflow`. OSC 8 URLs reach the same parser. | Accumulate in `u32`. Reject values above `UINT16_MAX`, or use explicit wrapping arithmetic if exact C behavior is required. |
| PL-02 | `config.zig:1994-2002`, `config.zig:2087-2089` | `origin/master:config.c:2104-2108`, `origin/master:config.c:2410-2413` | Double free | High | `value_to_key_combos()` frees the first combo's `master_copy` aux on failure. Its caller then frees the same aux. A valid pipe combo followed by an invalid key segfaults. The C oracle has the same defect. | Give the aux one owner. Let `value_to_key_combos()` consume it on all paths, and remove the caller's second free. Add a failure-path harness check. |
| PL-03 | `fdm.zig:4-6`, `spawn.zig:3-5`, `main.zig:316-328`, `slave.zig:60-89` | `origin/master:fdm.c`, `origin/master:spawn.c`, `origin/master:main.c:188-205` | Portability | High | `fdm.zig` and `spawn.zig` fail compilation on FreeBSD. Other plumbing files hard-code Linux signal, ioctl, socket and stat layouts. Meson still selects a FreeBSD utmp backend. A cross compile of `fdm.zig` for `x86_64-freebsd` fails at the explicit compile error. | Use libc constants and platform-neutral Zig/libc types. Keep platform-only ABI details in small probed shims. Restore a FreeBSD build job. |
| PL-04 | `fdm.zig:12-15` | Linux `struct epoll_event` in `sys/epoll.h` | ABI layout | High | C packs `epoll_event`; `data` is at offset 4 and the size is 12 on aarch64. The Zig non-x86-64 branch gives `u64` natural alignment, so `data` moves to offset 8 and the size becomes 16. | Use `align(1)` for both fields on every Linux architecture. Add compile-time size and offset assertions. |
| PL-05 | `client.zig:310-316`, `client.zig:363-373` | `origin/master:client.c:668-678` | Leak | Medium | The heap copy of `foot_argv` is not freed. C uses a VLA. Valgrind reports 32 definitely lost bytes for a four-element argv after a successful fake-server exchange. | Add `free(foot_argv)` to the common cleanup block. |
| PL-06 | `xmalloc.zig:14-47` | `origin/master:xmalloc.c:15-43` | Contract drift | Medium | C turns zero sizes into one-byte allocations and aborts on zero arguments to `xreallocarray()`. Zig permits them. `xreallocarray(ptr, 0, 16)` calls `realloc(ptr, 0)`, frees `ptr`, and returns null. | Restore the C preconditions and zero-size normalization. Preserve the original pointer on failure. |
| PL-07 | `server.zig:753-758` | `origin/master:server.c:584-589` | Checked cast | Medium | C converts `strtol()` to `int` with truncation. Zig uses `@intCast`, which traps for a numeric socket path outside `c_int`. A value such as `2147483648` crashes instead of failing socket validation. | Truncate to `u32` and `@bitCast`, as `print_pid()` already does, or reject out-of-range values explicitly. |
| PL-08 | `terminal_types.zig:1000`, `terminal_types.zig:1141`, `terminal_types.zig:1834`, `terminal_types.zig:2045-2105`; `scripts/gen_abi_probe.py:45-118` | `config.h`, `user-notification.h`, `util.h` | ABI coverage | Medium | `PtOrPx`, `Timespec`, `TllStr`, `EnvVar*` and `UserNotification*` cross the C ABI in this layer but have no `C_TYPES` entry and no `expectAbi()` check. The probe check passes because it only checks types listed in `C_TYPES`. Local `Stat`, `Sigaction` and `Passwd` mirrors are also unprobed. | Add the named C types to `C_TYPES` and add `expectAbi()` checks. Probe or shim the platform-private types. |
| PL-09 | `fdm.zig:169-176` | `origin/master:fdm.c:89-100` | Error-path leak | Low | If the FDM allocation or signal-handler allocation fails, the epoll FD and/or `received_signals` allocation leaks. The C oracle has the same leak. | Free `received_signals` and close `epoll_fd` on both failure paths. Clear the global pointer. |
| PL-10 | `fdm.zig:417-422` | `origin/master:fdm.c:423-443`, `tllist.h:tll_foreach` | Use-after-free | Medium | Hook dispatch caches the next node. If hook A deletes hook B, dispatch calls the freed B node. Self-removal works. The C iterator has the same weakness. | Define deletion semantics. Re-read the successor from the live list after each callback, or defer all hook deletion until dispatch ends. |
| PL-11 | `main.zig:414-418` | `origin/master:main.c:173-177` | errno lifetime | Low | `print_pid()` calls `close()` before `log_errno()`. A failing `close()` can replace the `write()` errno. The child error path in `slave.zig:434-440` has the same ordering problem. | Capture errno immediately after the failing call. Pass it to `log_errno_provided()` and use it for `_exit()`. |
| PL-12 | `base64.zig:135-152` | `origin/master:base64.c:146-150` | Lost precondition | Low | C asserts `0 < size < 3`. Zig silently encodes size 0 as `====` and ignores bytes after the second for larger sizes. | Restore explicit assertions or return an error. Keep the valid-size output unchanged. |

## Top 10 and minimal repros

1. **PL-02, config double free.** Put this in a file and run `foot -C -c file`:

   ```ini
   [key-bindings]
   pipe-scrollback=[echo hi] Control+a NoSuchKey
   ```

   Result: exit 139 after the expected invalid-key diagnostic.

2. **PL-01, URI overflow.** Run:

   ```sh
   foot -C -D 'file://localhost:65536/tmp'
   ```

   Result: exit 134, `integer overflow` at `uri.zig:129`. A terminal can supply the same authority in an OSC 8 URL.

3. **PL-03, FreeBSD build break.** Run:

   ```sh
   zig build-obj fdm.zig -target x86_64-freebsd -fno-emit-bin
   ```

   Result: `fdm.zig uses Linux-specific constants`. `spawn.zig` has the same guard.

4. **PL-04, aarch64 epoll ABI.** Compile the C packed `epoll_event` shape for aarch64 and compare it with the Zig non-x86-64 branch. C gives `sizeof == 12` and `offsetof(data) == 4`; Zig gives 16 and 8.

5. **PL-05, client leak.** Start the fake UNIX-socket fixture described below, then run:

   ```sh
   valgrind --leak-check=full --errors-for-leak-kinds=definite,indirect \
     --error-exitcode=99 build/footclient -s /tmp/fake.sock /bin/true
   ```

   Result: 32 definitely lost bytes. Without Valgrind, the same exchange returns the fixture's exit code 42.

6. **PL-07, socket-path cast.** Set `main.server-socket-path=2147483648` and reach `server_init()` under a compositor, or call it from a small harness. Zig traps at `@intCast`; C truncates and then fails `prepare_socket()`.

7. **PL-06, zero-size allocator contract.** Link a small C caller to `xmalloc.zig` and call:

   ```c
   void *p = xreallocarray(malloc(16), 0, 16);
   ```

   Result: null, and the original allocation has been freed. C aborts with `EINVAL`.

8. **PL-08, unprobed ABI.** Run `scripts/gen_abi_probe.py --check`; it passes. Then search `C_TYPES` for `PtOrPx`, `Timespec`, `EnvVar`, and `UserNotification`; none is present.

9. **PL-10, hook deletion.** Register hooks A and B at one priority. Let A call `fdm_hook_del(B)`. `fdm_poll()` caches B before A runs and then calls the freed B node.

10. **PL-11, errno clobber.** Preload a `close()` wrapper that clears errno, and make a server write its PID to `/dev/full`. The write fails with `ENOSPC`, but the later log can report `Success` after `close()` clears errno.

## Completeness matrix

Status `OK` means a direct 1:1 port. `OK*` means a verified difference or a documented exception. `F:id` means the function is present but has a finding.

| Module | C functions | Zig functions | Status |
|---|---|---|---|
| `main.c` | `fdm_sigint`, `fdm_sigusr`, `print_usage`, `get_foot_exe`, `locale_is_utf8`, `term_shutdown_cb`, `print_pid`, `sanitize_signals`, `main` | Same names in camel case; `main` is exported | `OK`, except PL-03 and PL-11 |
| `client.c` | `sigint_handler`, `sigusr_handler`, `sendall`, `print_usage`, `get_footclient_exe`, `push_string`, `free_string_list`, `send_string_list`, `main` | Handlers, `client_shim_sendall`, usage/exe helpers, `StringList.push/sendAll/deinit`, `footclient_main` | `OK`, except PL-03 and PL-05 |
| `server.c` | `client_destroy`, `client_send_exit_code`, `instance_destroy`, `term_shutdown_handler`, `fdm_client`, `fdm_server`, `try_connect`, `prepare_socket`, `server_init`, `server_destroy`, both global theme switches | Same names in camel case; `parseAndInit` replaces the inlined parser body | `OK`, except PL-03 and PL-07 |
| `slave.c` | `find_file_in_path`, `foot_execvpe` | `slave_shim_execvpe` and its private fallback in `slave.c` | `OK*`, documented exception |
| `slave.c` | `is_valid_shell`, `emit_one_notification`, `emit_notifications_of_kind`, `emit_notifications`, `slave_exec`, `env_matches_var_name`, `add_to_env`, `del_from_env`, `slave_spawn` | Same names in camel case | `OK`, except PL-03 and PL-11 |
| `config.c` | `log_and_notify_va`, `log_and_notify`, `log_contextual`, `log_and_notify_errno_va`, `log_and_notify_errno`, `log_contextual_errno` | `logAndNotify*`, `logContextual*`, exported C entry points | `OK` |
| `config.c` | `get_shell`, `open_config`, `str_has_prefix` | `get_shell`, `openConfig`, `eq` | `OK`, except PL-03 and PL-08 |
| `config.c` | `value_to_bool`, `str_to_ulong`, `str_to_uint32`, `str_to_uint16`, `value_to_uint16`, `value_to_uint32`, `value_to_dimensions`, `value_to_float`, `value_to_str`, `value_to_wchars`, `value_to_enum`, `value_to_color`, `value_to_two_colors`, `value_to_pt_or_px` | Same names; private `strToUint32/16` helpers | `OK`, except PL-08 |
| `config.c` | `value_to_fonts`, `free_argv`, `clone_argv`, `spawn_template_free`, `spawn_template_clone`, `value_to_spawn_template` | Same names | `OK` |
| `config.c` | `parse_section_main`, `parse_section_security`, `parse_section_bell`, `parse_section_desktop_notifications`, `parse_section_scrollback`, `parse_section_url`, `parse_section_regex`, `parse_color_theme`, `parse_section_colors_dark`, `parse_section_colors_light`, `parse_section_cursor`, `parse_section_mouse`, `parse_section_csd`, `parse_section_touch`, `parse_section_environment`, `parse_section_tweak` | Same names | `OK`; regex compile uses the 35-line C exception |
| `config.c` | `free_binding_aux`, `free_key_binding`, `free_key_binding_list`, `parse_modifiers`, `argv_compare`, `binding_aux_equal`, `remove_from_key_bindings_list`, `mouse_button_name_to_code`, `mouse_button_code_to_name` | Same names | `OK` |
| `config.c` | `value_to_key_combos`, `modifiers_equal`, `modifiers_disjoint`, `modifiers_to_str`, `pipe_argv_from_value`, `regex_name_from_value`, `parse_key_binding_section`, `parse_section_key_bindings`, `parse_section_search_bindings`, `parse_section_url_bindings`, `parse_section_mouse_bindings`, `parse_section_text_bindings`, `resolve_key_binding_collisions` | Same names; `parseKeyBindingSection` and `resolveKeyBindingCollisions` are shared helpers | `F:PL-02` |
| `config.c` | `parse_key_value`, `str_to_section`, `parse_config_file`, `get_server_socket_path`, `m`, `add_default_key_bindings`, `add_default_search_bindings`, `add_default_url_bindings`, `add_default_mouse_bindings` | Same names; `m` becomes `DefaultBinding` data | `OK` |
| `config.c` | `config_font_list_clone`, `config_load`, `config_override_apply`, `key_binding_list_clone`, `config_clone`, `config_free`, `config_font_parse`, `config_font_list_destroy`, `check_if_font_is_monospaced` | Same names | `OK` |
| `log.c` | `log_init`, `log_deinit`, `_log`, `_sys_log`, `log_msg_va`, `log_msg`, `log_errno_va`, `log_errno`, `log_errno_provided_va`, `log_errno_provided`, `map_len`, `log_level_from_string`, `log_level_string_hint` | Same names; `_log` and `_sys_log` become `log` and `sysLog` | `OK` |
| `debug.c` | `print_stack_trace`, `fatal_error`, `bug` | `debug_shim_print_stack_trace`, `fatal_error`, `bug` | `OK*`, ASAN selection uses a build option |
| `fdm.c` | `sigabbrev_np`, `fdm_init`, `fdm_destroy`, `fdm_add`, `fdm_del_internal`, `fdm_del`, `fdm_del_no_close`, `event_modify`, `fdm_event_add`, `fdm_event_del`, `hook_priority_to_list`, `fdm_hook_add`, `fdm_hook_del`, `signal_handler`, `fdm_signal_add`, `fdm_signal_del`, `fdm_poll` | Same names in camel case; libc provides `sigabbrev_np` | `F:PL-03`, `F:PL-04`, `F:PL-09`, `F:PL-10` |
| `reaper.c` | `reaper_init`, `reaper_destroy`, `reaper_add`, `reaper_del`, `fdm_reap` | Same names | `OK` |
| `spawn.c` | `spawn`, `spawn_expand_template` | `spawn.zig:spawn`, `spawn_template.zig:spawn_expand_template` | `OK`, except PL-03 |
| `async.c` | `async_write` | `async_write` | `OK*`, EAGAIN values are Linux constants |
| `base64.c` | `base64_decode`, `base64_encode`, `base64_encode_final` | Same names | `OK*`, except PL-12; NULL guard on decode is verified |
| `commands.c` | `cmd_scrollback_up`, `cmd_scrollback_down` | Same names | `OK` |
| `misc.c` | `isword`, `timespec_add`, `timespec_sub`, `is_valid_utf8_and_printable` | Same names | `OK`, except PL-08 for `Timespec` |
| `uri.c` | `uri_parse`, `hostname_is_localhost` | Same names | `F:PL-01` |
| `xmalloc.c` | `check_alloc`, `xmalloc`, `xcalloc`, `xrealloc`, `xreallocarray`, `xstrdup`, `xstrndup`, `xc32dup`, `xvasprintf_`, `xvasprintf`, `xasprintf` | Checks are folded into each function; `xvasprintf` calls libc; `xasprintf` stays in the varargs shim | `F:PL-06` |
| `xsnprintf.c` | `xvsnprintf`, `xsnprintf` | `xvsnprintf`; `xsnprintf` stays in the varargs shim | `OK*` |
| `foot-features.c` | `version_and_features` object | Same exported array plus `foot_version_and_features()` | `OK` |
| `tllist.h` | `tll_init`, length/empty, front/back, push/insert, remove, pop, free, foreach/rforeach, sort | `tll.Tll(T)` methods | `OK`; the unused generic `Iterator.remove()` remains an unreachable stub |

## Entry points and process semantics

### `main`

The getopt string is exact:

```text
+c:Co:t:T:a:LD:f:w:W:s::HmFPp:d:l::Sveh
```

The long-option table has the same order, `val`, and `has_arg`. This includes the `class` alias for `a`, the undocumented `presentation-timings` option, `PTY_OPTION = CHAR_MAX + 1`, and `TOPLEVEL_TAG_OPTION = CHAR_MAX + 2`.

The override strings match C for `-o`, `-t`, `-L`, `-T`, `-a`, `--toplevel-tag`, `-f`, `-w`, `-W`, `-m`, and `-F`.

Other checks:

- Foot failure is `-26`. Client failure is `-36`. A normal client returns the server's 4-byte exit code unchanged.
- `-p` parses a decimal FD first. A nonnumeric name opens with `O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC` and mode `0644`. Only a newly created file is unlinked at exit.
- The cleanup order matches C: cwd, server, terminal, SHM, renderer, Wayland, key bindings, reaper, signal handlers, FDM, config, PID file, logging.
- The signal mask is cleared. Handlers are reset before option parsing. SIGINT and SIGTERM use the FDM. SIGUSR1 and SIGUSR2 switch themes. SIGHUP and SIGPIPE are ignored after setup.
- Locale fallback is `""`, then `C.UTF-8`, then `en_US.UTF-8`. A total failure keeps the window open with `/bin/sh -c ""`.
- CWD resolution uses `getcwd()` with a growing buffer, then prefers `$PWD` only when both real paths match.
- The no-compositor smoke test returned shell status 230, which is `-26`. It created no PID file because setup failed before `print_pid()`.

### Client and server IPC

The mirrors are 14 bytes for `client_data`, 2 for `client_string`, 5 for `client_ipc_hdr`, and 4 for `client_ipc_sigusr`. The ABI probe pins the fields and offsets.

The packet order is exact:

1. `uint32_t` total length.
2. `client_data`.
3. executable, cwd, optional activation token.
4. override length/string pairs.
5. foot argv length/string pairs.
6. slave argv length/string pairs.
7. optional environment length/string pairs.

The server uses a 128 KiB setup limit, level-triggered `EPOLLIN`, and the same teardown paths for HUP, short reads, oversized packets, malformed setup, and no monitors. The no-wait path sends exit code 0 and leaves the terminal in the server list.

There is no `SCM_RIGHTS` use in either the C or Zig client/server protocol. Socket activation passes a listening FD number in the config string; `prepare_socket()` validates it.

### Fake-socket fixture

The audit used a Python UNIX-socket fixture. It accepted one connection, read the 4-byte length, read exactly that many setup bytes, parsed the 14-byte header and all string arrays, then sent a native `int` exit code 42 and closed.

Commands:

```sh
python3 /tmp/audit-plumbing/fake_server.py /tmp/audit-plumbing/fake.sock &
build/footclient -s /tmp/audit-plumbing/fake.sock /bin/true
```

The client returned 42. The fixture asserted the packet order and counts. Valgrind on the same exchange found PL-05.

## Config audit

### Ownership and failure cleanup

`config_load()` zeroes the whole config, assigns every default, and moves initial notifications into `conf.notifications`. `config_free()` frees every owned string, font list, argv, regex, binding aux, modifier list, environment entry, notification, and utmp helper path.

The normal partial-failure path is symmetric. `main` calls `config_free()` when `config_load()` returns false. The config oracle under Valgrind reported zero definite or indirect leaks.

No additional partial-config leak was found in `config_load()`. PL-02 is a binding-error double free, not a load cleanup leak.

### Parsing

- `str_to_ulong()` uses libc `strtoul`, clears errno, and requires a complete parse. The 32-bit and 16-bit helpers add range checks.
- `value_to_dimensions()` keeps `sscanf("%ux%u")` behavior, including leading whitespace and ignored trailing text.
- `value_to_float()` uses libc `strtof` and requires a complete parse with no errno.
- `value_to_pt_or_px()` requires the `px` suffix to be the exact end pointer and keeps C's truncation to `i16`.
- Colours accept exactly 6 hex digits, or 8 digits when alpha is allowed. RGB colours gain `ff000000` only in the alpha-capable form.
- Double colours use libc `strtok`, require two values, and assign outputs only after both parse.
- Strings support whole-value single or double quotes and unescape only the active quote or backslash.

All section keys match C. The counts are 40 for `[main]`, 1 security, 6 bell, 4 notifications, 4 scrollback, 5 URL, 2 regex, 16 colour-theme, 6 cursor, 2 mouse, 13 CSD, 1 touch, and 18 tweak keys. The Zig regex section also has the expected `launch` and `regex` branches.

No parsed key is left without a config field assignment. The four default binding tables contain 22 key, 44 search, 5 URL, and 13 mouse entries, matching C.

### Regex wrapper

`config_regex_compile()` uses `REG_EXTENDED`, formats `regerror()` on failure, and returns `-2` after `regfree()` when `re_nsub == 0`. Zig compiles into a local object first, so a failed replacement leaves the old regex intact. Success then frees the old regex and installs the new one.

## Utilities, FDM, reaper and spawn

- `xstrjoin` and `xasprintf` return allocated NUL-terminated strings. The caller owns the result. PL-06 covers the allocator edge contract.
- `log_*` uses `@cVaStart`, `@cVaCopy`, and `@cVaEnd`. `log_errno_va()` captures errno before formatting. The contextual errno path preserves C's later capture point.
- FDM uses level-triggered epoll. It defers FD-handler deletion during dispatch and skips deleted handlers. PL-09 and PL-10 cover allocation cleanup and hook deletion.
- The reaper removes a child before invoking its callback. It drains all exited children with `waitpid(-1, ..., WNOHANG)`.
- `spawn()` creates an `O_CLOEXEC` error pipe, resets the child session and signal state, sets PWD and activation variables, duplicates the requested standard FDs, and reports exec errors to the parent. The parent reaps a failed child.
- `slave_spawn()` builds a mutable environment copy, applies TERM/COLORTERM/PWD, removes terminal-specific variables, applies `TERMINFO` and configured environment entries, validates SHELL, and forks. The error pipe is close-on-exec.
- `base64` matches the C tables and padding rules for valid input. Empty base64 decodes to an empty allocated string. Embedded NUL terminates decode input, as in C.
- `uri_parse()` respects the supplied length, decodes `%xx`, treats `?` and `#` as path text for file URIs, and frees all partial outputs on failure. PL-01 is the port overflow.
- `async_write()` handles empty input, EAGAIN, and partial writes. A zero-byte write loops, matching C.

## ABI mirror and build options

`C_TYPES` covers the server structs, all four protocol structs, `sockaddr_un`, `Config`, `ConfigContext`, font lists, argv, binding aux/list structs, `CustomRegex`, `Terminal`, `Wayland`, `Monitor`, `Grid`, and `FcftGlyph`. The protocol and server mirrors have compile-time checks in `terminal_types.zig`.

PL-08 lists the mirrors used by this layer that are still outside the probe. The opaque `regex_t` is size-pinned through `Config.url.preg`; its private alignment and fields stay in C.

| Build option | Zig consumer | Result |
|---|---|---|
| `default_terminfo` | `main.zig`, `client.zig`, `config.zig` | Same default TERM and help text |
| `foot_terminfo_path` | `slave.zig` | Same conditional TERMINFO value |
| `asan_enabled` | `debug.zig` | Same ASAN-only stack trace |
| `utmp_enabled`, `utmp_add`, `utmp_del`, `utmp_del_have_argument`, `utmp_helper_path` | `terminal.zig`, `config.zig` | Same backend and helper selection |
| `grapheme_clustering` | `terminal_types.zig`, config, terminal, VT, features | Same feature gate |
| `pixman_rgba_16` | `config.zig` | Same `surface-bit-depth` choices |
| `pgo`, `ime`, `toplevel_tag`, `blur`, `assertions` | `foot-features.zig` | Same version feature string |

The audit also generated Meson build files for `debugoptimized` and `plain`. The C compiler flags and Zig feature flags agree in both cases.

## Shim table

Class a means C-only platform, opaque-type, macro, or varargs knowledge. Class b means a mirror adapter that should be deleted. Class c means logic that should be ported.

| File/function | Class | Assessment |
|---|---|---|
| `main-shim.c:main_shim_is_directory()` | a | Keep. It hides `struct stat` and `S_ISDIR`. |
| `xmalloc-shim.c:xasprintf()` | a | Keep. Zig cannot define a C variadic entry point. |
| `xsnprintf-shim.c:xsnprintf()` | a | Keep. Same varargs reason. |
| `config.c:config_regex_compile()` | a | Keep as the documented regex exception. |
| `slave.c:slave_shim_execvpe()` and fallback | a | Keep as the documented exec/env exception. |
| `terminal-shim.c:terminal_shim_fcft_font_name()` | a | Keep. `fcft_font` is opaque here. |
| `terminal_shim_urls_mode_active()` | c, resolved | The old three-line C adapter is gone. `url-mode.zig:39` now exports the function used by `commands.zig` and other modules. |
| All other functions called by the owned modules | b | None remain in this call graph. Normal module exports are not shims. |

## Exceptions audit

### `config.c` — 35 lines

The file contains one function. It compiles a regex, formats libc's error, checks `re_nsub`, and frees a capture-free regex. Zig cannot name `regex_t` portably because glibc and musl use different layouts. Zig also cannot inspect `re_nsub` without that private layout.

The wrapper is the minimum practical C surface. It contains no option parsing, config ownership, logging policy, or binding logic. Moving any of those lines back to C would enlarge the exception without removing a Zig limitation.

### `slave.c` — 64 lines

The file contains `execvpe()` and the portable PATH-search fallback. Zig 0.16 has no `execvpeZ()` that accepts the caller's `envp`. `execvp()` and `std.posix.execvpeZ()` do not preserve the required custom-environment semantics.

The fallback is required when configure-time `EXECVPE` is absent. It is the original C search code. The file contains no PTY setup, signal restoration, environment rewriting, shell validation, or notification output. Those functions are all in `slave.zig`.

Conclusion: both C exceptions are justified and minimal.

## Verification

Run on an isolated worktree at the audit base.

| Check | Result |
|---|---|
| `ninja -C build` | Pass, 188 steps in the clean audit build |
| `meson test -C build --no-rebuild --print-errorlogs` | 5/5 pass |
| `./build/tests/test-config` | Pass; expected negative-case diagnostics only |
| `valgrind --leak-check=full ./build/tests/test-config` | 0 errors; 0 definite, indirect, or possible leaks; 16,768 bytes still reachable |
| `./build/foot -C -c foot.ini` | Exit 0 |
| `./build/footclient --help` | Exit 0 |
| Fake-socket client exchange | Correct packet order; exit code 42 passed through |
| Valgrind fake-socket client | Found PL-05, 32 definitely lost bytes |
| `foot -s -p /tmp/pid` without a compositor | Exit `-26`; no PID file, because setup failed first |
| `scripts/gen_abi_probe.py --check` | Pass; PL-08 shows the coverage limit |
| FreeBSD `fdm.zig` cross compile | Fails, PL-03 |
| aarch64 C epoll layout check | Confirms PL-04 |
| `scripts/dev-check.sh` | Not run. The shared source worktree had concurrent product edits; the isolated base build and tests were used instead. |

## Verified-identical list

- Getopt strings, long options, aliases, undocumented options, and `CHAR_MAX` offsets.
- All command-line override strings.
- Foot and client failure codes, help/version exits, and child exit-code passthrough.
- PID file flags, mode, numeric-FD path, and unlink-at-exit rule.
- Cleanup order and locale fallback chain.
- CWD growth loop and `$PWD` symlink preference.
- Client wire sizes, field order, packet order, string limits, and setup-size limit.
- Server accept loop, level-triggered framing, no-wait behavior, and normal teardown paths.
- Absence of `SCM_RIGHTS` in this protocol.
- Config defaults, section/key coverage, numeric libc semantics, colour widths, and default binding tables.
- Config load/free ownership on normal and partial-failure paths.
- Regex compile/error/`re_nsub`/`regfree` behavior.
- Logging varargs forwarding and errno capture points.
- FDM level triggering and deferred FD deletion.
- Reaper remove-before-callback behavior.
- Spawn and slave environment order, signal reset, FD duplication, and error-pipe protocol.
- Valid-input base64, URI, async-write, timespec, UTF-8 printable, and scrollback command behavior.
- Build-option values listed in the build-option table.

## Verified differences not reported as defects

The audit applied the brief's exclusion list. It did not report NULL guards where C dereferences, omitted `LOG_DBG`, `execvpe()` or `regex_t` staying C, the `mbrtoc32(NULL, ...)` state choice, skipped SIGKILL/SIGSTOP handling, the Meson-only ReleaseSafe mapping, or deliberate `strtoul` truncation in `print_pid`.
