config_test = executable(
  'test-config',
  'test-config.c',
  'test-config-stubs.c',
  # test-config.c #includes config.c, so the parser is compiled into the
  # test itself; the value-parsing helpers live in config.zig and come in
  # as an object file.
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
