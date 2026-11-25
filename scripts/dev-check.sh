#!/bin/sh
# Fast inner loop: build the debug build dir and run its tests (~15-20s).
#
# Use this while iterating; run scripts/full-check.sh before committing
# (it adds build-disabled + build-release and the smoke test).
#
# Note: never run two ninja invocations against the *same* build dir - they
# serialise on the build dir lock and can appear to hang.

set -e
cd "$(dirname "$0")/.."

# Zig modules are compiled in parallel; ninja's default job count already
# matches nproc, so no -j here.
ninja -C build
meson test -C build --no-rebuild
