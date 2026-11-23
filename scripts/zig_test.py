#!/usr/bin/env python3
"""Run `zig test` for one module with the same environment as the build.

Usage:
  scripts/zig_test.py MODULE.zig BUILD_OPTIONS.zig C_LAYOUT.zig [ZIG_FLAGS...]

Meson passes the generated `zig_test_build_options.zig` and `c_layout.zig`
so tests compile with the same feature configuration as the real build.
"""

import subprocess
import sys


def main() -> int:
    if len(sys.argv) < 4:
        sys.exit(__doc__)

    module, build_options, c_layout = sys.argv[1:4]
    extra = sys.argv[4:]

    cmd = ["zig", "test", "-lc", *extra,
           "--dep", "build_options",
           "--dep", "c_layout",
           "-Mroot=" + module,
           "-Mbuild_options=" + build_options,
           "-Mc_layout=" + c_layout]
    return subprocess.call(cmd)


if __name__ == "__main__":
    sys.exit(main())
