#!/bin/sh

set -e

if [ ${#} -ne 3 ]; then
    echo "Usage: ${0} <default_version> <src_dir> <out_file>"
    exit 1
fi

default_version=${1}
src_dir=${2}
out_file=${3}

# echo "default version:  ${default_version}"
# echo "source directory: ${src_dir}"
# echo "output file:      ${out_file}"

# A linked worktree has a .git *file*, not a directory; treat both as a git
# checkout so this check is meaningful outside the main worktree too.
if [ -e "${src_dir}/.git" ] && command -v git > /dev/null; then
    workdir=$(pwd)
    cd "${src_dir}"

    # Only semver tags are safe to parse into FOOT_MAJOR/MINOR/PATCH. A tag
    # such as "zig-migration-1.1" would otherwise end up in those integer
    # macros and break compilation (e.g. of csi-shim.c).
    if git describe --tags --match '[0-9]*' > /dev/null 2>&1; then
        git_version=$(git describe --always --tags --match '[0-9]*')
    else
        # No semver tags available, happens in e.g. CI builds
        git_version="${default_version}"
    fi

    git_branch=$(git rev-parse --abbrev-ref HEAD)
    cd "${workdir}"

    new_version="${git_version} ($(date "+%b %d %Y"), branch '${git_branch}')"
else
    new_version="${default_version}"
    extra=""
fi

major=$(echo "${new_version}" | sed -r 's/^([0-9]+)\.([0-9]+)\.([0-9]+).*/\1/')
minor=$(echo "${new_version}" | sed -r 's/^([0-9]+)\.([0-9]+)\.([0-9]+).*/\2/')
patch=$(echo "${new_version}" | sed -r 's/^([0-9]+)\.([0-9]+)\.([0-9]+).*/\3/')
extra=$(echo "${new_version}" | sed -r 's/^([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9]+-g[a-z0-9]+) .*)?.*/\5/')

is_number() {
    case "${1}" in
        ''|*[!0-9]*) return 1 ;;
        *) return 0 ;;
    esac
}

# FOOT_VERSION stays descriptive, but the integer macros must always be
# numeric. If a tag (or the default) cannot be parsed, fall back to the
# semver default version for those three macros.
if ! is_number "${major}" || ! is_number "${minor}" || ! is_number "${patch}"; then
    major=$(printf '%s\n' "${default_version}" | sed -r 's/^([0-9]+)\.([0-9]+)\.([0-9]+).*/\1/')
    minor=$(printf '%s\n' "${default_version}" | sed -r 's/^([0-9]+)\.([0-9]+)\.([0-9]+).*/\2/')
    patch=$(printf '%s\n' "${default_version}" | sed -r 's/^([0-9]+)\.([0-9]+)\.([0-9]+).*/\3/')
fi

if ! is_number "${major}" || ! is_number "${minor}" || ! is_number "${patch}"; then
    major=0
    minor=0
    patch=0
fi

new_version="#define FOOT_VERSION \"${new_version}\"
#define FOOT_MAJOR ${major}
#define FOOT_MINOR ${minor}
#define FOOT_PATCH ${patch}
#define FOOT_EXTRA \"${extra}\""

if [ -f "${out_file}" ]; then
    old_version=$(cat "${out_file}")
else
    old_version=""
fi

# echo "old version: ${old_version}"
# echo "new version: ${new_version}"

if [ "${old_version}" != "${new_version}" ]; then
    echo "${new_version}" > "${out_file}"
fi
