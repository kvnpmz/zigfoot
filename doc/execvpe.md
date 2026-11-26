# execvpe semantics

The Zig `slave_execvpe()` in `slave.zig` replaces both the glibc `execvpe`
call and the old non-glibc fallback. It keeps glibc's *search* rules, with one
deliberate difference about where PATH comes from.

> Checked on `ab5f4261` by `sed -n '242,308p' slave.zig` and
> `meson test -C build` (testlog `foot:execvpe`): all **11 cases** pass, including
> empty file → `ENOENT`, empty PATH → cwd, `ESTALE`/`ENODEV`/`ETIMEDOUT`
> continuing the search, and PATH read from `envp` overriding `getenv`/`environ`.
> No source change was needed; the algorithm below matches the implementation.

## Algorithm

- An empty file name fails with `ENOENT` before any PATH lookup.
- If the file name contains a slash it is passed to `execve()` once, with no
  PATH search.
- Otherwise PATH is read from the **supplied `envp`**. An unset PATH falls
  back to `confstr(_CS_PATH)`, as glibc does; an **empty** PATH is one empty
  component (search `./file`), *not* the confstr fallback.
- Components are tried in order; an empty component means the current
  directory. Each candidate is tried with `execve()`.
- `EACCES`, `ENOENT`, `ENOTDIR`, `ESTALE`, `ENODEV` and `ETIMEDOUT` keep the
  search alive; `EACCES` is remembered. `ENOEXEC` retries the candidate as
  `/bin/sh candidate argv[1] ...`. Any other error is returned immediately.
- If no candidate runs, the remembered `EACCES` wins over `ENOENT`. `argv`
  and `envp` are borrowed and never modified.

## Deliberate divergence from glibc

glibc's `execvpe()` obtains PATH from `getenv("PATH")`/`environ`. The port
reads it from the `envp` handed to `slave_execvpe()`, so foot's
`[environment] PATH=...` setting is honoured even when the parent process's
`environ` has a different PATH. This is an intentional product behaviour,
not "glibc semantics" in the strict sense.

## Cases covered

`tests/test-execvpe.c` drives eleven cases:

| Case | Expected |
|---|---|
| command found in PATH | child exits with the requested status |
| missing command | `ENOENT` |
| only a non-executable match | `EACCES` |
| non-executable match before an executable one | search continues, second runs |
| shebang-less script | `/bin/sh` fallback runs it |
| file name containing a slash | no PATH search |
| `PATH=:` (empty component) | current directory is searched |
| PATH unset | `confstr(_CS_PATH)` fallback |
| `PATH=` (empty) | current directory is searched, no confstr fallback |
| empty file name | `ENOENT` before the search |
| PATH in `envp` differs from `environ` | `envp` wins (documented divergence) |
