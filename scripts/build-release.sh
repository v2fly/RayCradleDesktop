#!/usr/bin/env bash
set -euo pipefail

APP_NAME="${APP_NAME:-RayCradleDesktop}"
APP_ID="${APP_ID:-org.v2fly.RayCradleDesktop}"

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "${script_dir}/.." && pwd)"
cd "${repo_root}"

usage() {
    cat <<EOF
Usage: scripts/build-release.sh [--binary-only]

Builds the current platform's RayCradleDesktop release artifact.

Outputs:
  Windows: dist/release/RayCradleDesktop-<version>-windows-<arch>.exe
           dist/release/RayCradleDesktop-<version>-windows-<arch>.zip
  macOS:   dist/release/RayCradleDesktop-<version>-darwin-<arch>.zip
  Linux:   dist/release/RayCradleDesktop-<version>-linux-<arch>.AppImage

Environment:
  RAYCRADLE_VERSION      Artifact version label. Default: GITHUB_REF_NAME or dev
  TARGET_GOOS            Target OS. Default: go env GOOS
  TARGET_GOARCH          Target architecture. Default: go env GOARCH
  DIST_DIR               Output directory. Default: dist/release
  GO_BUILD_TAGS          Override Go build tags. Default: gtk3 on Linux, empty elsewhere
  LINUXDEPLOY            Path to linuxdeploy. Linux only
  APPIMAGETOOL           Path to appimagetool. Linux only
EOF
}

binary_only=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary-only)
            binary_only=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'error: unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

safe_name() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '-'
}

zip_dir() {
    local src_dir="$1"
    local out_file="$2"

    mkdir -p "$(dirname -- "${out_file}")"
    rm -f "${out_file}"

    if command -v zip >/dev/null 2>&1; then
        (
            cd "${src_dir}"
            zip -X -q -r "${out_file}" .
        )
        return
    fi

    if command -v powershell.exe >/dev/null 2>&1; then
        local win_src win_out
        win_src="$(cd "${src_dir}" && pwd -W)"
        win_out="$(cd "$(dirname -- "${out_file}")" && pwd -W)\\$(basename -- "${out_file}")"
        powershell.exe -NoProfile -Command \
            "Compress-Archive -Path '${win_src}\\*' -DestinationPath '${win_out}' -Force" >/dev/null
        return
    fi

    die "zip or powershell.exe is required to create ${out_file}"
}

appimage_arch() {
    case "$1" in
        amd64) printf 'x86_64' ;;
        arm64) printf 'aarch64' ;;
        *) die "unsupported AppImage architecture: $1" ;;
    esac
}

debian_multiarch() {
    case "$1" in
        amd64) printf 'x86_64-linux-gnu' ;;
        arm64) printf 'aarch64-linux-gnu' ;;
        *) die "unsupported Debian multiarch target: $1" ;;
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

ensure_linuxdeploy() {
    if [[ -n "${LINUXDEPLOY:-}" ]]; then
        [[ -x "${LINUXDEPLOY}" ]] || die "LINUXDEPLOY is not executable: ${LINUXDEPLOY}"
        printf '%s\n' "${LINUXDEPLOY}"
        return
    fi

    if command -v linuxdeploy >/dev/null 2>&1; then
        command -v linuxdeploy
        return
    fi

    need_cmd curl
    local arch tool_dir tool
    arch="$(appimage_arch "${target_goarch:-$(go env GOARCH)}")"
    tool_dir="${repo_root}/dist/tools"
    tool="${tool_dir}/linuxdeploy-${arch}.AppImage"
    mkdir -p "${tool_dir}"

    if [[ ! -x "${tool}" ]]; then
        printf 'Downloading linuxdeploy for %s...\n' "${arch}" >&2
        curl -fsSL "$(linuxdeploy_url "${arch}")" -o "${tool}"
        chmod +x "${tool}"
    fi

    printf '%s\n' "${tool}"
}

ensure_appimagetool() {
    if [[ -n "${APPIMAGETOOL:-}" ]]; then
        [[ -x "${APPIMAGETOOL}" ]] || die "APPIMAGETOOL is not executable: ${APPIMAGETOOL}"
        printf '%s\n' "${APPIMAGETOOL}"
        return
    fi

    if command -v appimagetool >/dev/null 2>&1; then
        command -v appimagetool
        return
    fi

    need_cmd curl
    local arch tool_dir tool
    arch="$(appimage_arch "${target_goarch:-$(go env GOARCH)}")"
    tool_dir="${repo_root}/dist/tools"
    tool="${tool_dir}/appimagetool-${arch}.AppImage"
    mkdir -p "${tool_dir}"

    if [[ ! -x "${tool}" ]]; then
        printf 'Downloading appimagetool for %s...\n' "${arch}" >&2
        curl -fsSL \
            "https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-${arch}.AppImage" \
            -o "${tool}"
        chmod +x "${tool}"
    fi

    printf '%s\n' "${tool}"
}

write_linux_icon() {
    local path="$1"
    cat >"${path}" <<EOF
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256">
  <rect width="256" height="256" rx="48" fill="#1f2937"/>
  <path d="M64 68h128v34H64zM64 111h128v34H64zM64 154h128v34H64z" fill="#38bdf8"/>
  <circle cx="84" cy="85" r="8" fill="#f8fafc"/>
  <circle cx="84" cy="128" r="8" fill="#f8fafc"/>
  <circle cx="84" cy="171" r="8" fill="#f8fafc"/>
</svg>
EOF
}

copy_linux_library_to_appdir() {
    local appdir="$1"
    local library="$2"
    local multiarch="$3"
    local source=""
    local search_dir

    for search_dir in "/usr/lib/${multiarch}" "/lib/${multiarch}" /usr/lib /lib; do
        if [[ -e "${search_dir}/${library}" ]]; then
            source="${search_dir}/${library}"
            break
        fi
    done

    [[ -n "${source}" ]] || die "unable to find Linux library ${library}"
    cp -L "${source}" "${appdir}/usr/lib/${library}"
    chmod 0644 "${appdir}/usr/lib/${library}"

    if command -v patchelf >/dev/null 2>&1 && file "${appdir}/usr/lib/${library}" | grep -q 'ELF'; then
        patchelf --set-rpath '$ORIGIN' "${appdir}/usr/lib/${library}" || true
    fi
}

bundle_linux_text_stack_libraries() {
    local appdir="$1"
    local multiarch

    multiarch="$(debian_multiarch "${target_goarch:-$(go env GOARCH)}")"

    # linuxdeploy treats these as system libraries, but Debian Pango requires
    # matching HarfBuzz symbols on older distributions.
    copy_linux_library_to_appdir "${appdir}" libharfbuzz.so.0 "${multiarch}"
    copy_linux_library_to_appdir "${appdir}" libfribidi.so.0 "${multiarch}"
    copy_linux_library_to_appdir "${appdir}" libfreetype.so.6 "${multiarch}"
	copy_linux_library_to_appdir "${appdir}" libfontconfig.so.1 "${multiarch}"
}

copy_linux_file_to_appdir() {
	local source="$1"
	local appdir="$2"
	local target="${appdir}/${source#/}"

	mkdir -p "$(dirname -- "${target}")"
	cp -L "${source}" "${target}"
	chmod 0755 "${target}"
}

bundle_webkitgtk_helpers() {
	local appdir="$1"
	local multiarch="$2"
	local search_dirs file source
	local found=0

	search_dirs=(
		"/usr/lib/${multiarch}"
		/usr/lib64
		/usr/lib
		/usr/libexec
	)

	for file in \
		webkit2gtk-4.1/WebKitNetworkProcess \
		webkit2gtk-4.1/WebKitWebProcess \
		webkit2gtk-4.1/injected-bundle/libwebkit2gtkinjectedbundle.so
	do
		for search_dir in "${search_dirs[@]}"; do
			source="${search_dir}/${file}"
			if [[ -e "${source}" ]]; then
				copy_linux_file_to_appdir "${source}" "${appdir}"
				found=$((found + 1))
				break
			fi
		done
	done

	[[ "${found}" -ge 3 ]] || die "unable to find all WebKitGTK helper processes and injected bundle"
}

patch_webkitgtk_appdir_paths() {
	local appdir="$1"

	find "${appdir}/usr/lib" -type f -name 'libwebkit*' \
		-exec sed -i -e "s|/usr|././|g" {} +
}

patch_webkitgtk_helper_rpaths() {
	local appdir="$1"
	local file

	command -v patchelf >/dev/null 2>&1 || return 0

	for file in \
		"${appdir}/usr/lib/"*/webkit2gtk-4.1/WebKitNetworkProcess \
		"${appdir}/usr/lib/"*/webkit2gtk-4.1/WebKitWebProcess
	do
		[[ -e "${file}" ]] || continue
		patchelf --set-rpath '$ORIGIN/../..' "${file}" || true
	done

	for file in "${appdir}/usr/lib/"*/webkit2gtk-4.1/injected-bundle/libwebkit2gtkinjectedbundle.so; do
		[[ -e "${file}" ]] || continue
		patchelf --set-rpath '$ORIGIN/../../..' "${file}" || true
	done
}

build_go_binary() {
    local output="$1"
    local goos="$2"
    local goarch="${target_goarch:-$(go env GOARCH)}"
    local tags="${GO_BUILD_TAGS:-}"
    local ldflags="-s -w"

    if [[ -z "${tags}" && "${goos}" == "linux" ]]; then
        tags="gtk3"
    fi
    if [[ "${goos}" == "windows" ]]; then
        ldflags="-H=windowsgui ${ldflags}"
    fi

    mkdir -p "$(dirname -- "${output}")"

    if [[ -n "${tags}" ]]; then
        GOOS="${goos}" GOARCH="${goarch}" go build -trimpath -tags "${tags}" -ldflags "${ldflags}" -o "${output}" .
    else
        GOOS="${goos}" GOARCH="${goarch}" go build -trimpath -ldflags "${ldflags}" -o "${output}" .
    fi

    [[ -s "${output}" ]] || die "go build did not produce ${output}"
}

package_windows() {
    local artifact_base="$1"
    local build_dir="$2"
    local out_dir="$3"
    local exe="${build_dir}/${APP_NAME}.exe"
    local release_exe="${out_dir}/${artifact_base}.exe"
    local release_zip="${out_dir}/${artifact_base}.zip"

    build_go_binary "${exe}" "windows"
    if [[ "${binary_only}" == true ]]; then
        printf '%s\n' "${exe}"
        return
    fi

    mkdir -p "${out_dir}"
    cp "${exe}" "${release_exe}"
    [[ -s "${release_exe}" ]] || die "copy did not produce ${release_exe}"

    zip_dir "${build_dir}" "${release_zip}"
    [[ -s "${release_zip}" ]] || die "zip did not produce ${release_zip}"
    printf '%s\n%s\n' "${release_exe}" "${release_zip}"
}

package_macos() {
    local artifact_base="$1"
    local build_dir="$2"
    local out_dir="$3"
    local app_dir="${build_dir}/${APP_NAME}.app"
    local macos_dir="${app_dir}/Contents/MacOS"
    local resources_dir="${app_dir}/Contents/Resources"

    mkdir -p "${macos_dir}" "${resources_dir}"
    build_go_binary "${macos_dir}/${APP_NAME}" "darwin"
    chmod +x "${macos_dir}/${APP_NAME}"

    cat >"${app_dir}/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>${APP_ID}</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>${version}</string>
  <key>CFBundleVersion</key>
  <string>${version}</string>
  <key>LSMinimumSystemVersion</key>
  <string>11.0</string>
</dict>
</plist>
EOF

    if [[ "${binary_only}" == true ]]; then
        printf '%s\n' "${app_dir}"
        return
    fi

    zip_dir "${build_dir}" "${out_dir}/${artifact_base}.zip"
    printf '%s\n' "${out_dir}/${artifact_base}.zip"
}

package_linux_appimage() {
    local artifact_base="$1"
    local build_dir="$2"
    local out_dir="$3"
    local appdir="${build_dir}/${APP_NAME}.AppDir"
    local appimagetool arch linuxdeploy multiarch out_file

    mkdir -p \
        "${appdir}/usr/bin" \
        "${appdir}/usr/share/applications" \
        "${appdir}/usr/share/icons/hicolor/scalable/apps"

    build_go_binary "${appdir}/usr/bin/${APP_NAME}" "linux"
    chmod +x "${appdir}/usr/bin/${APP_NAME}"

	cat >"${appdir}/AppRun" <<EOF
#!/usr/bin/env sh
set -eu
APPDIR="\$(dirname "\$(readlink -f "\$0")")"
export WEBKIT_DISABLE_DMABUF_RENDERER="\${WEBKIT_DISABLE_DMABUF_RENDERER:-1}"
export APPDIR
cd "\${APPDIR}/usr"
exec "\${APPDIR}/usr/bin/${APP_NAME}" "\$@"
EOF
    chmod +x "${appdir}/AppRun"

    cat >"${appdir}/${APP_NAME}.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=${APP_NAME}
Exec=${APP_NAME}
Icon=${APP_NAME}
Categories=Network;
Terminal=false
EOF
    cp "${appdir}/${APP_NAME}.desktop" "${appdir}/usr/share/applications/${APP_NAME}.desktop"
    write_linux_icon "${appdir}/${APP_NAME}.svg"
    cp "${appdir}/${APP_NAME}.svg" "${appdir}/usr/share/icons/hicolor/scalable/apps/${APP_NAME}.svg"

    if [[ "${binary_only}" == true ]]; then
        printf '%s\n' "${appdir}"
        return
    fi

	appimagetool="$(ensure_appimagetool)"
	arch="$(appimage_arch "${target_goarch:-$(go env GOARCH)}")"
	multiarch="$(debian_multiarch "${target_goarch:-$(go env GOARCH)}")"
	out_file="${out_dir}/${artifact_base}.AppImage"
	mkdir -p "${out_dir}"
	rm -f "${out_file}"

	bundle_webkitgtk_helpers "${appdir}" "${multiarch}"

	linuxdeploy="$(ensure_linuxdeploy)"
	if ! (
		cd "${build_dir}"
        ARCH="${arch}" APPIMAGE_EXTRACT_AND_RUN=1 \
            "${linuxdeploy}" \
                --appdir "${appdir}" \
                --executable "${appdir}/usr/bin/${APP_NAME}" \
                --desktop-file "${appdir}/usr/share/applications/${APP_NAME}.desktop" \
                --icon-file "${appdir}/usr/share/icons/hicolor/scalable/apps/${APP_NAME}.svg"
    ); then
        die "linuxdeploy failed to populate ${appdir}"
	fi

	bundle_linux_text_stack_libraries "${appdir}"
	patch_webkitgtk_helper_rpaths "${appdir}"
	patch_webkitgtk_appdir_paths "${appdir}"

	appimagetool="$(ensure_appimagetool)"
    ARCH="${arch}" APPIMAGE_EXTRACT_AND_RUN=1 "${appimagetool}" "${appdir}" "${out_file}"
    chmod +x "${out_file}"
    printf '%s\n' "${out_file}"
}

need_cmd go

goos="${TARGET_GOOS:-$(go env GOOS)}"
target_goarch="${TARGET_GOARCH:-$(go env GOARCH)}"
version="${RAYCRADLE_VERSION:-${GITHUB_REF_NAME:-dev}}"
version="$(safe_name "${version}")"
out_dir="${DIST_DIR:-${repo_root}/dist/release}"
case "${out_dir}" in
    /*|[A-Za-z]:*)
        ;;
    *)
        out_dir="${repo_root}/${out_dir}"
        ;;
esac
build_dir="${repo_root}/dist/build/${goos}-${target_goarch}"
artifact_base="${APP_NAME}-${version}-${goos}-${target_goarch}"

rm -rf "${build_dir}"
mkdir -p "${build_dir}" "${out_dir}"

case "${goos}" in
    windows)
        package_windows "${artifact_base}" "${build_dir}" "${out_dir}"
        ;;
    darwin)
        package_macos "${artifact_base}" "${build_dir}" "${out_dir}"
        ;;
    linux)
        package_linux_appimage "${artifact_base}" "${build_dir}" "${out_dir}"
        ;;
    *)
        die "unsupported GOOS for release packaging: ${goos}"
        ;;
esac
