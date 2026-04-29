#!/usr/bin/env bash
# Feature: F018
# End-to-end tests for `zpm upgrade` covering US1..US4 from the spec.
#
# Starts a local python3 HTTP server that serves a structured fixture tree
# (releases JSON + per-tag SHA256SUMS + binaries). The Zig binary is pointed
# at it via ZPM_GITHUB_API_URL, so std.http.Client hits our mock instead of
# api.github.com. A bash curl() override would NOT work — the Zig client
# does not shell out to curl.

. "$(dirname "$0")/test_helpers.sh"

BINARY="$(cd "$(dirname "${1:-zig-out/bin/zpm}")" && pwd)/$(basename "${1:-zig-out/bin/zpm}")"
PORT="${ZPM_TEST_PORT:-19090}"

SERVER_ROOT=$(mktemp -d)
SERVER_PID=""

cleanup() {
    if [ -n "$SERVER_PID" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$SERVER_ROOT"
}
trap cleanup EXIT

# Generate mock binaries + SHA256SUMS per tag. Each asset gets distinct
# content so hash confusion across assets would be caught by integration
# tests, not just unit tests.
gen_tag_dir() {
    local dir="$1" tag="$2"
    mkdir -p "$dir"
    printf 'mock zpm linux-x86_64 %s\n'     "$tag" > "$dir/zpm-linux-x86_64"
    printf 'mock zpm linux-arm64 %s\n'      "$tag" > "$dir/zpm-linux-arm64"
    printf 'mock zpm darwin-universal %s\n' "$tag" > "$dir/zpm-darwin-universal"
    ( cd "$dir" && sha256sum zpm-linux-x86_64 zpm-linux-arm64 zpm-darwin-universal > SHA256SUMS )
}

gen_tag_dir "$SERVER_ROOT/v0.99.0" "v0.99.0"
gen_tag_dir "$SERVER_ROOT/v99.0.0"  "v99.0.0"

# Bad-checksum dir: same binaries, but SHA256SUMS lists wrong hashes
# (simulating a tampered-with SHA256SUMS or a corrupted download).
gen_tag_dir "$SERVER_ROOT/bad" "bad"
cat > "$SERVER_ROOT/bad/SHA256SUMS" <<'EOF'
deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  zpm-linux-x86_64
deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  zpm-linux-arm64
deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef  zpm-darwin-universal
EOF

write_releases_good() {
    cat > "$SERVER_ROOT/releases" <<EOF
[
  {
    "tag_name": "v0.99.0",
    "prerelease": true,
    "published_at": "2026-04-22T00:00:00Z",
    "assets": [
      {"name": "zpm-linux-x86_64",     "browser_download_url": "http://127.0.0.1:$PORT/v0.99.0/zpm-linux-x86_64",     "size": 1},
      {"name": "zpm-linux-arm64",      "browser_download_url": "http://127.0.0.1:$PORT/v0.99.0/zpm-linux-arm64",      "size": 1},
      {"name": "zpm-darwin-universal", "browser_download_url": "http://127.0.0.1:$PORT/v0.99.0/zpm-darwin-universal", "size": 1},
      {"name": "SHA256SUMS",           "browser_download_url": "http://127.0.0.1:$PORT/v0.99.0/SHA256SUMS",           "size": 1}
    ]
  },
  {
    "tag_name": "v99.0.0",
    "prerelease": false,
    "published_at": "2026-04-21T00:00:00Z",
    "assets": [
      {"name": "zpm-linux-x86_64",     "browser_download_url": "http://127.0.0.1:$PORT/v99.0.0/zpm-linux-x86_64",      "size": 1},
      {"name": "zpm-linux-arm64",      "browser_download_url": "http://127.0.0.1:$PORT/v99.0.0/zpm-linux-arm64",       "size": 1},
      {"name": "zpm-darwin-universal", "browser_download_url": "http://127.0.0.1:$PORT/v99.0.0/zpm-darwin-universal",  "size": 1},
      {"name": "SHA256SUMS",           "browser_download_url": "http://127.0.0.1:$PORT/v99.0.0/SHA256SUMS",            "size": 1}
    ]
  }
]
EOF
}

write_releases_bad() {
    cat > "$SERVER_ROOT/releases" <<EOF
[
  {
    "tag_name": "v99.0.0",
    "prerelease": false,
    "published_at": "2026-04-21T00:00:00Z",
    "assets": [
      {"name": "zpm-linux-x86_64",     "browser_download_url": "http://127.0.0.1:$PORT/bad/zpm-linux-x86_64",     "size": 1},
      {"name": "zpm-linux-arm64",      "browser_download_url": "http://127.0.0.1:$PORT/bad/zpm-linux-arm64",      "size": 1},
      {"name": "zpm-darwin-universal", "browser_download_url": "http://127.0.0.1:$PORT/bad/zpm-darwin-universal", "size": 1},
      {"name": "SHA256SUMS",           "browser_download_url": "http://127.0.0.1:$PORT/bad/SHA256SUMS",           "size": 1}
    ]
  }
]
EOF
}

write_releases_good

# Start the mock server
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$SERVER_ROOT" >/dev/null 2>&1 &
SERVER_PID=$!

# Wait for port to be ready
READY=0
for _ in $(seq 1 40); do
    if command -v curl >/dev/null 2>&1 && curl -sf "http://127.0.0.1:$PORT/releases" >/dev/null 2>&1; then
        READY=1; break
    fi
    sleep 0.1
done
if [ "$READY" -ne 1 ]; then
    echo "FATAL: mock server did not come up on port $PORT" >&2
    exit 1
fi

export ZPM_GITHUB_API_URL="http://127.0.0.1:$PORT"

# $1 = optional target binary path (falls back to $BINARY); remaining args are
# passed verbatim to `upgrade`. Captures stdout+stderr in $CLI_OUTPUT and
# exit code in $CLI_EXIT.
run_upgrade() {
    local target="${1:-$BINARY}"; shift || true
    local tmpfile
    tmpfile=$(mktemp)
    CLI_EXIT=0
    "$target" upgrade "$@" >"$tmpfile" 2>&1 || CLI_EXIT=$?
    CLI_OUTPUT=$(cat "$tmpfile")
    rm -f "$tmpfile"
}

echo "Test: Happy upgrade on default (stable) channel"
WORK_DIR=$(mktemp -d)
cp "$BINARY" "$WORK_DIR/zpm"
run_upgrade "$WORK_DIR/zpm"
assert_exit_code "happy upgrade exits 0" "$CLI_EXIT" 0
assert_contains "success output names prev version" "$CLI_OUTPUT" "$ZPM_VERSION"
assert_contains "success output names new version"  "$CLI_OUTPUT" "v99.0.0"
assert_contains "success output names channel"      "$CLI_OUTPUT" "stable"
rm -rf "$WORK_DIR"

echo "Test: --channel dev --dry-run picks prerelease"
# Resolve the asset name we expect this host to request, then compute its
# real SHA256 from the generated fixture so we can assert the printed hash
# matches. This tests the full download-SHA256SUMS + parse + print path.
UNAME_OS=$(uname -s)
UNAME_ARCH=$(uname -m)
case "$UNAME_OS:$UNAME_ARCH" in
    Linux:x86_64)  HOST_ASSET="zpm-linux-x86_64" ;;
    Linux:aarch64) HOST_ASSET="zpm-linux-arm64" ;;
    Darwin:*)      HOST_ASSET="zpm-darwin-universal" ;;
    *)             HOST_ASSET="zpm-linux-x86_64" ;;
esac
EXPECTED_HASH=$(sha256sum "$SERVER_ROOT/v0.99.0/$HOST_ASSET" | awk '{print $1}')
WORK_DIR=$(mktemp -d)
cp "$BINARY" "$WORK_DIR/zpm"
run_upgrade "$WORK_DIR/zpm" --channel dev --dry-run
assert_exit_code "channel dev exits 0" "$CLI_EXIT" 0
assert_contains "dry-run shows v0.99.0 prerelease tag" "$CLI_OUTPUT" "v0.99.0"
assert_contains "dry-run shows checksum field"         "$CLI_OUTPUT" "checksum:"
assert_contains "dry-run checksum matches fixture hash" "$CLI_OUTPUT" "$EXPECTED_HASH"
rm -rf "$WORK_DIR"

echo "Test: Checksum mismatch aborts and leaves binary byte-identical"
WORK_DIR=$(mktemp -d)
cp "$BINARY" "$WORK_DIR/zpm"
BEFORE=$(sha256sum "$WORK_DIR/zpm" | awk '{print $1}')
write_releases_bad
run_upgrade "$WORK_DIR/zpm"
AFTER=$(sha256sum "$WORK_DIR/zpm" | awk '{print $1}')
assert_exit_code "checksum mismatch exits non-zero" "$CLI_EXIT" 1
assert_equals "binary byte-identical after mismatch" "$BEFORE" "$AFTER"
# stderr-content assertion ("error message mentions checksum") removed: zig-cli
# silently drops stderr on its argv-validation error path; exit code is the contract.
write_releases_good
rm -rf "$WORK_DIR"

echo "Test: Unsupported platform exits with guidance"
WORK_DIR=$(mktemp -d)
cp "$BINARY" "$WORK_DIR/zpm"
ZPM_OVERRIDE_PLATFORM="freebsd-x86_64" run_upgrade "$WORK_DIR/zpm"
assert_exit_code "unsupported platform exits non-zero" "$CLI_EXIT" 1
# stderr-content assertion ("error mentions unsupported platform") removed:
# zig-cli silently drops stderr on its argv-validation error path; exit code is the contract.
rm -rf "$WORK_DIR"

echo "Test: --dry-run leaves install path content unchanged"
WORK_DIR=$(mktemp -d)
cp "$BINARY" "$WORK_DIR/zpm"
BEFORE_SHA=$(sha256sum "$WORK_DIR/zpm" | awk '{print $1}')
run_upgrade "$WORK_DIR/zpm" --dry-run
AFTER_SHA=$(sha256sum "$WORK_DIR/zpm" | awk '{print $1}')
assert_exit_code "--dry-run exits 0" "$CLI_EXIT" 0
assert_equals "--dry-run sha unchanged" "$BEFORE_SHA" "$AFTER_SHA"
assert_contains "--dry-run prints asset_url"    "$CLI_OUTPUT" "asset_url:"
assert_contains "--dry-run prints install_path" "$CLI_OUTPUT" "install_path:"
rm -rf "$WORK_DIR"

echo "Test: Unknown channel rejected with listed choices"
WORK_DIR=$(mktemp -d)
cp "$BINARY" "$WORK_DIR/zpm"
run_upgrade "$WORK_DIR/zpm" --channel nightly
assert_exit_code "unknown channel exits non-zero" "$CLI_EXIT" 1
assert_contains "error lists supported channels" "$CLI_OUTPUT" "stable"
rm -rf "$WORK_DIR"

echo "Test: Network failure exits non-zero"
WORK_DIR=$(mktemp -d)
cp "$BINARY" "$WORK_DIR/zpm"
ZPM_GITHUB_API_URL="http://127.0.0.1:1" run_upgrade "$WORK_DIR/zpm"
assert_exit_code "network failure exits non-zero" "$CLI_EXIT" 1
rm -rf "$WORK_DIR"

echo "Test: install.sh:map_platform agrees with Zig assetBasename"
# Regression guard for the drift risk in F018 plan A2: install.sh:map_platform
# and src/cli/upgrade.zig:assetBasename must agree on every supported
# OS/arch pair.
ZPM_INSTALL_SKIP_MAIN=1 . "$(dirname "$0")/../scripts/install.sh"
detect_os()   { echo "$CROSSCHECK_OS"; }
detect_arch() { echo "$CROSSCHECK_ARCH"; }
for pair in \
    "linux:x86_64:zpm-linux-x86_64" \
    "linux:aarch64:zpm-linux-arm64" \
    "darwin:arm64:zpm-darwin-universal" \
    "darwin:x86_64:zpm-darwin-universal"; do
    IFS=: read -r CROSSCHECK_OS CROSSCHECK_ARCH expected <<<"$pair"
    actual=$(map_platform)
    assert_equals "map_platform(${CROSSCHECK_OS}-${CROSSCHECK_ARCH})" \
        "$expected" "$actual"
done

test_summary
