#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"

usage() {
    cat <<EOF
Usage: scripts/run-linux-rootfs.sh -- <command> [args...]

Creates a Debian build rootfs and runs the command inside it with the current
workspace and Go toolchain bind-mounted at their original absolute paths.
The rootfs setup is executed through unshare -r, so no real root account or
privileged account is required.

Environment:
  LINUX_ROOTFS_SUITE     Debian suite. Default: bookworm
  LINUX_ROOTFS_MIRROR    Debian mirror. Default: http://deb.debian.org/debian
  LINUX_ROOTFS_DIR       Rootfs directory. Default: \$RUNNER_TEMP/raycradle-rootfs/<suite>-<arch>
  TARGET_GOARCH          Target Go architecture. Default: go env GOARCH
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
fi
if [[ "${1:-}" == "--" ]]; then
    shift
fi
if [[ $# -eq 0 ]]; then
    usage >&2
    exit 2
fi

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

fetch_url() {
    local url="$1"
    local output="$2"

    if command -v curl >/dev/null 2>&1; then
        curl -fsSL "${url}" -o "${output}"
        return
    fi
    if command -v wget >/dev/null 2>&1; then
        wget -q -O "${output}" "${url}"
        return
    fi

    die "curl or wget is required to fetch ${url}"
}

debian_arch() {
    case "$1" in
        amd64) printf 'amd64' ;;
        arm64) printf 'arm64' ;;
        *) die "unsupported Debian rootfs architecture: $1" ;;
    esac
}

appimage_arch() {
    case "$1" in
        amd64) printf 'x86_64' ;;
        arm64) printf 'aarch64' ;;
        *) die "unsupported AppImage architecture: $1" ;;
    esac
}

linuxdeploy_url() {
    case "$1" in
        x86_64)
            printf '%s\n' "https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage"
            ;;
        aarch64)
            printf '%s\n' "https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-aarch64.AppImage"
            ;;
        *)
            die "unsupported linuxdeploy architecture: $1"
            ;;
    esac
}

appimagetool_url() {
    case "$1" in
        x86_64|aarch64)
            printf 'https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-%s.AppImage\n' "$1"
            ;;
        *)
            die "unsupported appimagetool architecture: $1"
            ;;
    esac
}

command_needs_appimage_tools() {
    local arg
    for arg in "$@"; do
        case "${arg}" in
            *build-release.sh*)
                return 0
                ;;
        esac
    done
    return 1
}

ensure_extracted_appimage_tool() {
    local name="$1"
    local url="$2"
    local arch tool_dir tool extract_dir extracted_root

    arch="$(appimage_arch "${target_goarch}")"
    tool_dir="${repo_root}/dist/tools"
    tool="${tool_dir}/${name}-${arch}.AppImage"
    extract_dir="${tool_dir}/${name}-${arch}-extracted"
    extracted_root="${extract_dir}/squashfs-root"
    mkdir -p "${tool_dir}" "${extract_dir}"

    if [[ ! -x "${tool}" ]]; then
        fetch_url "${url}" "${tool}"
        chmod +x "${tool}"
    fi

    if [[ ! -d "${extracted_root}" ]]; then
        (
            cd "${extract_dir}"
            rm -rf squashfs-root
            "${tool}" --appimage-extract >/dev/null
        )
    fi

    [[ -d "${extracted_root}" ]] || die "failed to extract ${tool}"
    printf '%s\n' "${extracted_root}"
}

write_linuxdeploy_wrapper() {
    local extracted_root="$1"
    local wrapper="$2"

    cat >"${wrapper}" <<'EOF'
#!/usr/bin/env sh
set -eu
wrapper_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
tool_root="${wrapper_dir}/squashfs-root"
export PATH="${tool_root}/usr/bin:${tool_root}/plugins/linuxdeploy-plugin-appimage/usr/bin:${PATH:-}"
export LD_LIBRARY_PATH="${tool_root}/usr/lib:${tool_root}/usr/lib/x86_64-linux-gnu:${tool_root}/lib:${tool_root}/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
export LINUXDEPLOY_PLUGIN_DIR="${tool_root}/plugins"
exec "${tool_root}/usr/bin/linuxdeploy" "$@"
EOF
    chmod +x "${wrapper}"
    [[ -x "${extracted_root}/usr/bin/linuxdeploy" ]] || die "linuxdeploy was not extracted correctly"
}

write_appimagetool_wrapper() {
    local extracted_root="$1"
    local wrapper="$2"

    cat >"${wrapper}" <<'EOF'
#!/usr/bin/env sh
set -eu
wrapper_dir="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
tool_root="${wrapper_dir}/squashfs-root"
export PATH="${tool_root}/usr/bin:${PATH:-}"
export LD_LIBRARY_PATH="${tool_root}/usr/lib:${tool_root}/usr/lib/x86_64-linux-gnu:${tool_root}/lib:${tool_root}/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}"
exec "${tool_root}/usr/bin/appimagetool" "$@"
EOF
    chmod +x "${wrapper}"
    [[ -x "${extracted_root}/usr/bin/appimagetool" ]] || die "appimagetool was not extracted correctly"
}

ensure_appimage_build_tools() {
    local arch linuxdeploy_root appimagetool_root tool_dir

    command_needs_appimage_tools "$@" || return 0

    arch="$(appimage_arch "${target_goarch}")"
    tool_dir="${repo_root}/dist/tools"
    if [[ -z "${LINUXDEPLOY:-}" ]]; then
        linuxdeploy_root="$(ensure_extracted_appimage_tool linuxdeploy "$(linuxdeploy_url "${arch}")")"
        LINUXDEPLOY="${tool_dir}/linuxdeploy-${arch}-extracted/linuxdeploy-wrapper"
        write_linuxdeploy_wrapper "${linuxdeploy_root}" "${LINUXDEPLOY}"
        export LINUXDEPLOY
    fi
    if [[ -z "${APPIMAGETOOL:-}" ]]; then
        appimagetool_root="$(ensure_extracted_appimage_tool appimagetool "$(appimagetool_url "${arch}")")"
        APPIMAGETOOL="${tool_dir}/appimagetool-${arch}-extracted/appimagetool-wrapper"
        write_appimagetool_wrapper "${appimagetool_root}" "${APPIMAGETOOL}"
        export APPIMAGETOOL
    fi
}

csv_join() {
    local IFS=,
    printf '%s' "$*"
}

ensure_mmdebstrap() {
    if command -v mmdebstrap >/dev/null 2>&1; then
        mmdebstrap_cmd="$(command -v mmdebstrap)"
        return
    fi

    need_cmd apt-get
    need_cmd dpkg-deb

    local tool_dir download_dir install_dir deb
    tool_dir="${repo_root}/dist/tools/mmdebstrap"
    download_dir="${tool_dir}/download"
    install_dir="${tool_dir}/root"
    mkdir -p "${download_dir}" "${install_dir}"

    if [[ ! -x "${install_dir}/usr/bin/mmdebstrap" ]]; then
        (
            cd "${download_dir}"
            apt-get -o APT::Sandbox::User=root download mmdebstrap
        )
        deb="$(find "${download_dir}" -maxdepth 1 -type f -name 'mmdebstrap_*.deb' | sort -V | tail -n 1)"
        [[ -n "${deb}" ]] || die "apt-get download did not produce an mmdebstrap .deb"
        dpkg-deb -x "${deb}" "${install_dir}"
    fi

    mmdebstrap_cmd="${install_dir}/usr/bin/mmdebstrap"
    [[ -x "${mmdebstrap_cmd}" ]] || die "downloaded mmdebstrap is not executable: ${mmdebstrap_cmd}"
}

ensure_debian_keyring() {
    need_cmd dpkg-deb
    need_cmd xzcat

    local tool_dir download_dir install_dir packages_xz package_path keyring deb
    tool_dir="${repo_root}/dist/tools/debian-archive-keyring"
    download_dir="${tool_dir}/download"
    install_dir="${tool_dir}/root"
    keyring="${install_dir}/usr/share/keyrings/debian-archive-keyring.gpg"
    mkdir -p "${download_dir}" "${install_dir}"

    if [[ ! -f "${keyring}" ]]; then
        packages_xz="${download_dir}/Packages-${rootfs_suite}-${rootfs_debian_arch}.xz"
        fetch_url \
            "${rootfs_mirror%/}/dists/${rootfs_suite}/main/binary-${rootfs_debian_arch}/Packages.xz" \
            "${packages_xz}"

        package_path="$(
            xzcat "${packages_xz}" | awk '
                BEGIN { RS = ""; FS = "\n"; found = 0 }
                $1 == "Package: debian-archive-keyring" {
                    for (i = 1; i <= NF; i++) {
                        if ($i ~ /^Filename: /) {
                            sub(/^Filename: /, "", $i)
                            print $i
                            found = 1
                            break
                        }
                    }
                }
                END { if (found == 0) exit 1 }
            '
        )"
        [[ -n "${package_path}" ]] || die "unable to find debian-archive-keyring in ${packages_xz}"

        deb="${download_dir}/debian-archive-keyring.deb"
        fetch_url "${rootfs_mirror%/}/${package_path}" "${deb}"
        dpkg-deb -x "${deb}" "${install_dir}"
    fi

    [[ -f "${keyring}" ]] || die "Debian archive keyring was not extracted"
    debian_keyring="${keyring}"
}

enter_user_namespace() {
    if [[ "${RAYCRADLE_IN_UNSHARE:-}" == "1" ]]; then
        [[ "${EUID}" -eq 0 ]] || die "unshare did not map the current user to root"
        return
    fi

    need_cmd unshare
    ensure_mmdebstrap
    ensure_debian_keyring
    ensure_appimage_build_tools "$@"

    export RAYCRADLE_IN_UNSHARE=1
    exec unshare -r -m --propagation private -- "$0" -- "$@"
}

mount_bind() {
    local source="$1"
    local target="$2"

    mkdir -p "${target}"
    if ! mountpoint -q "${target}"; then
        mount --bind "${source}" "${target}"
        mounted_paths+=("${target}")
    fi
}

mount_bind_optional() {
    local source="$1"
    local target="$2"

    mkdir -p "${target}"
    if ! mountpoint -q "${target}"; then
        if mount --bind "${source}" "${target}"; then
            mounted_paths+=("${target}")
        else
            printf 'warning: unable to bind mount %s at %s; continuing\n' "${source}" "${target}" >&2
        fi
    fi
}

mount_device_file() {
    local name="$1"
    local source="/dev/${name}"
    local target="${rootfs}/dev/${name}"

    [[ -e "${source}" ]] || return 0
    mkdir -p "$(dirname -- "${target}")"
    : >"${target}"
    if ! mountpoint -q "${target}"; then
        mount --bind "${source}" "${target}"
        mounted_paths+=("${target}")
    fi
}

cleanup_mounts() {
    local path
    for ((idx=${#mounted_paths[@]} - 1; idx >= 0; idx--)); do
        path="${mounted_paths[$idx]}"
        if mountpoint -q "${path}"; then
            umount "${path}" || true
        fi
    done
}

prepare_rootfs() {
    local packages packages_csv
    packages=(
        bash
        binutils
        build-essential
        ca-certificates
        coreutils
        curl
        dash
        desktop-file-utils
        file
        findutils
        git
        grep
        gzip
        libc-bin
        libgtk-3-dev
        libsoup-3.0-dev
        libwebkit2gtk-4.1-dev
        patchelf
        pkg-config
        sed
        tar
        xz-utils
        zip
    )
    packages_csv="$(csv_join "${packages[@]}")"

    if [[ ! -e "${rootfs}/.raycradle-rootfs-ready-mmdebstrap-extract-v2" ]]; then
        rm -rf "${rootfs}"
        mkdir -p "${rootfs}"

        TAR_OPTIONS=--no-same-owner \
            "${mmdebstrap_cmd}" \
            --mode=unshare \
            --format=directory \
            --variant=extract \
            --include="${packages_csv}" \
            --keyring="${debian_keyring}" \
            --aptopt='APT::Sandbox::User "root"' \
            "${rootfs_suite}" \
            "${rootfs}" \
            "${rootfs_mirror}"

        cp /etc/resolv.conf "${rootfs}/etc/resolv.conf"
        chmod 1777 "${rootfs}/tmp" "${rootfs}/var/tmp" 2>/dev/null || true

        if [[ ! -e "${rootfs}/bin/sh" ]]; then
            ln -s bash "${rootfs}/bin/sh"
        fi
        if [[ ! -e "${rootfs}/usr/bin/cc" && -e "${rootfs}/usr/bin/gcc" ]]; then
            ln -s gcc "${rootfs}/usr/bin/cc"
        fi
        if [[ ! -e "${rootfs}/usr/bin/c++" && -e "${rootfs}/usr/bin/g++" ]]; then
            ln -s g++ "${rootfs}/usr/bin/c++"
        fi

        touch "${rootfs}/.raycradle-rootfs-ready-mmdebstrap-extract-v2"
        rootfs_created=1
    fi

    cp /etc/resolv.conf "${rootfs}/etc/resolv.conf"
}

need_cmd go
need_cmd mountpoint

target_goarch="${TARGET_GOARCH:-$(go env GOARCH)}"
host_goarch="$(go env GOARCH)"
if [[ "${target_goarch}" != "${host_goarch}" ]]; then
    die "Linux rootfs builds require native TARGET_GOARCH=${host_goarch}; got ${target_goarch}"
fi

rootfs_debian_arch="$(debian_arch "${target_goarch}")"
rootfs_suite="${LINUX_ROOTFS_SUITE:-bookworm}"
rootfs_mirror="${LINUX_ROOTFS_MIRROR:-http://deb.debian.org/debian}"
rootfs_base="${LINUX_ROOTFS_DIR:-${RUNNER_TEMP:-/tmp}/raycradle-rootfs/${rootfs_suite}-${rootfs_debian_arch}}"
mkdir -p "$(dirname -- "${rootfs_base}")"
rootfs="$(cd -- "$(dirname -- "${rootfs_base}")" && pwd)/$(basename -- "${rootfs_base}")"
goroot="$(go env GOROOT)"

enter_user_namespace "$@"
ensure_mmdebstrap
ensure_debian_keyring

mounted_paths=()
trap cleanup_mounts EXIT
rootfs_created=0

prepare_rootfs

if [[ "${rootfs_created}" == "1" && "${RAYCRADLE_REEXEC_AFTER_ROOTFS_CREATE:-}" != "1" ]]; then
    export RAYCRADLE_REEXEC_AFTER_ROOTFS_CREATE=1
    exec unshare -r -m --propagation private -- "$0" -- "$@"
fi

mount_bind_optional /proc "${rootfs}/proc"
mount_device_file null
mount_device_file zero
mount_device_file random
mount_device_file urandom
ln -sfn /proc/self/fd "${rootfs}/dev/fd"
ln -sfn /proc/self/fd/0 "${rootfs}/dev/stdin"
ln -sfn /proc/self/fd/1 "${rootfs}/dev/stdout"
ln -sfn /proc/self/fd/2 "${rootfs}/dev/stderr"

if [[ -d /etc/ssl/certs ]]; then
    mount_bind_optional /etc/ssl/certs "${rootfs}/etc/ssl/certs"
fi

mkdir -p "${rootfs}$(dirname -- "${repo_root}")"
mount_bind "${repo_root}" "${rootfs}${repo_root}"

mkdir -p "${rootfs}$(dirname -- "${goroot}")"
mount_bind "${goroot}" "${rootfs}${goroot}"

chroot "${rootfs}" /usr/bin/env -i \
    HOME=/root \
    PATH="${goroot}/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    GOROOT="${goroot}" \
    GOCACHE=/tmp/raycradle-go-build-cache \
    GOMODCACHE=/tmp/raycradle-go-mod-cache \
    CGO_ENABLED=1 \
    CC=/usr/bin/gcc \
    CXX=/usr/bin/g++ \
    PKG_CONFIG=/usr/bin/pkg-config \
    SSL_CERT_DIR=/etc/ssl/certs \
    RAYCRADLE_VERSION="${RAYCRADLE_VERSION:-${GITHUB_REF_NAME:-dev}}" \
    TARGET_GOOS="${TARGET_GOOS:-linux}" \
    TARGET_GOARCH="${target_goarch}" \
    GO_BUILD_TAGS="${GO_BUILD_TAGS:-gtk3}" \
    DIST_DIR="${DIST_DIR:-${repo_root}/dist/release}" \
    LINUXDEPLOY="${LINUXDEPLOY:-}" \
    APPIMAGETOOL="${APPIMAGETOOL:-}" \
    RAYCRADLE_REPO_ROOT="${repo_root}" \
    /bin/bash -lc 'cd "${RAYCRADLE_REPO_ROOT}" && "$@"' bash "$@"
