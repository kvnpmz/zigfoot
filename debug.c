#include "debug.h"

/*
 * debug.c: fatal_error() and bug() are ported to debug.zig. Only the
 * AddressSanitizer hook has to stay in C, because it depends on
 * __SANITIZE_ADDRESS__ / HAS_FEATURE(address_sanitizer) being visible at
 * compile time.
 */

#include <stdio.h>

#if defined(__SANITIZE_ADDRESS__) || HAS_FEATURE(address_sanitizer)
#include <sanitizer/asan_interface.h>
#define ASAN_ENABLED 1
#endif

void debug_shim_print_stack_trace(void) {
#ifdef ASAN_ENABLED
    fputs("\nStack trace:\n", stderr);
    __sanitizer_print_stack_trace();
#endif
}
