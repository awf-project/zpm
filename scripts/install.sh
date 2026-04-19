#!/bin/sh
# Feature: F015 / T006
# POSIX-compatible installer for zpm: detects OS/arch, downloads binary from
# GitHub Releases, verifies SHA256 checksum, and places it in INSTALL_DIR.
set -eu

REPO="awf-project/zpm"
INSTALL_DIR="${INSTALL_DIR:-${HOME}/.local/bin}"

detect_os() {
    uname -s | tr '[:upper:]' '[:lower:]'
}

detect_arch() {
    uname -m
}

map_platform() {
    os=$(detect_os)
    arch=$(detect_arch)
    case "${os}-${arch}" in
        darwin-arm64)    echo "zpm-darwin-arm64" ;;
        darwin-x86_64)   echo "zpm-darwin-x86_64" ;;
        linux-x86_64)    echo "zpm-linux-x86_64" ;;
        linux-aarch64)   echo "zpm-linux-arm64" ;;
        *)
            echo "unsupported platform: ${os}-${arch}" >&2
            exit 1
            ;;
    esac
}

fetch_latest_release_url() {
    platform="$1"
    curl -fsSL "https://api.github.com/repos/${REPO}/releases/latest" \
        | grep "browser_download_url" \
        | grep "${platform}" \
        | sed 's/.*"browser_download_url": *"\([^"]*\)".*/\1/'
}

download_binary() {
    url="$1"
    dest="$2"
    curl -fsSL -o "$dest" "$url"
}

verify_checksum() {
    binary="$1"
    checksums_file="$2"
    name=$(basename "$binary")
    if command -v sha256sum >/dev/null 2>&1; then
        hash_cmd="sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        hash_cmd="shasum -a 256"
    else
        echo "warning: sha256sum and shasum not found, skipping checksum verification" >&2
        return
    fi
    expected=$(grep "$name" "$checksums_file" | awk '{print $1}')
    actual=$($hash_cmd "$binary" | awk '{print $1}')
    if [ "$expected" != "$actual" ]; then
        echo "checksum mismatch for ${name}" >&2
        exit 1
    fi
}

install_binary() {
    src="$1"
    mkdir -p "$INSTALL_DIR"
    cp "$src" "${INSTALL_DIR}/zpm"
    chmod +x "${INSTALL_DIR}/zpm"
}

check_path() {
    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*) ;;
        *)
            echo "warning: ${INSTALL_DIR} is not in your PATH" >&2
            printf '  Add to your shell profile: export PATH="${PATH}:%s"\n' "${INSTALL_DIR}" >&2
            ;;
    esac
}

main() {
    platform=$(map_platform)
    tmpdir=$(mktemp -d)
    trap 'rm -rf "$tmpdir"' EXIT

    binary="${tmpdir}/zpm"
    checksums="${tmpdir}/SHA256SUMS"

    binary_url=$(fetch_latest_release_url "$platform")
    if [ -z "$binary_url" ]; then
        echo "error: could not find release binary for ${platform}" >&2
        exit 1
    fi

    checksums_url=$(fetch_latest_release_url "SHA256SUMS")
    download_binary "$binary_url" "$binary"

    if [ -n "$checksums_url" ]; then
        download_binary "$checksums_url" "$checksums"
        verify_checksum "$binary" "$checksums"
    fi

    install_binary "$binary"
    check_path
    echo "zpm installed to ${INSTALL_DIR}/zpm"
}

case "$0" in
    *install.sh) main "$@" ;;
esac
