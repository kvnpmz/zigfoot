#!/usr/bin/env python3
"""Generate abi_probe.c from the hand-written ABI mirrors in terminal_types.zig.

The probe prints `pub const <Type>_<field>: usize = ...;` lines using the C
compiler's own `sizeof`/`offsetof`, so `terminal_types.zig` can compare its
mirrors against the real C layout at compile time (see `expectAbi()` there).

Why generate the probe from the Zig side? So that adding a field to a mirror
automatically adds a check for it. The C compiler is still the source of
truth: if a field name does not exist in C, or an offset/size differs, the
build fails.

Usage:
  scripts/gen_abi_probe.py            # rewrite abi_probe.c
  scripts/gen_abi_probe.py --check    # fail if abi_probe.c is stale
"""

import os
import re
import sys
from typing import TypedDict

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SRC = os.path.join(ROOT, "terminal_types.zig")
OUT = os.path.join(ROOT, "abi_probe.c")


class Field(TypedDict):
    name: str
    kind: str
    base: str
    gated: bool
    nested: list["Field"]


class TypeInfo(TypedDict):
    kind: str
    fields: list[Field]


# Zig type name -> C type used as the `offsetof()` first argument.
# `NESTED_IN_TERMINAL` types are anonymous members of `struct terminal`, so
# their offsets are relative to that member (e.g. `render.margins`).
C_TYPES: dict[str, str] = {
    "Coord": "struct coord",
    "Range": "struct range",
    "Cursor": "struct cursor",
    "ScrollRegion": "struct scroll_region",
    "Damage": "struct damage",
    "Cell": "struct cell",
    "Attributes": "struct attributes",
    "RowData": "struct row_data",
    "Row": "struct row",
    "RowRanges": "struct row_ranges",
    "RowRange": "struct row_range",
    "RowRangeData": "union row_range_data",
    "UriRangeData": "struct uri_range_data",
    "UnderlineRangeData": "struct underline_range_data",
    "Colors": "struct colors",
    "Charsets": "struct charsets",
    "PtmxBuffer": "struct ptmx_buffer",
    "Composed": "struct composed",
    "Grid": "struct grid",
    "Sixel": "struct sixel",
    "Vt": "struct vt",
    "VtParam": "struct vt_param",
    "VtSubparams": "struct vt_subparams",
    "Terminal": "struct terminal",
    "Notification": "struct notification",
    "NotificationIcon": "struct notification_icon",
    "Url": "struct url",
}

NESTED_IN_TERMINAL: dict[str, str] = {
    "Render": "render",
    "Meta": "meta",
    "Flash": "flash",
    "Blink": "blink",
    "Margins": "margins",
}

# Zig-only helpers with no C counterpart; do not recurse into them.
SKIP: set[str] = {
    "AsciiPrinterBits", "TllInt", "TllStr", "TllNotification", "UrlList",
    "SixelList", "DamageList", "DamageNode", "SixelNode", "UrlNode",
    "NotificationNode", "Timespec", "Itimerspec",
}

# C packed structs: the size is checkable, individual members are bit-fields.
PACKED: set[str] = {"Attributes"}

FIELD_RE = re.compile(
    r'^(?:@"([^"]+)"|([A-Za-z_][A-Za-z0-9_]*))\s*:\s*(.*)$')

TYPE_RE = re.compile(
    r'^pub const ([A-Za-z_][A-Za-z0-9_]*) = '
    r'(extern struct|extern union|packed struct\([^)]+\)|struct) \{')


def strip_comment(line: str) -> str:
    # Good enough: terminal_types.zig has no string literal containing "//".
    index = line.find("//")
    return line if index < 0 else line[:index]


def block_end(lines: list[str], start: int) -> int:
    """Return the index of the line holding the matching closing brace."""
    depth = 0
    for index in range(start, len(lines)):
        text = strip_comment(lines[index])
        depth += text.count("{") - text.count("}")
        if depth == 0:
            return index
    raise ValueError(f"unbalanced braces starting at line {start + 1}")


def parse_fields(lines: list[str], lo: int, hi: int) -> list[Field]:
    fields: list[Field] = []
    index = lo
    while index < hi:
        line = strip_comment(lines[index]).strip()
        if not line:
            index += 1
            continue

        match = FIELD_RE.match(line)
        if not match:
            index += 1
            continue

        name = match.group(1) or match.group(2)
        typ = match.group(3)
        assert name is not None and typ is not None
        gated = False

        if typ.startswith("if ("):
            if "grapheme_clustering" not in typ:
                raise ValueError("unsupported comptime condition: " + typ)
            gated = True
            typ = "gated"

        nested: list[Field] = []
        kind = "scalar"
        if re.match(r'^(extern )?(struct|union)\s*\{', typ):
            kind = "union" if "union" in typ else "struct"
            end = block_end(lines, index)
            nested = parse_fields(lines, index + 1, end)
            index = end + 1
        else:
            index += 1

        base = re.split(r'[^A-Za-z0-9_]', typ.rstrip(',').strip())[0]
        fields.append({
            "name": name,
            "kind": kind,
            "base": base,
            "gated": gated,
            "nested": nested,
        })
    return fields


def parse_types(text: str) -> dict[str, TypeInfo]:
    lines = text.split("\n")
    types: dict[str, TypeInfo] = {}
    index = 0
    while index < len(lines):
        match = TYPE_RE.match(lines[index])
        if not match:
            index += 1
            continue
        name, keyword = match.group(1), match.group(2)
        assert name is not None and keyword is not None
        if keyword.startswith("packed"):
            kind = "packed"
        elif "union" in keyword:
            kind = "union"
        else:
            kind = "struct"
        end = block_end(lines, index)
        types[name] = {
            "kind": kind,
            "fields": [] if kind == "packed"
            else parse_fields(lines, index + 1, end),
        }
        index = end + 1
    return types


def c_member(root: str, path: list[str], field: str | None = None) -> str:
    parts = list(path)
    if field is not None:
        parts.append(field)
    return f"(({root} *)0)->{'.'.join(parts)}"


def c_offset(root: str, path: list[str], field: str,
             base_path: list[str] | None) -> str:
    expr = f"offsetof({root}, {'.'.join(path + [field])})"
    if base_path:
        expr += f" - offsetof({root}, {'.'.join(base_path)})"
    return expr


def emit_type(out: list[str], name: str, root: str, path: list[str],
              fields: list[Field], types: dict[str, TypeInfo],
              base_path: list[str] | None) -> None:
    size_expr = (f"sizeof({root})" if not path
                 else f"sizeof({c_member(root, path)})")
    out.append(f'fprintf(out, "pub const {name}__size: usize = %zu;\\n", '
               f'{size_expr});')
    emit_fields(out, name, root, path, fields, types, False, base_path)


def emit_fields(out: list[str], prefix: str, root: str, path: list[str],
                fields: list[Field], types: dict[str, TypeInfo],
                in_union: bool,
                base_path: list[str] | None) -> None:
    for field in fields:
        if field["name"].startswith("_"):
            continue
        if field["gated"]:
            out.append("#if defined(FOOT_GRAPHEME_CLUSTERING)")

        key = prefix + "_" + field["name"]
        member = c_member(root, path, field["name"])
        out.append(f'fprintf(out, "pub const {key}__size: usize = %zu;\\n", '
                   f'sizeof({member}));')
        if not in_union:
            offset = c_offset(root, path, field["name"], base_path)
            out.append(f'fprintf(out, "pub const {key}: usize = %zu;\\n", '
                       f'{offset});')
        if field["gated"]:
            out.append("#endif")

        if field["kind"] == "union":
            continue
        if field["kind"] == "struct":
            out.append(
                f'fprintf(out, "pub const {key}__abi_fields: usize = 1;\\n");')
            emit_fields(out, key, root, path + [field["name"]],
                        field["nested"], types, False,
                        path + [field["name"]])
            continue

        base = field["base"]
        if base in SKIP or base in PACKED:
            continue
        info = types.get(base)
        if info is not None and info["kind"] == "struct":
            out.append(
                f'fprintf(out, "pub const {key}__abi_fields: usize = 1;\\n");')
            emit_fields(out, key, root, path + [field["name"]],
                        info["fields"], types, in_union,
                        path + [field["name"]])


def generate() -> str:
    with open(SRC, "r", encoding="utf-8") as file:
        types = parse_types(file.read())

    out: list[str] = [
        "/* Generated by scripts/gen_abi_probe.py from terminal_types.zig.",
        " * Do not edit by hand; run the script instead.",
        " *",
        " * Prints the C layout as Zig constants so terminal_types.zig can",
        " * compare its mirrors against the real C structs at compile time. */",
        "",
        "#include <stddef.h>",
        "#include <stdio.h>",
        "#include <stdint.h>",
        "#include <stdbool.h>",
        "",
        '#include "composed.h"',
        '#include "grid.h"',
        '#include "notify.h"',
        '#include "terminal.h"',
        "",
        "int main(int argc, char **argv) {",
        "    FILE *out = stdout;",
        "    if (argc > 1 && !(out = fopen(argv[1], \"w\"))) {",
        "        perror(argv[1]);",
        "        return 1;",
        "    }",
    ]

    for name, c_type in C_TYPES.items():
        if name not in types:
            raise SystemExit(
                f"gen_abi_probe: {name} not found in {SRC}")
        emit_type(out, name, c_type, [], types[name]["fields"], types, None)

    for name, member in NESTED_IN_TERMINAL.items():
        if name not in types:
            raise SystemExit(
                f"gen_abi_probe: {name} not found in {SRC}")
        emit_type(out, name, "struct terminal", [member],
                  types[name]["fields"], types, [member])

    out += [
        "    if (out != stdout)",
        "        fclose(out);",
        "    return 0;",
        "}",
        "",
    ]
    return "\n".join(out)


def main() -> int:
    content = generate()
    if "--check" in sys.argv:
        try:
            with open(OUT, "r", encoding="utf-8") as file:
                current: str | None = file.read()
        except FileNotFoundError:
            current = None
        if current != content:
            sys.stderr.write(
                "abi_probe.c is stale; run scripts/gen_abi_probe.py\n")
            return 1
        return 0
    with open(OUT, "w", encoding="utf-8") as file:
        file.write(content)
    return 0


if __name__ == "__main__":
    sys.exit(main())
