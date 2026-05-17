#!/usr/bin/env bash
# Feature: zig-cli reclaim refactor (refactor/reclaim-zig-cli)
# End-to-end CLI tests covering help, version, error paths, and tool dispatch.
. "$(dirname "$0")/test_helpers.sh"

BINARY="$(cd "$(dirname "${1:-zig-out/bin/zpm}")" && pwd)/$(basename "${1:-zig-out/bin/zpm}")"

# Track every temp dir so a Ctrl-C or set -e abort doesn't leak them.
TEMP_DIRS=()
cleanup_temp_dirs() {
    for d in "${TEMP_DIRS[@]}"; do
        rm -rf "$d"
    done
}
trap cleanup_temp_dirs EXIT

# Each tool subcommand needs a .zpm/ in $PWD or it bootstrap-fails. Use a
# fresh temp dir as PWD per tool invocation. We use pushd/popd (not a `( ... )`
# subshell) so $CLI_EXIT and $CLI_OUTPUT set by capture_cli propagate back to
# the parent shell where assertions run.
make_zpm_dir() {
    local d
    d=$(mktemp -d)
    mkdir -p "$d/.zpm/data" "$d/.zpm/kb"
    TEMP_DIRS+=("$d")
    echo "$d"
}

# Run capture_cli inside a fresh .zpm/-bootstrapped dir.
# Uses pushd/popd so CLI_EXIT and CLI_OUTPUT remain visible to the caller.
# Cleanup is handled by the EXIT trap on TEMP_DIRS.
capture_cli_in_zpm_dir() {
    local dir
    dir=$(make_zpm_dir)
    pushd "$dir" >/dev/null
    capture_cli "$@"
    popd >/dev/null
}

# --- Help and version ---

echo "Test: zpm with no args prints help (zig-cli exits 1)"
capture_cli
assert_exit_code "exit 1" "$CLI_EXIT" 1
assert_contains "shows COMMANDS section" "$CLI_OUTPUT" "COMMANDS"

echo "Test: zpm --help prints help"
capture_cli --help
assert_exit_code "exit 0" "$CLI_EXIT" 0
assert_contains "shows COMMANDS section" "$CLI_OUTPUT" "COMMANDS"

echo "Test: zpm version subcommand prints version"
capture_cli version
assert_exit_code "exit 0" "$CLI_EXIT" 0
assert_contains "version line begins with 'zpm '" "$CLI_OUTPUT" "zpm "
assert_contains "version line contains $ZPM_VERSION" "$CLI_OUTPUT" "$ZPM_VERSION"

# --- Subcommand error paths (zig-cli driven; stderr is silently dropped by a
#     known zig-cli flush bug, so we only assert exit codes here, not text). ---

echo "Test: unknown subcommand"
capture_cli bogus
assert_exit_code "exit 1" "$CLI_EXIT" 1

echo "Test: tool with missing required arg"
capture_cli_in_zpm_dir remember-fact
assert_exit_code "exit 1" "$CLI_EXIT" 1

echo "Test: tool with unknown flag"
capture_cli_in_zpm_dir remember-fact --fact 'foo(bar)' --bogus baz
assert_exit_code "exit 1" "$CLI_EXIT" 1

echo "Test: tool with invalid integer value"
capture_cli_in_zpm_dir explain-why --fact 'parent(tom, bob)' --max-depth abc
assert_exit_code "exit 1" "$CLI_EXIT" 1

# --- Upgrade flag parsing ---

echo "Test: upgrade --channel nightly is rejected (enum parser)"
capture_cli upgrade --channel nightly --dry-run
assert_exit_code "exit 1" "$CLI_EXIT" 1

# --- Tool happy path with positional + flag ---

echo "Test: define-rule with positional head + --body"
capture_cli_in_zpm_dir define-rule 'grandparent(X,Z)' --body 'parent(X,Y), parent(Y,Z)'
assert_exit_code "exit 0" "$CLI_EXIT" 0

echo "Test: assume-fact with positional fact + --assumption"
capture_cli_in_zpm_dir assume-fact 'hyp_test' --assumption a
assert_exit_code "exit 0" "$CLI_EXIT" 0

echo "Test: --format json on list-assumptions"
capture_cli_in_zpm_dir list-assumptions --format json
assert_exit_code "exit 0" "$CLI_EXIT" 0
# JSON output should start with { or [
case "$CLI_OUTPUT" in
    \{*|\[*) green "  PASS: JSON output begins with { or ["; PASS=$((PASS+1)) ;;
    *) red "  FAIL: JSON output does not begin with { or [: '$CLI_OUTPUT'"; FAIL=$((FAIL+1)) ;;
esac

# Feature: F021
# --- Memory management CLI tests ---

echo "Test: zpm memory create --name creates a named memory module (F021/US1)"
MEM_LIFECYCLE_DIR=$(make_zpm_dir)
pushd "$MEM_LIFECYCLE_DIR" >/dev/null
capture_cli memory create --name feature_auth
popd >/dev/null
assert_exit_code "zpm memory create exits 0" "$CLI_EXIT" 0

echo "Test: zpm memory list shows created memory (F021/US1)"
pushd "$MEM_LIFECYCLE_DIR" >/dev/null
capture_cli memory list
popd >/dev/null
assert_exit_code "zpm memory list exits 0" "$CLI_EXIT" 0
assert_contains "zpm memory list contains feature_auth" "$CLI_OUTPUT" "feature_auth"

echo "Test: zpm memory mount --name mounts a named memory module (F021/US1)"
pushd "$MEM_LIFECYCLE_DIR" >/dev/null
capture_cli memory mount --name feature_auth
popd >/dev/null
assert_exit_code "zpm memory mount exits 0" "$CLI_EXIT" 0

echo "Test: zpm remember-fact --memory targets named segment (F021/US2)"
pushd "$MEM_LIFECYCLE_DIR" >/dev/null
capture_cli remember-fact --fact 'task_done(login)' --memory feature_auth
popd >/dev/null
assert_exit_code "zpm remember-fact --memory exits 0" "$CLI_EXIT" 0

echo "Test: zpm query-logic --memory queries named segment (F021/US2)"
pushd "$MEM_LIFECYCLE_DIR" >/dev/null
capture_cli query-logic --goal 'task_done(X)' --memory feature_auth
popd >/dev/null
assert_exit_code "zpm query-logic --memory exits 0" "$CLI_EXIT" 0
assert_contains "zpm query-logic --memory returns binding" "$CLI_OUTPUT" "login"

echo "Test: zpm memory unmount --name unmounts a named memory module (F021/US1)"
pushd "$MEM_LIFECYCLE_DIR" >/dev/null
capture_cli memory unmount --name feature_auth
popd >/dev/null
assert_exit_code "zpm memory unmount exits 0" "$CLI_EXIT" 0

# Feature: F022
# --- Persistent mount manifest (.zpm/mounts.json) ---

echo "Test: mount mode survives CLI restart (F022/US1)"
F022_MODE_DIR=$(make_zpm_dir)
pushd "$F022_MODE_DIR" >/dev/null
"$BINARY" memory create --name ref_kb >/dev/null 2>&1 || true
"$BINARY" memory unmount --name ref_kb >/dev/null 2>&1 || true
"$BINARY" memory mount --name ref_kb --mode ro >/dev/null 2>&1 || true
capture_cli memory list
popd >/dev/null
assert_exit_code "memory list exits 0 after restart" "$CLI_EXIT" 0
assert_contains "ref_kb appears in memory list after restart" "$CLI_OUTPUT" "ref_kb"
assert_contains "ref_kb mode=ro preserved after restart" "$CLI_OUTPUT" "mode=ro"
MANIFEST_MODE=$(jq -r --arg n ref_kb '.mounts[] | select(.name == $n) | .mode' "$F022_MODE_DIR/.zpm/mounts.json")
assert_equals "manifest persists ro mode for ref_kb" "ro" "$MANIFEST_MODE"

echo "Test: unmount survives CLI restart, disk directory preserved (F022/US1, SC-002)"
F022_UNMOUNT_DIR=$(make_zpm_dir)
pushd "$F022_UNMOUNT_DIR" >/dev/null
"$BINARY" memory create --name temp_work >/dev/null 2>&1 || true
"$BINARY" memory unmount --name temp_work >/dev/null 2>&1 || true
capture_cli memory list
popd >/dev/null
assert_exit_code "memory list exits 0" "$CLI_EXIT" 0
assert_not_contains "temp_work absent from memory list after restart" "$CLI_OUTPUT" "temp_work"
assert_true "temp_work kb directory preserved on disk" test -d "$F022_UNMOUNT_DIR/.zpm/kb/temp_work"
MANIFEST_ENTRY=$(jq -r --arg n temp_work '.mounts[] | select(.name == $n) | .name' "$F022_UNMOUNT_DIR/.zpm/mounts.json")
assert_equals "manifest excludes unmounted temp_work" "" "$MANIFEST_ENTRY"

echo "Test: global-scope memory writes absolute manifest entry reachable from another cwd (F022/US2, SC-003)"
F022_GLOBAL_DIR=$(make_zpm_dir)
F022_XDG=$(mktemp -d)
TEMP_DIRS+=("$F022_XDG")
export XDG_DATA_HOME="$F022_XDG"
pushd "$F022_GLOBAL_DIR" >/dev/null
"$BINARY" memory create --name shared_xx --scope global >/dev/null 2>&1 || true
popd >/dev/null
GLOBAL_SCOPE=$(jq -r --arg n shared_xx '.mounts[] | select(.name == $n) | .scope' "$F022_GLOBAL_DIR/.zpm/mounts.json")
assert_equals "manifest entry scope is global" "global" "$GLOBAL_SCOPE"
GLOBAL_PATH=$(jq -r --arg n shared_xx '.mounts[] | select(.name == $n) | .path' "$F022_GLOBAL_DIR/.zpm/mounts.json")
case "$GLOBAL_PATH" in
    /*) green "  PASS: manifest entry path is absolute"; PASS=$((PASS+1)) ;;
    *)  red "  FAIL: manifest path is not absolute: '$GLOBAL_PATH'"; FAIL=$((FAIL+1)) ;;
esac
assert_contains "absolute path lives under XDG_DATA_HOME" "$GLOBAL_PATH" "$F022_XDG"
assert_true "global memory directory exists at absolute path" test -d "$GLOBAL_PATH"
F022_GLOBAL_DIR_B=$(make_zpm_dir)
SHARED_ENTRY_JSON=$(jq -c --arg n shared_xx '.mounts[] | select(.name == $n)' "$F022_GLOBAL_DIR/.zpm/mounts.json")
cat > "$F022_GLOBAL_DIR_B/.zpm/mounts.json" <<JSON
{"version": 1, "mounts": [{"name":"default","path":".zpm/kb/default","scope":"project","mode":"rw"}, $SHARED_ENTRY_JSON]}
JSON
pushd "$F022_GLOBAL_DIR_B" >/dev/null
capture_cli memory list
popd >/dev/null
assert_exit_code "memory list in second cwd exits 0" "$CLI_EXIT" 0
assert_contains "shared_xx is mounted from absolute path in second cwd" "$CLI_OUTPUT" "shared_xx"
unset XDG_DATA_HOME

echo "Test: first boot with no mounts.json generates one from kb/ scan (F022/US3, SC-004)"
F022_MIGRATE_DIR=$(make_zpm_dir)
mkdir -p "$F022_MIGRATE_DIR/.zpm/kb/feature_alpha" "$F022_MIGRATE_DIR/.zpm/kb/feature_beta"
assert_true "no mounts.json pre-boot" test ! -e "$F022_MIGRATE_DIR/.zpm/mounts.json"
pushd "$F022_MIGRATE_DIR" >/dev/null
capture_cli memory list
popd >/dev/null
assert_exit_code "memory list exits 0 on first boot" "$CLI_EXIT" 0
assert_true "mounts.json was created by migration" test -f "$F022_MIGRATE_DIR/.zpm/mounts.json"
for NAME in default feature_alpha feature_beta; do
    FOUND=$(jq -r --arg n "$NAME" '.mounts[] | select(.name == $n) | .name' "$F022_MIGRATE_DIR/.zpm/mounts.json")
    assert_equals "migrated manifest includes $NAME" "$NAME" "$FOUND"
done

# Feature: F022 — get-kb-overview CLI subcommand

echo "Test: zpm get-kb-overview CLI subcommand responds with valid JSON over STDIO"
capture_cli_in_zpm_dir get-kb-overview
assert_exit_code "exit 0" "$CLI_EXIT" 0
case "$CLI_OUTPUT" in
    \{*) green "  PASS: get-kb-overview output begins with {"; PASS=$((PASS+1)) ;;
    *) red "  FAIL: get-kb-overview output does not begin with {: '$CLI_OUTPUT'"; FAIL=$((FAIL+1)) ;;
esac
assert_contains "JSON contains predicates field" "$CLI_OUTPUT" '"predicates"'
assert_contains "JSON contains assumptions field" "$CLI_OUTPUT" '"assumptions"'
assert_contains "JSON contains truncated field" "$CLI_OUTPUT" '"truncated"'
assert_contains "JSON contains mounts field" "$CLI_OUTPUT" '"mounts"'

echo "Test: zpm get-kb-overview --sample-size 0 returns predicates with empty samples arrays and truncated: false"
KBO_SAMPLE_DIR=$(make_zpm_dir)
pushd "$KBO_SAMPLE_DIR" >/dev/null
capture_cli remember-fact --fact 'kbo_test_pred(a,b)'
capture_cli remember-fact --fact 'kbo_test_pred(c,d)'
capture_cli get-kb-overview --sample-size 0
popd >/dev/null
assert_exit_code "get-kb-overview --sample-size 0 exits 0" "$CLI_EXIT" 0
assert_contains "predicates include kbo_test_pred" "$CLI_OUTPUT" "kbo_test_pred"
assert_contains "samples arrays are empty" "$CLI_OUTPUT" '"samples":[]'
assert_contains "truncated is false" "$CLI_OUTPUT" '"truncated":false'

test_summary
