# execvpe semantics

The Zig implementation replaces both the glibc execvpe call and the old
non-glibc fallback. If the file name contains a slash it is passed to execve
once, with no PATH search. Otherwise PATH is read from the supplied envp; an
unset or empty PATH falls back to confstr(_CS_PATH). Components are tried in
order, an empty component means the current directory, EACCES and
ENOENT/ENOTDIR keep the search alive, and ENOEXEC retries the candidate as
/bin/sh with {"sh", candidate, argv[1], ...}. If no candidate runs, the
remembered EACCES wins over ENOENT; other errors such as EPERM and E2BIG are
returned immediately. argv and envp are borrowed and never modified.

## Cases covered

- command found in PATH;
- missing command (ENOENT);
- only a non-executable match (EACCES);
- non-executable match before an executable one (search continues);
- shebang-less script through /bin/sh;
- a file name containing a slash (no PATH search);
- an empty PATH component resolving in the current directory;
- PATH absent from envp (confstr fallback).
