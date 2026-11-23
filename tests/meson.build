config_test = executable(
  'test-config',
  'test-config.c',
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
