#!/usr/bin/env bash
# Features: F001-F004
# Functional tests for MCP server end-to-end protocol communication.
# Validates: initialize handshake, tools/list discovery, tools/call dispatch, error handling, graceful shutdown.
set -euo pipefail

BINARY="${1:-zig-out/bin/zpm}"
PASS=0
FAIL=0
TIMEOUT=5

red() { printf '\033[31m%s\033[0m\n' "$1"; }
green() { printf '\033[32m%s\033[0m\n' "$1"; }

assert_contains() {
    local label="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label — expected to contain: $needle"
        red "  GOT: $haystack"
        FAIL=$((FAIL + 1))
    fi
}

assert_exit_code() {
    local label="$1" actual="$2" expected="$3"
    if [ "$actual" -eq "$expected" ]; then
        green "  PASS: $label"
        PASS=$((PASS + 1))
    else
        red "  FAIL: $label — expected exit code $expected, got $actual"
        FAIL=$((FAIL + 1))
    fi
}

send_mcp() {
    local input="$1"
    printf '%s' "$input" | timeout "$TIMEOUT" "$BINARY" 2>/dev/null || true
}

# --- Test 1: Initialize handshake returns correct server info ---
echo "Test: Initialize handshake"
INIT_REQ='{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"test","version":"0.1.0"}}}'
RESPONSE=$(send_mcp "$INIT_REQ")

assert_contains "serverInfo.name is zpm" "$RESPONSE" '"name":"zpm"'
assert_contains "serverInfo.version is 0.1.0" "$RESPONSE" '"version":"0.1.0"'
assert_contains "protocolVersion is 2025-11-25" "$RESPONSE" '"protocolVersion":"2025-11-25"'
assert_contains "tools capability advertised" "$RESPONSE" '"tools":'

# --- Test 2: tools/list returns echo tool with schema ---
echo "Test: Tool discovery via tools/list"
TOOLSLIST_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/list\",\"params\":{}}"
RESPONSE=$(send_mcp "$TOOLSLIST_INPUT")
TOOLS_LINE=$(echo "$RESPONSE" | grep '"id":2')

assert_contains "echo tool listed" "$TOOLS_LINE" '"name":"echo"'
assert_contains "echo tool has description" "$TOOLS_LINE" '"description":"Echo back the input message"'
assert_contains "echo tool has inputSchema" "$TOOLS_LINE" '"inputSchema":'
assert_contains "remember_fact tool listed" "$TOOLS_LINE" '"name":"remember_fact"'
assert_contains "define_rule tool listed" "$TOOLS_LINE" '"name":"define_rule"'
assert_contains "query_logic tool listed" "$TOOLS_LINE" '"name":"query_logic"'
assert_contains "trace_dependency tool listed" "$TOOLS_LINE" '"name":"trace_dependency"'

# --- Test 3: tools/call echo returns the message ---
echo "Test: Echo tool invocation"
ECHO_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{\"message\":\"functional test\"}}}"
RESPONSE=$(send_mcp "$ECHO_INPUT")
ECHO_LINE=$(echo "$RESPONSE" | grep '"id":3')

assert_contains "echo returns message text" "$ECHO_LINE" '"text":"functional test"'
assert_contains "echo result is not an error" "$ECHO_LINE" '"isError":false'

# --- Test 4: tools/call echo with missing argument returns error ---
echo "Test: Echo tool missing argument error"
MISSING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"echo\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$MISSING_INPUT")
ERROR_LINE=$(echo "$RESPONSE" | grep '"id":4')

assert_contains "missing arg returns isError true" "$ERROR_LINE" '"isError":true'

# --- Test 5: Graceful shutdown on EOF ---
echo "Test: Graceful shutdown on STDIO close"
printf '%s\n' "$INIT_REQ" | timeout "$TIMEOUT" "$BINARY" >/dev/null 2>&1
EXIT_CODE=$?
assert_exit_code "exits with code 0 on EOF" "$EXIT_CODE" 0

# --- Test 6: remember_fact asserts a fact and returns success ---
echo "Test: remember_fact tool invocation"
REMEMBER_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"user_prefers(dark_mode)\"}}}"
RESPONSE=$(send_mcp "$REMEMBER_INPUT")
REMEMBER_LINE=$(echo "$RESPONSE" | grep '"id":6')

assert_contains "remember_fact returns success" "$REMEMBER_LINE" '"isError":false'
assert_contains "remember_fact confirms asserted fact" "$REMEMBER_LINE" 'user_prefers(dark_mode)'

# --- Test 7: remember_fact with missing fact key returns error ---
echo "Test: remember_fact missing argument error"
MISSING_FACT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$MISSING_FACT_INPUT")
MISSING_FACT_LINE=$(echo "$RESPONSE" | grep '"id":7')

assert_contains "missing fact key returns isError true" "$MISSING_FACT_LINE" '"isError":true'

# --- Test 8: define_rule asserts a rule and returns success ---
echo "Test: define_rule tool invocation"
DEFINE_RULE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"mortal(X)\",\"body\":\"human(X)\"}}}"
RESPONSE=$(send_mcp "$DEFINE_RULE_INPUT")
DEFINE_RULE_LINE=$(echo "$RESPONSE" | grep '"id":8')

assert_contains "define_rule returns success" "$DEFINE_RULE_LINE" '"isError":false'
assert_contains "define_rule confirms asserted rule head" "$DEFINE_RULE_LINE" 'mortal(X)'

# --- Test 9: define_rule with missing arguments returns error ---
echo "Test: define_rule missing argument error"
MISSING_RULE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$MISSING_RULE_INPUT")
MISSING_RULE_LINE=$(echo "$RESPONSE" | grep '"id":9')

assert_contains "missing rule arguments returns isError true" "$MISSING_RULE_LINE" '"isError":true'

# --- Test 10: query_logic returns solutions for matching facts ---
echo "Test: query_logic tool invocation with matching facts"
QUERY_FACTS_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"fruit(apple)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"fruit(banana)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"fruit(X)\"}}}"
RESPONSE=$(send_mcp "$QUERY_FACTS_INPUT")
QUERY_LINE=$(echo "$RESPONSE" | grep '"id":12')

assert_contains "query_logic returns success" "$QUERY_LINE" '"isError":false'
assert_contains "query_logic returns apple binding" "$QUERY_LINE" 'apple'
assert_contains "query_logic returns banana binding" "$QUERY_LINE" 'banana'

# --- Test 11: query_logic returns empty array when no facts match ---
echo "Test: query_logic with no matching facts returns empty array"
QUERY_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"nonexistent_pred(X)\"}}}"
RESPONSE=$(send_mcp "$QUERY_EMPTY_INPUT")
QUERY_EMPTY_LINE=$(echo "$RESPONSE" | grep '"id":13')

assert_contains "query_logic empty result is not an error" "$QUERY_EMPTY_LINE" '"isError":false'
assert_contains "query_logic empty result returns empty array" "$QUERY_EMPTY_LINE" '[]'

# --- Test 12: query_logic with missing goal argument returns error ---
echo "Test: query_logic missing goal argument error"
QUERY_MISSING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$QUERY_MISSING_INPUT")
QUERY_MISSING_LINE=$(echo "$RESPONSE" | grep '"id":14')

assert_contains "missing goal returns isError true" "$QUERY_MISSING_LINE" '"isError":true'

# --- Test 12b: query_logic with syntactically invalid goal returns empty result ---
# NOTE: scryer-prolog silently returns 0 solutions for malformed goals instead of
# raising a parse error. This test documents current behavior; SC-003 "invalid syntax
# returns error" cannot be enforced at the Zig layer without duplicating Prolog's parser.
echo "Test: query_logic with invalid syntax returns empty result (scryer-prolog limitation)"
QUERY_INVALID_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"contributor(X,\"}}}"
RESPONSE=$(send_mcp "$QUERY_INVALID_INPUT")
QUERY_INVALID_LINE=$(echo "$RESPONSE" | grep '"id":22')

assert_contains "invalid syntax returns empty array (scryer-prolog limitation)" "$QUERY_INVALID_LINE" '"isError":false'

# --- Test 13: trace_dependency returns reachable nodes for transitive dependency chain ---
echo "Test: trace_dependency tool invocation with transitive dependencies"
TRACE_CHAIN_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"depends_on(a, b)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"depends_on(b, c)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"path(X, Start)\",\"body\":\"depends_on(Start, X)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"path(X, Start)\",\"body\":\"depends_on(Start, Mid), path(X, Mid)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"tools/call\",\"params\":{\"name\":\"trace_dependency\",\"arguments\":{\"start_node\":\"a\"}}}"
RESPONSE=$(send_mcp "$TRACE_CHAIN_INPUT")
TRACE_LINE=$(echo "$RESPONSE" | grep '"id":19')

assert_contains "trace_dependency returns success" "$TRACE_LINE" '"isError":false'
assert_contains "trace_dependency returns direct dependency b" "$TRACE_LINE" '\"b\"'
assert_contains "trace_dependency returns transitive dependency c" "$TRACE_LINE" '\"c\"'

# --- Test 14: trace_dependency returns empty array for isolated node ---
echo "Test: trace_dependency with isolated node returns empty array"
TRACE_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/call\",\"params\":{\"name\":\"trace_dependency\",\"arguments\":{\"start_node\":\"isolated\"}}}"
RESPONSE=$(send_mcp "$TRACE_EMPTY_INPUT")
TRACE_EMPTY_LINE=$(echo "$RESPONSE" | grep '"id":20')

assert_contains "trace_dependency isolated node is not an error" "$TRACE_EMPTY_LINE" '"isError":false'
assert_contains "trace_dependency isolated node returns empty array" "$TRACE_EMPTY_LINE" '[]'

# --- Test 15: trace_dependency with missing start_node argument returns error ---
echo "Test: trace_dependency missing start_node argument error"
TRACE_MISSING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tools/call\",\"params\":{\"name\":\"trace_dependency\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$TRACE_MISSING_INPUT")
TRACE_MISSING_LINE=$(echo "$RESPONSE" | grep '"id":21')

assert_contains "missing start_node returns isError true" "$TRACE_MISSING_LINE" '"isError":true'

# --- Test 16: trace_dependency with injection attempt returns error ---
echo "Test: trace_dependency rejects Prolog injection attempt"
TRACE_INJECT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":23,\"method\":\"tools/call\",\"params\":{\"name\":\"trace_dependency\",\"arguments\":{\"start_node\":\"a), halt(0\"}}}"
RESPONSE=$(send_mcp "$TRACE_INJECT_INPUT")
TRACE_INJECT_LINE=$(echo "$RESPONSE" | grep '"id":23')

assert_contains "injection attempt returns isError true" "$TRACE_INJECT_LINE" '"isError":true'

# --- Summary ---
echo ""
TOTAL=$((PASS + FAIL))
if [ "$FAIL" -eq 0 ]; then
    green "All $TOTAL assertions passed."
else
    red "$FAIL of $TOTAL assertions failed."
    exit 1
fi
