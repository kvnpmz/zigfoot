#!/bin/bash
# Emit exact Zig constants for the enums execute_binding() needs. The C
# compiler is the source of truth for the values; no transcription.
set -eu
cd /workspace

names_bind=$(rg -o 'BIND_ACTION_[A-Z0-9_]+' key-binding.h | sort -u)
names_aux=$(rg -o --no-filename 'BINDING_AUX_[A-Z0-9_]+' key-binding.h config.h | sort -u)
names_url=$(rg -o --no-filename 'URL_ACTION_[A-Z0-9_]+' terminal.h | sort -u)
names_sel=$(rg -o --no-filename 'SELECTION_[A-Z0-9_]+' terminal.h | sort -u)

emit_cases() {
    for n in "$@"; do
        printf '    printf("%s %%d\\n", (int)%s);\n' "$n" "$n"
    done
}

{
    echo '#include <stdio.h>'
    echo '#include "key-binding.h"'
    echo '#include "selection.h"'
    echo '#include "url-mode.h"'
    echo 'int main(void) {'
    emit_cases $names_bind
    emit_cases $names_aux
    emit_cases $names_url
    emit_cases $names_sel
    echo '    return 0;'
    echo '}'
} > /tmp/gen_enums.c

cc -I/workspace -I/workspace/build \
   -I/usr/include/pixman-1 -I/usr/include/freetype2 -I/usr/include/libpng16 \
   -I/usr/include/harfbuzz -I/usr/include/glib-2.0 -I/usr/lib64/glib-2.0/include \
   -D_GNU_SOURCE=200809L -DHAVE_PIXMAN_RGBA_16 -DHAVE_XDG_TOPLEVEL_TAG=1 \
   -DHAVE_EXT_BACKGROUND_EFFECT=1 -DFOOT_IME_ENABLED=1 \
   -o /tmp/gen_enums /tmp/gen_enums.c 2>/dev/null

/tmp/gen_enums | sort -k1,1 > /tmp/enums.txt
awk '{ printf "pub const %s: c_int = %s;\n", $1, $2 }' /tmp/enums.txt > /tmp/enums.zig

echo "constants: $(rg -c '' /tmp/enums.zig)"
rg 'URL_ACTION_|SELECTION_CHAR_WISE|SELECTION_BLOCK|SELECTION_WORD_WISE' /tmp/enums.zig | head -8
