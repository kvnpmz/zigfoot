#pragma once

#include <xkbcommon/xkbcommon.h>

#include "terminal.h"

enum modifier {
    MOD_NONE = 0x0,
    MOD_ANY = 0x1,
    MOD_SHIFT = 0x2,
    MOD_ALT = 0x4,
    MOD_CTRL = 0x8,
    MOD_META = 0x10,
    MOD_MODIFY_OTHER_KEYS_STATE1 = 0x20,
    MOD_MODIFY_OTHER_KEYS_STATE2 = 0x40,
};

struct key_data {
    enum modifier modifiers;
    enum cursor_keys cursor_keys_mode;
    enum keypad_keys keypad_keys_mode;
    const char *seq;
};

/* The key tables themselves now live in input.zig (D4b2), together with
 * keymap_data_for_sym() and keymap_lookup(). This header keeps only the
 * types the remaining C code needs. */
