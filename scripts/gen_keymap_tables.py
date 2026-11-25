#!/usr/bin/env python3
"""One-shot generator: keymap.h's key_data tables -> input.zig (D4b2a).

This is the script that produced the ~900 lines of key data now living at the
bottom of input.zig. It is checked in for review, not as part of the build:
keymap.h itself no longer contains the tables (they were removed in the same
commit), so re-running it requires the pre-migration header, e.g.

    git show 969f70f7:keymap.h > /tmp/keymap.h

The header is first run through the C preprocessor, which is what makes the
DEFAULT_MODS_FOR_KP()/DEFAULT_MODS_FOR_SINGLE()/DEFAULT_MODS_FOR_TILDE()
macro tables and their `"\\033O"#sym` string splicing come out expanded - the
generator then only has to:

  * turn C octal escapes into Zig `\\xNN` escapes,
  * map MOD_* / CURSOR_KEYS_* / KEYPAD_* to their numeric values,
  * emit `KeyData`, an `extern struct` with C's field layout, so that
    keymap_lookup() can keep handing pointers into these tables across the
    C boundary,
  * emit the sym -> table switch and keymap_lookup() itself.

Usage: python3 scripts/gen_keymap_tables.py > /tmp/tables.zig
       (then paste/append into input.zig)
"""
import re
import subprocess

INPUT_C = '/workspace/input.c'
KEYSYMS_H = '/usr/include/xkbcommon/xkbcommon-keysyms.h'

with open('/tmp/keymap_pre.c', 'w') as f:
    f.write('#include "keymap.h"\n')

subprocess.run(
    ['cc', '-E', '-P', '-I/workspace', '-I/workspace/build',
     '-I/usr/include/pixman-1', '-I/usr/include/freetype2', '-I/usr/include/libpng16',
     '-I/usr/include/harfbuzz', '-I/usr/include/glib-2.0', '-I/usr/lib64/glib-2.0/include',
     '-D_GNU_SOURCE=200809L', '-DHAVE_PIXMAN_RGBA_16', '-DHAVE_XDG_TOPLEVEL_TAG=1',
     '-DHAVE_EXT_BACKGROUND_EFFECT=1', '-DFOOT_IME_ENABLED=1',
     '/tmp/keymap_pre.c', '-o', '/tmp/keymap_pre.i'],
    check=True)

h = open('/tmp/keymap_pre.i').read()
c = open(INPUT_C).read()

# ── 1. sym -> table mapping, from keymap_data_for_sym()'s switch ───────────
switch_start = c.index('keymap_data_for_sym(xkb_keysym_t sym, size_t *count)')
switch_end = c.index('\n}\n', switch_start)
switch = c[switch_start:switch_end]
pairs = re.findall(r'case (XKB_KEY_\w+):\s*\*count = ALEN\((\w+)\);\s*return \2;', switch)
assert len(pairs) == 78, len(pairs)

# ── 2. the tables (post-preprocessor: one line per table, macros expanded) ─
ENTRY = re.compile(
    r'\{\s*(.+?),\s*(CURSOR_KEYS_\w+),\s*(KEYPAD_\w+),\s*'
    r'("(?:[^"\\]|\\.)*"(?:\s*"(?:[^"\\]|\\.)*")*)'
    r'\s*\}', re.S)

tables = {}
for m in re.finditer(r'static const struct key_data (\w+)\[\] = \{(.*?)\};', h, re.S):
    name, body = m.group(1), m.group(2)
    body = body.replace('{{', '{').replace('}}', '}')
    rows = [(e.group(1), e.group(2), e.group(3), e.group(4))
            for e in ENTRY.finditer(body)]
    assert rows, name
    tables[name] = rows
assert len(tables) == 78, len(tables)

MODS = {
    'MOD_NONE': 0x0, 'MOD_ANY': 0x1, 'MOD_SHIFT': 0x2, 'MOD_ALT': 0x4,
    'MOD_CTRL': 0x8, 'MOD_META': 0x10,
    'MOD_MODIFY_OTHER_KEYS_STATE1': 0x20,
    'MOD_MODIFY_OTHER_KEYS_STATE2': 0x40,
}
CURSOR = {'CURSOR_KEYS_DONTCARE': 0, 'CURSOR_KEYS_NORMAL': 1, 'CURSOR_KEYS_APPLICATION': 2}
KEYPAD = {'KEYPAD_DONTCARE': 0, 'KEYPAD_NUMERICAL': 1, 'KEYPAD_APPLICATION': 2}


def mods_value(expr):
    total = 0
    for part in expr.split('|'):
        part = part.strip()
        assert part in MODS, part
        total |= MODS[part]
    return total


def escape_literal(lit):
    """Contents of one C string literal -> Zig escape sequences."""
    out = []
    i = 1
    while i < len(lit) - 1:
        ch = lit[i]
        if ch != '\\':
            out.append(ch)
            i += 1
            continue
        nxt = lit[i + 1]
        if nxt in '01234567':
            j = i + 1
            digits = ''
            while j < len(lit) and len(digits) < 3 and lit[j] in '01234567':
                digits += lit[j]
                j += 1
            out.append('\\x%02x' % int(digits, 8))
            i = j
        elif nxt == 'x' or nxt == 'X':
            j = i + 2
            digits = ''
            while j < len(lit) and len(digits) < 2 and lit[j] in '0123456789abcdefABCDEF':
                digits += lit[j]
                j += 1
            assert digits, lit[i:i + 4]
            out.append('\\x%02x' % int(digits, 16))
            i = j
        elif nxt == 'e':
            out.append('\\x1b')
            i += 2
        elif nxt in 'rtn':
            out.append({'r': '\\r', 't': '\\t', 'n': '\\n'}[nxt])
            i += 2
        elif nxt == '\\':
            out.append('\\\\')
            i += 2
        elif nxt == '"':
            out.append('\\"')
            i += 2
        else:
            raise AssertionError(lit[i:i + 2])
    return ''.join(out)


def zig_string(group):
    """Concatenated C string literals -> one Zig literal."""
    parts = re.findall(r'"(?:[^"\\]|\\.)*"', group)
    assert parts, group
    return '"' + ''.join(escape_literal(p) for p in parts) + '"'


# ── 3. keysym values for the switch ───────────────────────────────────────
syms_src = open(KEYSYMS_H).read()
sym_values = {}
for name, _ in pairs:
    m = re.search(r'^#define %s\s+(0x[0-9a-fA-F]+)' % name, syms_src, re.M)
    assert m, name
    sym_values[name] = '0x%x' % int(m.group(1), 16)

# ── 4. emit ───────────────────────────────────────────────────────────────
L = []
L.append('// ─────────────────────────────────────────────────────────────────────────')
L.append('// The VT key tables (D4b2), translated from keymap.h.')
L.append('//')
L.append('// `modifiers` uses the MOD_* bits from keymap.h; the MODIFY_OTHER_KEYS_STATE1')
L.append('// / _2 bits mark entries that only apply when modifyOtherKeys mode 1 / 2 is')
L.append('// active. `seq` is what gets sent to the client. KeyData is field-for-field')
L.append("// identical to C's struct key_data (three enums and a pointer), so")
L.append('// keymap_lookup() can keep returning a pointer into these tables.')
L.append('// ─────────────────────────────────────────────────────────────────────────')
L.append('')
for name, val in [('MOD_NONE', 0x00), ('MOD_ANY', 0x01), ('MOD_SHIFT', 0x02),
                  ('MOD_ALT', 0x04), ('MOD_CTRL', 0x08), ('MOD_META', 0x10),
                  ('MOD_MODIFY_OTHER_KEYS_STATE1', 0x20),
                  ('MOD_MODIFY_OTHER_KEYS_STATE2', 0x40)]:
    L.append(f'pub const {name}: c_int = 0x{val:02x};')
L.append('')
for name, val in [('CURSOR_KEYS_DONTCARE', 0), ('CURSOR_KEYS_NORMAL', 1),
                  ('CURSOR_KEYS_APPLICATION', 2)]:
    L.append(f'pub const {name}: c_int = {val};')
L.append('')
for name, val in [('KEYPAD_DONTCARE', 0), ('KEYPAD_NUMERICAL', 1),
                  ('KEYPAD_APPLICATION', 2)]:
    L.append(f'pub const {name}: c_int = {val};')
L.append('')
L.append('pub const KeyData = extern struct {')
L.append('    modifiers: c_int,')
L.append('    cursor_keys: c_int,')
L.append('    keypad_keys: c_int,')
L.append('    seq: [*:0]const u8,')
L.append('};')
L.append('')

for name, rows in tables.items():
    L.append(f'const {name} = [_]KeyData{{')
    for mods, cur, pad, seq in rows:
        L.append(f'    .{{ .modifiers = {mods_value(mods)}, '
                 f'.cursor_keys = {CURSOR[cur]}, .keypad_keys = {KEYPAD[pad]}, '
                 f'.seq = {zig_string(seq)} }},')
    L.append('};')
    L.append('')

L.append("/// The table for `sym`, or null. Mirrors keymap.h's switch statement.")
L.append('export fn keymap_data_for_sym(sym: u32, count: *usize) callconv(.c) ?[*]const KeyData {')
L.append('    switch (sym) {')
for sym, table in pairs:
    L.append(f'        {sym_values[sym]} => {{ // {sym}')
    L.append(f'            count.* = {table}.len;')
    L.append(f'            return &{table};')
    L.append('        },')
L.append('        else => return null,')
L.append('    }')
L.append('}')
L.append('')
L.append("/// The sequence to send for `sym` with `mods`, honouring the terminal's")
L.append('/// cursor-key / keypad mode and the modifyOtherKeys state.')
L.append('export fn keymap_lookup(')
L.append('    term: *Terminal,')
L.append('    sym: u32,')
L.append('    mods: c_int,')
L.append(') callconv(.c) ?*const KeyData {')
L.append('    var count: usize = 0;')
L.append('    const info = keymap_data_for_sym(sym, &count) orelse return null;')
L.append('')
L.append('    const cursor_keys_mode: c_int = @intFromEnum(term.cursor_keys_mode);')
L.append('    const keypad_keys_mode: c_int = if (term.num_lock_modifier)')
L.append('        KEYPAD_NUMERICAL')
L.append('    else')
L.append('        @intFromEnum(term.keypad_keys_mode);')
L.append('')
L.append('    var j: usize = 0;')
L.append('    while (j < count) : (j += 1) {')
L.append('        var modifiers = info[j].modifiers;')
L.append('')
L.append('        if (modifiers & MOD_MODIFY_OTHER_KEYS_STATE1 != 0) {')
L.append('            if (term.modify_other_keys_2)')
L.append('                continue;')
L.append('            modifiers &= ~MOD_MODIFY_OTHER_KEYS_STATE1;')
L.append('        }')
L.append('        if (modifiers & MOD_MODIFY_OTHER_KEYS_STATE2 != 0) {')
L.append('            if (!term.modify_other_keys_2)')
L.append('                continue;')
L.append('            modifiers &= ~MOD_MODIFY_OTHER_KEYS_STATE2;')
L.append('        }')
L.append('')
L.append('        if (modifiers != MOD_ANY and modifiers != mods)')
L.append('            continue;')
L.append('')
L.append('        if (info[j].cursor_keys != CURSOR_KEYS_DONTCARE and')
L.append('            info[j].cursor_keys != cursor_keys_mode)')
L.append('            continue;')
L.append('')
L.append('        if (info[j].keypad_keys != KEYPAD_DONTCARE and')
L.append('            info[j].keypad_keys != keypad_keys_mode)')
L.append('            continue;')
L.append('')
L.append('        return &info[j];')
L.append('    }')
L.append('')
L.append('    return null;')
L.append('}')
L.append('')

print('\n'.join(L))
