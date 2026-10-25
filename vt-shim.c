#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include "terminal.h"

/* term->ascii_printer is a function pointer: void (*)(struct terminal *, uint8_t) */
void vt_call_ascii_printer(struct terminal *term, uint8_t c) {
    term->ascii_printer(term, c);
}

/* tab_stops: tll(int) insertion helper (needs iterator semantics) */
void vt_tab_stops_insert_before(struct terminal *term, int value) {
    tll_foreach(term->tab_stops, it) {
        if (it->item < value)
            continue;
        if (it->item > value)
            tll_insert_before(term->tab_stops, it, value);
        return;
    }
}

void vt_tab_stops_push_back(struct terminal *term, int value) {
    tll_push_back(term->tab_stops, value);
}

int vt_tab_stops_len(struct terminal *term) {
    return (int)tll_length(term->tab_stops);
}

int vt_tab_stops_back(struct terminal *term) {
    return tll_back(term->tab_stops);
}

int vt_tab_stops_next_after(struct terminal *term, int col) {
    tll_foreach(term->tab_stops, it) {
        if (it->item > col) return it->item;
    }
    return -1;
}
