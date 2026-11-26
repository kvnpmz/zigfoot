config_test = executable(
  'test-config',
  'test-config.c',
  'test-config-stubs.c',
  # The parser and its value helpers are config.zig; the test links that
  # object and declares what it calls.
  config_obj,
  wl_proto_headers,
  link_with: [common, tokenize],
  dependencies: [pixman, xkb, fontconfig, wayland_client, fcft, tllist])

test('config', config_test)

# Zig unit tests. The script mirrors compile_zig.py's flags and gets the
# generated build_options + C ABI layout, so tests run in the same feature
# configuration as the build itself.
zig_build_root = meson.project_build_root()
zig_c_layout = join_paths(zig_build_root, 'c_layout.zig')
zig_build_options = join_paths(zig_build_root, 'zig_test_build_options.zig')

foreach m : zig_test_modules
  test(
    'zig-' + m[0],
    python,
    args: [zig_test_script, m[1], zig_build_options, zig_c_layout] + m[2],
    depends: [c_layout])
endforeach

test('abi-probe-up-to-date', python, args: [gen_abi_probe_script, '--check'])

# Headless terminal harness: links the real foot code (minus main.c) and
# supplies its own main(), so ported terminal.c/selection.c code can be
# exercised without wayland, a pty or a config file.
terminal_harness = executable(
  'test-terminal',
  'test-terminal.c',
  client_harness_obj,
  include_directories: '..',
  dependencies: foot_deps,
  link_with: footlib)

test('terminal-harness', terminal_harness)

# execvpe is Zig now (slave.zig, C ABI glue in slave.h). This drives the eight
# glibc semantics cases: PATH search, EACCES preference, ENOEXEC through /bin/sh.
execvpe_test = executable(
  'test-execvpe',
  'test-execvpe.c',
  include_directories: '..',
  dependencies: foot_deps,
  link_with: footlib)

test('execvpe', execvpe_test)

# regex_t is owned by config.zig now: opaque buffer, probed size/alignment and
# the re_nsub offset. This test drives the exported entry point directly.
regex_test = executable(
  'test-regex',
  'test-regex.c',
  include_directories: '..',
  dependencies: foot_deps,
  link_with: footlib)

test('regex', regex_test)

# Render parity corpus: paints the same cells/CSD/URL/OSD cases as a build of
# origin/master and compares FNV-1a hashes per cell. See scripts/render-parity.sh
# and doc/parity-report.md.
render_parity_harness = executable(
  'test-render-parity',
  'test-render-parity.c',
  client_harness_obj,
  include_directories: '..',
  dependencies: foot_deps,
  link_with: footlib,
  # The corpus paints through fake proxies, so the protocol inlines must be
  # wrapped exactly as scripts/render-parity.sh wraps them.
  link_args: [
    '-Wl,--wrap=wl_surface_attach',
    '-Wl,--wrap=wl_surface_damage_buffer',
    '-Wl,--wrap=wl_surface_commit',
    '-Wl,--wrap=wl_surface_set_buffer_scale',
    '-Wl,--wrap=wayland_shim_viewport_set_destination',
  ])

test('render-parity', render_parity_harness)
