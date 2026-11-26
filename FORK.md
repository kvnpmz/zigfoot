# Fork status and provenance

Zigfoot is an **unofficial** Zig port of the Wayland terminal emulator
[dnkl/foot](https://codeberg.org/dnkl/foot), the upstream project. It is not
endorsed by, affiliated with, or maintained by the upstream project or Daniel
Eklöf. Upstream's name, configuration format and terminal identity are kept
for compatibility; see [README.md](README.md) and [INSTALL.md](INSTALL.md)
for user-facing details.

## Base and license

* Upstream project: [dnkl/foot](https://codeberg.org/dnkl/foot) (upstream
  link), released under the MIT license.
* Upstream base: version **1.28.0**. The documented verification snapshot is
  `66a61615` on top of that release.
* License: MIT. Upstream copyright notices are retained, and the short
  [NOTICE](NOTICE) summarises the fork's status. No upstream copyright or
  licence grant has been removed.
* This fork is not affiliated with or endorsed by Daniel Eklöf.

## Development model and AI disclosure

This port was developed with substantial AI/LLM assistance: agents wrote much
of the Zig code, the porting harness, and documentation. That work was audited
and gated by the documented test and parity suites before being accepted; it
was not simply generated and shipped. The upstream project has its own policy
on AI-generated contributions, which applies to upstream, not to this fork.
The current, honest status is:

* Nine meson suites pass with 1,040 assertions.
* Render parity covers 1,058 cells at three scales against the C oracle
  (`6b3f557d`).
* In headless microbenchmarks, VT input is roughly 28% slower than C in
  `ReleaseSafe` and roughly 8% slower in `ReleaseFast`; config parsing and
  rendering are roughly at parity.

See [doc/perf-1.2.md](doc/perf-1.2.md) for the measurement methodology. No
frame-rate or compositor-level number is claimed.

## What is still C

The application modules are Zig, but this is a port, not a pure-Zig rewrite.
The tree still contains:

* 11 FFI shim files (2,552 lines total) that bridge libc/Wayland/other C APIs;
* generated C for ABI layout probing and Wayland/sRGB data (`abi_probe.c` and
  the generated Wayland and sRGB C files);
* C test harnesses and benchmark utilities, including the render-parity
  oracle comparison.

Build-time details are in [INSTALL.md](INSTALL.md); the historical engineering
record is in [MIGRATION_PLAN.md](MIGRATION_PLAN.md).

## Known limitations

* **Platforms:** runtime testing has been done on x86_64 Linux only. FreeBSD
  and aarch64 builds are compile-only; they have not been runtime-tested here.
* **Performance:** frame-level performance (FPS, input latency,
  startup-to-first-frame) has not been measured: the compositor provides no
  presentation feedback and the tree has no frame instrumentation. Window
  startup and teardown were measured separately (see `doc/perf-1.2.md`).
* **VT cost:** the safe Zig build pays extra bounds/safety-check cost in the
  terminal-input path versus C; `ReleaseFast` narrows but does not eliminate
  the measured gap.
* **Naming/compatibility:** installed commands are `zigfoot` and
  `zigfootclient`, and the package name is `zigfoot`; this is deliberately not
  a drop-in replacement for a distribution `foot` package. `foot.ini` and
  `TERM=foot` remain for compatibility.

## Reporting bugs

Please **open an issue in this repository**. Do not report zigfoot bugs to
upstream's tracker: upstream cannot reproduce or fix problems in this port.
Include the zigfoot version (`zigfoot --version`), logs (`zigfoot -d info`),
Wayland compositor details and reproduction steps. For bugs in unmodified
upstream 1.28.0, use the upstream project's own tracker instead (upstream link
only).

## Tracking upstream security fixes

Watch the upstream [dnkl/foot repository](https://codeberg.org/dnkl/foot)
(upstream link) for releases, tags and security-relevant commits. Compare
upstream changes against the recorded base (1.28.0, this branch at
`66a61615`), and re-run the documented suites before importing a fix. This
fork does not have an independent security advisory channel; treat upstream
notices as the input to that review.
