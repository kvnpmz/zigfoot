# regex_t port

## What is opaque

Zig does not mirror regex_t. Its layout is libc-private: glibc and musl
disagree. config.zig keeps only a byte buffer and passes its address to the
libc entry points regcomp(), regerror(), and regfree().

The buffer type is:

    const RegexTBuffer = [abi.RegexT__size]u8;

Local compile temporaries are declared with align(abi.RegexT__align). On
successful compilation they are copied into the owning Config/CustomRegex
field, which is the same opaque byte array in the extern ABI mirror.

## What is probed

scripts/gen_abi_probe.py emits these facts into c_layout.zig from C:

    RegexT__size        sizeof(regex_t)
    RegexT__align       _Alignof(regex_t)
    RegexT_re_nsub      offsetof(regex_t, re_nsub)
    REG_EXTENDED        the regcomp() flag from <regex.h>

Current x86_64 Linux/glibc values:

    size = 64
    alignment = 8
    re_nsub offset = 48
    REG_EXTENDED = 1

re_nsub is read through an explicit byte-offset pointer cast in
regexCompile(). No Zig struct describes regex_t.

## Ownership

A successfully compiled RegexT owns allocations made by regcomp(). The owner
must call regfree() exactly once:

- config.zig replaces an existing URL regex only after the new pattern
  compiled successfully; it regfrees the old buffer before storing the new
  one;
- CustomRegex entries are regfreed when the list is destroyed;
- the default URL regex is compiled directly into its Config field and freed
  with that field;
- a failed regcomp() returns -1 without regfree(), matching config.c;
- a successful compile with re_nsub == 0 calls regfree() and returns -2.

Callers compile into a local first, so a rejected replacement leaves the
currently active regex untouched. The local is stack storage; only a
successful buffer is copied out.

## Tests

tests/test-regex.c is standalone and calls config_regex_compile_zig(). It
covers grouped compile plus regexec, the ungrouped -2/free path, invalid
syntax, truncated regerror text, and two sequential compile/free cycles. Build
it with the same compile and link flags as tests/test-terminal, substituting
tests/test-regex.c for tests/test-terminal.c; the resulting executable links
build/libfootlib.a. Run it under valgrind --leak-check=full.

