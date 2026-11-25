/* C shim for the main port.
 *
 * struct stat is libc/arch-specific, and Zig's std.posix.Stat is void on
 * Linux, so the "is this a directory" test for -D/--working-directory stays
 * here. Everything else in main (argument parsing, locale, config, the
 * setup/teardown chain) is main.zig.
 */

#include <stdbool.h>
#include <sys/stat.h>

bool
main_shim_is_directory(const char *path)
{
    struct stat st;
    return stat(path, &st) == 0 && S_ISDIR(st.st_mode);
}
