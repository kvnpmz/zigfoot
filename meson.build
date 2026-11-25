project('foot', 'c',
        version: '1.28.0',
        license: 'MIT',
        meson_version: '>=0.59.0',
        default_options: [
          'c_std=c11',
          'warning_level=1',
          'werror=true',
          'b_ndebug=if-release'])

is_debug_build = get_option('buildtype').startswith('debug')

cc = meson.get_compiler('c')

# Newer clang versions warns when using __COUNTER__ without -std=c2y
if cc.has_argument('-Wc2y-extensions')
  add_project_arguments('-Wno-c2y-extensions', language: 'c')
endif

if cc.has_function('memfd_create',
                   args: ['-D_GNU_SOURCE'],
                   prefix: '#include <sys/mman.h>')
  add_project_arguments('-DMEMFD_CREATE', language: 'c')
endif

# Missing on DragonFly, FreeBSD < 14.1
if cc.has_function('execvpe',
                   args: ['-D_GNU_SOURCE'],
                   prefix: '#include <unistd.h>')
  add_project_arguments('-DEXECVPE', language: 'c')
endif

if cc.has_function('sigabbrev_np',
                   args: ['-D_GNU_SOURCE'],
                   prefix: '#include <string.h>')
  add_project_arguments('-DSIGABBREV_NP', language: 'c')
endif

utmp_backend = get_option('utmp-backend')
if utmp_backend == 'auto'
  host_os = host_machine.system()
  if host_os == 'linux'
    utmp_backend = 'libutempter'
  elif host_os == 'freebsd'
    utmp_backend = 'ulog'
  else
    utmp_backend = 'none'
  endif
endif

utmp_default_helper_path = get_option('utmp-default-helper-path')

if utmp_backend == 'none'
  utmp_add = ''
  utmp_del = ''
  utmp_del_have_argument = false
  utmp_default_helper_path = ''
elif utmp_backend == 'libutempter'
  utmp_add = 'add'
  utmp_del = 'del'
  utmp_del_have_argument = false
  if utmp_default_helper_path == 'auto'
    utmp_default_helper_path = join_paths('/usr', get_option('libdir'), 'utempter', 'utempter')
  endif
elif utmp_backend == 'ulog'
  utmp_add = 'login'
  utmp_del = 'logout'
  utmp_del_have_argument = false
  if utmp_default_helper_path == 'auto'
    utmp_default_helper_path = join_paths('/usr', get_option('libexecdir'), 'ulog-helper')
  endif
else
    error('invalid utmp backend')
endif

add_project_arguments(
  ['-D_GNU_SOURCE=200809L',
   '-DFOOT_DEFAULT_TERM="@0@"'.format(get_option('default-terminfo'))] +
  (utmp_backend != 'none'
  ? ['-DUTMP_ADD="@0@"'.format(utmp_add),
     '-DUTMP_DEL="@0@"'.format(utmp_del),
     '-DUTMP_DEFAULT_HELPER_PATH="@0@"'.format(utmp_default_helper_path)]
  : []) +
  (utmp_del_have_argument
   ? ['-DUTMP_DEL_HAVE_ARGUMENT=1']
   : []) +
  (is_debug_build
    ? ['-D_DEBUG']
   : [cc.get_supported_arguments('-fno-asynchronous-unwind-tables')]) +
  (get_option('ime')
    ? ['-DFOOT_IME_ENABLED=1']
    : []) +
  (get_option('b_pgo') == 'use'
    ? ['-DFOOT_PGO_ENABLED=1']
    : []) +
  cc.get_supported_arguments(
    ['-pedantic',
     '-fstrict-aliasing',
     '-Wstrict-aliasing']) +
  (get_option('fanalyzer')
    ? ['-fanalyzer']
    : []),
  language: 'c',
)

terminfo_install_location = get_option('custom-terminfo-install-location')

if terminfo_install_location != ''
  add_project_arguments(
    ['-DFOOT_TERMINFO_PATH="@0@"'.format(
      join_paths(get_option('prefix'), terminfo_install_location))],
    language: 'c')
else
  terminfo_install_location = join_paths(get_option('datadir'), 'terminfo')
endif

# Compute the relative path used by compiler invocations.
source_root = meson.current_source_dir().split('/')
build_root = meson.global_build_root().split('/')
relative_dir_parts = []
i = 0
in_prefix = true
foreach p : build_root
  if i >= source_root.length() or not in_prefix or p != source_root[i]
    in_prefix = false
    relative_dir_parts += '..'
  endif
  i += 1
endforeach
i = 0
in_prefix = true
foreach p : source_root
  if i >= build_root.length() or not in_prefix or build_root[i] != p
    in_prefix = false
    relative_dir_parts += p
  endif
  i += 1
endforeach
relative_dir = join_paths(relative_dir_parts) + '/'

if cc.has_argument('-fmacro-prefix-map=/foo=')
  add_project_arguments('-fmacro-prefix-map=@0@='.format(relative_dir), language: 'c')
endif

math = cc.find_library('m')
threads = [dependency('threads'), cc.find_library('stdthreads', required: false)]
libepoll = dependency('epoll-shim', required: false)
pixman = dependency('pixman-1')
wayland_protocols = dependency('wayland-protocols', version: '>=1.41',
                               fallback: 'wayland-protocols',
                               default_options: ['tests=false'])
wayland_client = dependency('wayland-client')
wayland_cursor = dependency('wayland-cursor')
xkb = dependency('xkbcommon', version: '>=1.6.0')
fontconfig = dependency('fontconfig')
utf8proc = dependency('libutf8proc', required: get_option('grapheme-clustering'))

if utf8proc.found()
  add_project_arguments('-DFOOT_GRAPHEME_CLUSTERING=1', language: 'c')
endif

# Passed to compile_zig.py for Zig modules that mirror a clustering-gated
# C code path (char32.zig's c32width()).
grapheme_clustering_zig = utf8proc.found() ? 'true' : 'false'

pixman_rgba_16 = pixman.version().version_compare('>=0.46.0')
if pixman_rgba_16
  add_project_arguments('-DHAVE_PIXMAN_RGBA_16', language: 'c')
endif

tllist = dependency('tllist', version: '>=1.1.0', fallback: 'tllist')
fcft = dependency('fcft', version: ['>=3.3.1', '<4.0.0'], fallback: 'fcft')

wayland_protocols_datadir = wayland_protocols.get_variable('pkgdatadir')

wscanner = dependency('wayland-scanner', native: true)
wscanner_prog = find_program(
  wscanner.get_variable('wayland_scanner'), native: true)

wl_proto_headers = []
wl_proto_src = []
wl_proto_xml = [
  wayland_protocols_datadir / 'stable/xdg-shell/xdg-shell.xml',
  wayland_protocols_datadir / 'unstable/xdg-decoration/xdg-decoration-unstable-v1.xml',
  wayland_protocols_datadir / 'unstable/xdg-output/xdg-output-unstable-v1.xml',
  wayland_protocols_datadir / 'unstable/primary-selection/primary-selection-unstable-v1.xml',
  wayland_protocols_datadir / 'stable/presentation-time/presentation-time.xml',
  wayland_protocols_datadir / 'unstable/text-input/text-input-unstable-v3.xml',
  wayland_protocols_datadir / 'staging/xdg-activation/xdg-activation-v1.xml',
  wayland_protocols_datadir / 'stable/viewporter/viewporter.xml',
  wayland_protocols_datadir / 'staging/fractional-scale/fractional-scale-v1.xml',
  wayland_protocols_datadir / 'unstable/tablet/tablet-unstable-v2.xml',  # required by cursor-shape-v1
  wayland_protocols_datadir / 'staging/cursor-shape/cursor-shape-v1.xml',
  wayland_protocols_datadir / 'staging/single-pixel-buffer/single-pixel-buffer-v1.xml',
  wayland_protocols_datadir / 'staging/xdg-toplevel-icon/xdg-toplevel-icon-v1.xml',
  wayland_protocols_datadir / 'staging/xdg-system-bell/xdg-system-bell-v1.xml',
  wayland_protocols_datadir / 'staging/color-management/color-management-v1.xml',
]

if (wayland_protocols.version().version_compare('>=1.43'))
  wl_proto_xml += [wayland_protocols_datadir / 'staging/xdg-toplevel-tag/xdg-toplevel-tag-v1.xml']
  add_project_arguments('-DHAVE_XDG_TOPLEVEL_TAG=1', language: 'c')
endif
if (wayland_protocols.version().version_compare('>=1.45'))
  wl_proto_xml += [wayland_protocols_datadir / 'staging/ext-background-effect/ext-background-effect-v1.xml']
  add_project_arguments('-DHAVE_EXT_BACKGROUND_EFFECT=1', language: 'c')
endif

# The Zig mirrors of wayland.h (terminal_types.zig, chunks B1/B2) include the
# fields these compile-time flags gate. Turning any of them off changes the
# struct layout, so fail here with a clear message rather than with an ABI
# probe mismatch deep in a Zig compile.
if not get_option('ime')
  error('the Zig wayland.h mirrors assume IME support; configure with -Dime=true')
endif
if not wayland_protocols.version().version_compare('>=1.43')
  error('the Zig wayland.h mirrors assume xdg-toplevel-tag (wayland-protocols >= 1.43)')
endif
if not wayland_protocols.version().version_compare('>=1.45')
  error('the Zig wayland.h mirrors assume ext-background-effect (wayland-protocols >= 1.45)')
endif

foreach prot : wl_proto_xml
  wl_proto_headers += custom_target(
    prot.underscorify() + '-client-header',
    output: '@BASENAME@.h',
    input: prot,
    command: [wscanner_prog, 'client-header', '@INPUT@', '@OUTPUT@'])

  wl_proto_src += custom_target(
    prot.underscorify() + '-private-code',
    output: '@BASENAME@.c',
    input: prot,
    command: [wscanner_prog, 'private-code', '@INPUT@', '@OUTPUT@'])
endforeach

env = find_program('env', native: true)
generate_version_sh = files('generate-version.sh')
version = custom_target(
  'generate_version',
  build_always_stale: true,
  output: 'version.h',
  command: [env, 'LC_ALL=C', generate_version_sh, meson.project_version(), '@CURRENT_SOURCE_DIR@', '@OUTPUT@'])

python = find_program('python3', native: true)

# ABI probe: compile the real C headers and emit the layout as Zig constants.
# terminal_types.zig imports `c_layout` and compares every mirrored struct
# against it at compile time (see `expectAbi`).
abi_probe = executable(
  'abi_probe',
  'abi_probe.c',
  wl_proto_headers,
  dependencies: [libepoll, pixman, fcft, tllist, wayland_client, xkb, utf8proc],
)

c_layout = custom_target(
  'c_layout',
  output: 'c_layout.zig',
  command: [abi_probe, '@OUTPUT@'],
  build_by_default: true,
)

zig_test_options = configuration_data()
zig_test_options.set('grapheme_clustering', grapheme_clustering_zig)
zig_test_build_options = configure_file(
  input: 'zig_test_build_options.zig.in',
  output: 'zig_test_build_options.zig',
  configuration: zig_test_options)

generate_builtin_terminfo_py = files('scripts/generate-builtin-terminfo.py')
foot_terminfo = files('foot.info')
builtin_terminfo = custom_target(
  'generate_builtin_terminfo',
  output: 'foot-terminfo.h',
  command: [python, generate_builtin_terminfo_py,
            '@default_terminfo@', foot_terminfo, 'foot', '@OUTPUT@']
)

generate_emoji_variation_sequences = files('scripts/generate-emoji-variation-sequences.py')
emoji_variation_sequences = custom_target(
  'generate_emoji_variation_sequences',
  input: 'unicode/emoji-variation-sequences.txt',
  output: 'emoji-variation-sequences.h',
  command: [python, generate_emoji_variation_sequences, '@INPUT@', '@OUTPUT@']
)

generate_srgb_funcs = files('scripts/srgb.py')
srgb_funcs = custom_target(
  'generate_srgb_funcs',
  output: ['srgb.c', 'srgb.h'],
  command: [python, generate_srgb_funcs, '@OUTPUT0@', '@OUTPUT1@']
)




composed_obj = custom_target(
  'composed_obj',
  input: 'composed.zig',
  output: 'composed.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)

base64_obj = custom_target(
  'base64_obj',
  input: 'base64.zig',
  output: 'base64.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)

xsnprintf_obj = custom_target(
  'xsnprintf_obj',
  input: 'xsnprintf.zig',
  output: 'xsnprintf.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)


char32_obj = custom_target(
  'char32_obj',
  input: 'char32.zig',
  output: 'char32.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ],
)


hsl_obj = custom_target(
  'hsl_obj',
  input: 'hsl.zig',
  output: 'hsl.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)


uri_obj = custom_target(
  'uri_obj',
  input: 'uri.zig',
  output: 'uri.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)



async_obj = custom_target(
  'async_obj',
  input: 'async.zig',
  output: 'async.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)

commands_obj = custom_target(
  'commands_obj',
  input: 'commands.zig',
  depend_files: files('terminal_types.zig'),
  output: 'commands.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

extract_obj = custom_target(
  'extract_obj',
  input: 'extract.zig',
  depend_files: files('terminal_types.zig'),
  output: 'extract.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

config_obj = custom_target(
  'config_obj',
  input: 'config.zig',
  depend_files: files('terminal_types.zig'),
  output: 'config.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
    # [tweak] surface-bit-depth only accepts "16-bit" when the C build has
    # HAVE_PIXMAN_RGBA_16.
    'pixman_rgba_16=' + pixman_rgba_16.to_string(),
    # config_load() mirrors the FOOT_DEFAULT_TERM / UTMP_DEFAULT_HELPER_PATH
    # / _DEBUG #defines the C build passes on the command line.
    'default_terminfo="' + get_option('default-terminfo') + '"',
    'utmp_helper_path="' + (utmp_backend != 'none' ? utmp_default_helper_path : '') + '"',
    'debug_build=' + is_debug_build.to_string(),
  ]
)

cursor_shape_obj = custom_target(
  'cursor_shape_obj',
  input: 'cursor-shape.zig',
  output: 'cursor-shape.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)

fdm_obj = custom_target(
  'fdm_obj',
  input: 'fdm.zig',
  output: 'fdm.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)

misc_obj = custom_target(
  'misc_obj',
  input: 'misc.zig',
  output: 'misc.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)

reaper_obj = custom_target(
  'reaper_obj',
  input: 'reaper.zig',
  output: 'reaper.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)


spawn_template_obj = custom_target(
  'spawn_template_obj',
  input: 'spawn_template.zig',
  output: 'spawn_template.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)

spawn_obj = custom_target(
  'spawn_obj',
  input: 'spawn.zig',
  output: 'spawn.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)

tokenize_obj = custom_target(
  'tokenize_obj',
  input: 'tokenize.zig',
  output: 'tokenize.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)

grid_obj = custom_target(
  'grid_obj',
  input: 'grid.zig',
  depend_files: files('terminal_types.zig', 'composed.zig'),
  output: 'grid.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

selection_obj = custom_target(
  'selection_obj',
  input: 'selection.zig',
  depend_files: files('terminal_types.zig'),
  output: 'selection.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)


terminal_obj = custom_target(
  '',
  input: 'terminal.zig',
  depend_files: files('terminal_types.zig', 'tll.zig'),
  output: 'terminal.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
    'utmp_enabled=' + (utmp_backend != 'none').to_string(),
    'utmp_add="' + utmp_add + '"',
    'utmp_del="' + utmp_del + '"',
    'utmp_del_have_argument=' + utmp_del_have_argument.to_string(),
  ],
)


csi_obj = custom_target(
  'csi_obj',
  input: 'csi.zig',
  depend_files: files('terminal_types.zig'),
  output: 'csi.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

dcs_obj = custom_target(
  'dcs_obj',
  input: 'dcs.zig',
  depend_files: files('terminal_types.zig'),
  output: 'dcs.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

osc_obj = custom_target(
  'osc_obj',
  input: 'osc.zig',
  depend_files: files('terminal_types.zig'),
  output: 'osc.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

debug_obj = custom_target(
  'debug_obj',
  input: 'debug.zig',
  depend_files: files('terminal_types.zig'),
  output: 'debug.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

user_notification_obj = custom_target(
  'user_notification_obj',
  input: 'user-notification.zig',
  depend_files: files('terminal_types.zig'),
  output: 'user-notification.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

unicode_mode_obj = custom_target(
  'unicode_mode_obj',
  input: 'unicode-mode.zig',
  depend_files: files('terminal_types.zig'),
  output: 'unicode-mode.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

foot_features_obj = custom_target(
  'foot_features_obj',
  input: 'foot-features.zig',
  output: 'foot-features.o',
  depends: version,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
    # foot-features.c is a chain of #defines built from the configure-time
    # feature set; mirror the same set as build options. `version=` reads
    # FOOT_VERSION out of the generated version.h.
    'version=version.h',
    'pgo=' + (get_option('b_pgo') == 'use').to_string(),
    'ime=' + get_option('ime').to_string(),
    'toplevel_tag=' + (wayland_protocols.version().version_compare('>=1.43')).to_string(),
    'blur=' + (wayland_protocols.version().version_compare('>=1.45')).to_string(),
    'assertions=' + is_debug_build.to_string(),
  ]
)

quirks_obj = custom_target(
  'quirks_obj',
  input: 'quirks.zig',
  depend_files: files('terminal_types.zig'),
  output: 'quirks.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

box_drawing_obj = custom_target(
  'box_drawing_obj',
  input: 'box-drawing.zig',
  depend_files: files('terminal_types.zig'),
  output: 'box-drawing.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

log_obj = custom_target(
  'log_obj',
  input: 'log.zig',
  depend_files: files('terminal_types.zig'),
  output: 'log.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
    # config.c's LOG_LEVEL help text and log.c's level-name table both hide
    # the "debug" entry in non-debug builds (_DEBUG).
    'debug_build=' + is_debug_build.to_string(),
  ]
)

shm_obj = custom_target(
  'shm_obj',
  input: 'shm.zig',
  depend_files: files('terminal_types.zig'),
  output: 'shm.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

slave_obj = custom_target(
  'slave_obj',
  input: 'slave.zig',
  depend_files: files('terminal_types.zig'),
  output: 'slave.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

sixel_obj = custom_target(
  'sixel_obj',
  input: 'sixel.zig',
  depend_files: files('terminal_types.zig'),
  output: 'sixel.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

vt_obj = custom_target(
  'vt_obj',
  input: 'vt.zig',
  depend_files: files('terminal_types.zig'),
  output: 'vt.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

notify_obj = custom_target(
  'notify_obj',
  input: 'notify.zig',
  depend_files: files('terminal_types.zig'),
  output: 'notify.o',
  depends: c_layout,
  command: [
    python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@',
    grapheme_clustering_zig,
  ]
)

xmalloc_obj = custom_target(
  'xmalloc_obj',
  input: 'xmalloc.zig',
  output: 'xmalloc.o',
  depends: c_layout,
  command: [python, files('compile_zig.py'), '@INPUT@', '@OUTPUT@']
)

common = static_library(
  'common',
  log_obj, 'log.h',
  char32_obj, 'char32.h',
  debug_obj, 'debug.c', 'debug.h',
  'macros.h',
  'xmalloc-shim.c',
    xmalloc_obj, 'xmalloc.h',
  'xsnprintf-shim.c',
  xsnprintf_obj, 'xsnprintf.h',
  dependencies: [utf8proc]
)

misc = static_library(
  'misc',
  hsl_obj, 'hsl.h',
  'macros.h',
  misc_obj, 'misc.h',
  uri_obj, 'uri.h',
  dependencies: [utf8proc],
  link_with: [common]
)

vtlib = static_library(
  'vtlib',
  base64_obj, 'base64.h',
  composed_obj, 'composed.h',
  cursor_shape_obj, 'cursor-shape.h',
  csi_obj, 'csi.h',
  'csi-shim.c',
  dcs_obj, 'dcs.h',
  'dcs-shim.c',
  'macros.h',
  osc_obj, 'osc.h',
  'osc-shim.c',
  sixel_obj, 'sixel.h',
  'sixel-shim.c',
  vt_obj, 'vt.h',
  'vt-shim.c',
  builtin_terminfo, srgb_funcs,
  wl_proto_src + wl_proto_headers,
  version,
  dependencies: [libepoll, pixman, fcft, tllist, wayland_client, xkb, utf8proc],
  link_with: [common, misc],
)

pgolib = static_library(
  'pgolib',
  grid_obj, terminal_obj, 'grid.h',
  'selection.c', selection_obj, 'selection.h', 'selection-shim.c',
  'terminal.c', 'terminal.h', 'terminal-shim.c',
  emoji_variation_sequences,
  wl_proto_src + wl_proto_headers,
  dependencies: [libepoll, pixman, fcft, tllist, wayland_client, xkb, utf8proc],
  link_with: vtlib,
)

tokenize = static_library(
  'tokenizelib',
  tokenize_obj,
  dependencies: [utf8proc],
  link_with: [common],
)

if get_option('b_pgo') == 'generate'
  executable(
    'pgo',
    'pgo/pgo.c',
    wl_proto_src + wl_proto_headers,
    dependencies: [math, threads, libepoll, pixman, wayland_client, xkb, utf8proc, fcft, tllist],
    link_with: pgolib,
  )
endif

foot_deps = [math, threads, libepoll, pixman, wayland_client, wayland_cursor,
             xkb, fontconfig, utf8proc, tllist, fcft]

# Everything except main.c, so tests can link the real code and supply their
# own main().
footlib = static_library(
  'footlib',
  async_obj, 'async.h',
  box_drawing_obj, 'box-drawing.h',
  'config.c', config_obj, 'config.h',
  commands_obj, 'commands.h',
  extract_obj, 'extract.h',
  fdm_obj, 'fdm.h',
  foot_features_obj, 'foot-features.h',
  'ime.c', 'ime.h',
  'input.c', 'input.h',
  'key-binding.c', 'key-binding.h',
  notify_obj, 'notify.h', 'notify-shim.c',
  quirks_obj, 'quirks.h',
  reaper_obj, 'reaper.h',
  'render.c', 'render.h',
  'search.c', 'search.h',
  'server.c', 'server.h', 'client-protocol.h',
  shm_obj, 'shm.c', 'shm.h',
  slave_obj, 'slave.c', 'slave.h',
  spawn_obj, spawn_template_obj, 'spawn.h',
  tokenize_obj, 'tokenize.h',
  unicode_mode_obj, 'unicode-mode.h',
  'url-mode.c', 'url-mode.h',
  user_notification_obj, 'user-notification.h',
  'wayland.c', 'wayland.h', 'shm-formats.h',
  'xkbcommon-vmod.h',
  srgb_funcs, wl_proto_src + wl_proto_headers, version,
  dependencies: foot_deps,
  link_with: pgolib)

executable(
  'foot',
  'main.c',
  wl_proto_src + wl_proto_headers,
  dependencies: foot_deps,
  link_with: footlib,
  install: true)

executable(
  'footclient',
  'client.c', 'client-protocol.h',
  foot_features_obj, 'foot-features.h',
  'macros.h',
  'util.h',
  version,
  dependencies: [tllist, utf8proc],
  link_with: [common, misc],
  install: true)

install_data(
  'foot.desktop', 'foot-server.desktop', 'footclient.desktop',
  install_dir: join_paths(get_option('datadir'), 'applications'))

systemd = dependency('systemd', required: false)
custom_systemd_units_dir = get_option('systemd-units-dir')

if systemd.found() or custom_systemd_units_dir != ''
  configuration = configuration_data()
  configuration.set('bindir', join_paths(get_option('prefix'), get_option('bindir')))

  if (custom_systemd_units_dir == '')
    systemd_units_dir = systemd.get_variable('systemduserunitdir')
  else
    systemd_units_dir = custom_systemd_units_dir
  endif

  configure_file(
    configuration: configuration,
    input: 'foot-server.service.in',
    output: '@BASENAME@',
    install_dir: systemd_units_dir
    )

  install_data(
    'foot-server.socket',
    install_dir: systemd_units_dir)
endif

scdoc = dependency('scdoc', native: true, required: get_option('docs'))
install_data('foot.ini', install_dir: join_paths(get_option('sysconfdir'), 'xdg', 'foot'))
if scdoc.found()
  install_data(
    'LICENSE', 'README.md', 'CHANGELOG.md',
    install_dir: join_paths(get_option('datadir'), 'doc', 'foot'))
  subdir('doc')
endif

if get_option('themes')
  install_subdir('themes', install_dir: join_paths(get_option('datadir'), 'foot'))
endif

terminfo_base_name = get_option('terminfo-base-name')
if terminfo_base_name == ''
  terminfo_base_name = get_option('default-terminfo')
endif

tic = find_program('tic', native: true, required: get_option('terminfo'))
if tic.found()
  conf_data = configuration_data(
    {
      'default_terminfo': terminfo_base_name
    }
  )

  preprocessed = configure_file(
    input: 'foot.info',
    output: 'foot.info.preprocessed',
    configuration: conf_data,
  )
  custom_target(
    'terminfo',
    output: terminfo_base_name[0],
    input: preprocessed,
    command: [tic, '-x', '-o', '@OUTDIR@', '-e', '@0@,@0@-direct'.format(terminfo_base_name), '@INPUT@'],
    install: true,
    install_dir: terminfo_install_location
  )
endif

subdir('completions')
subdir('icons')
subdir('utils')

if (get_option('tests'))
  zig_test_script = files('scripts/zig_test.py')
  gen_abi_probe_script = files('scripts/gen_abi_probe.py')

  # Modules with `test` blocks. Third element: extra zig test flags.
  zig_test_modules = [
    ['terminal_types', files('terminal_types.zig'), []],
    ['grid', files('grid.zig'), ['-lpixman-1']],
  ]

  subdir('tests')
endif

summary(
  {
    'Documentation': scdoc.found(),
    'Themes': get_option('themes'),
    'IME': get_option('ime'),
    'Grapheme clustering': utf8proc.found(),
    'utmp backend': utmp_backend,
    'utmp helper default path': utmp_default_helper_path,
    'Build terminfo': tic.found(),
    'Terminfo base name': terminfo_base_name,
    'Terminfo install location': terminfo_install_location,
    'Default TERM': get_option('default-terminfo'),
    'Set TERMINFO': get_option('custom-terminfo-install-location') != '',
    'Build tests': get_option('tests'),
  },
  bool_yn: true
)










