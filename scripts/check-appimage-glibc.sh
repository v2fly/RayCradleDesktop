#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: scripts/check-appimage-glibc.sh <AppImage> [<AppImage>...]

Fails if any ELF file inside the AppImage references a GLIBC symbol newer than
MAX_GLIBC_VERSION.

Environment:
  MAX_GLIBC_VERSION      Default: 2.36
EOF
}

if [[ $# -eq 0 || "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    [[ $# -eq 0 ]] && exit 2 || exit 0
fi

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

version_gt() {
    local left="$1"
    local right="$2"
    [[ "$(printf '%s\n%s\n' "${left}" "${right}" | sort -V | tail -n 1)" == "${left}" && "${left}" != "${right}" ]]
}

need_cmd file
need_cmd strings
need_cmd sort

max_glibc="${MAX_GLIBC_VERSION:-2.36}"
status=0

for appimage in "$@"; do
    [[ -f "${appimage}" ]] || die "AppImage does not exist: ${appimage}"
    appimage="$(cd -- "$(dirname -- "${appimage}")" && pwd)/$(basename -- "${appimage}")"

    tmpdir="$(mktemp -d)"
    trap 'rm -rf "${tmpdir}"' EXIT

    (
        cd "${tmpdir}"
        "${appimage}" --appimage-extract >/dev/null
    )

    highest="$(
        {
            if file "${appimage}" | grep -q 'ELF'; then
                strings "${appimage}" | grep -aoE 'GLIBC_[0-9]+\.[0-9]+' || true
            fi
            while IFS= read -r -d '' file_path; do
                if file "${file_path}" | grep -q 'ELF'; then
                    strings "${file_path}" | grep -aoE 'GLIBC_[0-9]+\.[0-9]+' || true
                fi
            done < <(find "${tmpdir}/squashfs-root" -type f -print0)
        } |
            sed 's/^GLIBC_//' |
            sort -V |
            tail -n 1
    )"

    if [[ -z "${highest}" ]]; then
        printf '%s: no GLIBC symbol references found\n' "${appimage}"
    elif version_gt "${highest}" "${max_glibc}"; then
        printf '%s: requires GLIBC_%s, maximum allowed is GLIBC_%s\n' "${appimage}" "${highest}" "${max_glibc}" >&2
        status=1
    else
        printf '%s: maximum GLIBC symbol is GLIBC_%s\n' "${appimage}" "${highest}"
    fi

    rm -rf "${tmpdir}"
    trap - EXIT
done

exit "${status}"
