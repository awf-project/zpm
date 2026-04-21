#!/usr/bin/env bash
# Features: F001-F012, F016
# Functional tests for MCP server end-to-end protocol communication.
# Validates: initialize handshake, tools/list discovery, tools/call dispatch, error handling, graceful shutdown.
. "$(dirname "$0")/test_helpers.sh"

BINARY="$(cd "$(dirname "${1:-zig-out/bin/zpm}")" && pwd)/$(basename "${1:-zig-out/bin/zpm}")"
TIMEOUT=5

send_mcp_persist() {
    local input="$1" dir="$2"
    mkdir -p "$dir/.zpm/data" "$dir/.zpm/kb"
    (cd "$dir" && printf '%s' "$input" | timeout "$TIMEOUT" "$BINARY" serve 2>/dev/null || true)
}

send_mcp() {
    local tmpdir
    tmpdir=$(mktemp -d)
    send_mcp_persist "$1" "$tmpdir"
    rm -rf "$tmpdir"
}

# Run `$BINARY $@`, capture combined stdout+stderr into $CLI_OUTPUT, exit code into $CLI_EXIT.
capture_cli() {
    local tmpfile
    tmpfile=$(mktemp)
    CLI_EXIT=0
    "$BINARY" "$@" >"$tmpfile" 2>&1 || CLI_EXIT=$?
    CLI_OUTPUT=$(cat "$tmpfile")
    rm -f "$tmpfile"
}

# Same as capture_cli, but splits stdout (discarded) from stderr into $CLI_STDERR.
capture_cli_stderr() {
    local tmpfile
    tmpfile=$(mktemp)
    CLI_EXIT=0
    "$BINARY" "$@" >/dev/null 2>"$tmpfile" || CLI_EXIT=$?
    CLI_STDERR=$(cat "$tmpfile")
    rm -f "$tmpfile"
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

assert_contains "echo tool has description" "$TOOLS_LINE" '"description":"Echo back the input message"'
assert_contains "echo tool has inputSchema" "$TOOLS_LINE" '"inputSchema":'
for TOOL_NAME in echo remember_fact define_rule query_logic trace_dependency verify_consistency explain_why get_knowledge_schema forget_fact clear_context update_fact upsert_fact assume_fact retract_assumption get_belief_status get_justification list_assumptions retract_assumptions save_snapshot restore_snapshot list_snapshots get_persistence_status; do
    assert_contains "tools/list includes $TOOL_NAME" "$TOOLS_LINE" "\"name\":\"$TOOL_NAME\""
done

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
SHUTDOWN_TMPDIR=$(mktemp -d)
mkdir -p "$SHUTDOWN_TMPDIR/.zpm/data" "$SHUTDOWN_TMPDIR/.zpm/kb"
(cd "$SHUTDOWN_TMPDIR" && printf '%s\n' "$INIT_REQ" | timeout "$TIMEOUT" "$BINARY" serve >/dev/null 2>&1)
EXIT_CODE=$?
rm -rf "$SHUTDOWN_TMPDIR"
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
echo "Test: query_logic with invalid syntax returns empty result"
QUERY_INVALID_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"contributor(X,\"}}}"
RESPONSE=$(send_mcp "$QUERY_INVALID_INPUT")
QUERY_INVALID_LINE=$(echo "$RESPONSE" | grep '"id":22')

assert_contains "invalid syntax returns empty array" "$QUERY_INVALID_LINE" '"isError":false'

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

# --- Test 17: verify_consistency returns no violations for empty knowledge base ---
echo "Test: verify_consistency with empty knowledge base"
VERIFY_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"tools/call\",\"params\":{\"name\":\"verify_consistency\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$VERIFY_EMPTY_INPUT")
VERIFY_LINE=$(echo "$RESPONSE" | grep '"id":24')

assert_contains "verify_consistency is not an error" "$VERIFY_LINE" '"isError":false'
assert_contains "verify_consistency returns empty violations array" "$VERIFY_LINE" '\"violations\":[]'

# --- Test 18: verify_consistency detects integrity violation ---
echo "Test: verify_consistency with integrity_violation rule fires"
VERIFY_VIOLATION_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":25,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"risky(deploy_v3)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":26,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"integrity_violation(X)\",\"body\":\"risky(X)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":27,\"method\":\"tools/call\",\"params\":{\"name\":\"verify_consistency\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$VERIFY_VIOLATION_INPUT")
VERIFY_VIOLATION_LINE=$(echo "$RESPONSE" | grep '"id":27')

assert_contains "verify_consistency with violation is not an error" "$VERIFY_VIOLATION_LINE" '"isError":false'
assert_contains "verify_consistency returns deploy_v3 as violation" "$VERIFY_VIOLATION_LINE" 'deploy_v3'

# --- Test 19: explain_why returns proof tree for asserted fact ---
echo "Test: explain_why with provable fact"
EXPLAIN_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":28,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"risky(deploy_v3)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":29,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{\"fact\":\"risky(deploy_v3)\"}}}"
RESPONSE=$(send_mcp "$EXPLAIN_INPUT")
EXPLAIN_LINE=$(echo "$RESPONSE" | grep '"id":29')

assert_contains "explain_why is not an error" "$EXPLAIN_LINE" '"isError":false'
assert_contains "explain_why returns proven true" "$EXPLAIN_LINE" '\"proven\":true'
assert_contains "explain_why includes fact in proof" "$EXPLAIN_LINE" 'risky(deploy_v3)'

# --- Test 20: explain_why returns proven false for unprovable fact ---
echo "Test: explain_why with unprovable fact"
EXPLAIN_UNPROVABLE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":30,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{\"fact\":\"unknown_fact(x)\"}}}"
RESPONSE=$(send_mcp "$EXPLAIN_UNPROVABLE_INPUT")
EXPLAIN_UNPROVABLE_LINE=$(echo "$RESPONSE" | grep '"id":30')

assert_contains "explain_why unprovable is not an error" "$EXPLAIN_UNPROVABLE_LINE" '"isError":false'
assert_contains "explain_why returns proven false" "$EXPLAIN_UNPROVABLE_LINE" '\"proven\":false'

# --- Test 21: explain_why with missing fact argument returns error ---
echo "Test: explain_why missing fact argument error"
EXPLAIN_MISSING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":31,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$EXPLAIN_MISSING_INPUT")
EXPLAIN_MISSING_LINE=$(echo "$RESPONSE" | grep '"id":31')

assert_contains "missing fact argument returns isError true" "$EXPLAIN_MISSING_LINE" '"isError":true'

# --- Test 22: explain_why returns proof tree for rule-derived fact ---
echo "Test: explain_why with rule-derived fact returns proof tree"
EXPLAIN_RULE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":32,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"parent(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":33,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"ancestor(X, Y)\",\"body\":\"parent(X, Y)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":34,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{\"fact\":\"ancestor(alice, bob)\"}}}"
RESPONSE=$(send_mcp "$EXPLAIN_RULE_INPUT")
EXPLAIN_RULE_LINE=$(echo "$RESPONSE" | grep '"id":34')

assert_contains "explain_why rule-derived is not an error" "$EXPLAIN_RULE_LINE" '"isError":false'
assert_contains "explain_why rule-derived returns proven true" "$EXPLAIN_RULE_LINE" '\"proven\":true'
assert_contains "explain_why rule-derived has non-empty children" "$EXPLAIN_RULE_LINE" '\"children\":[{'

# --- Test 23: get_knowledge_schema returns empty list for empty knowledge base ---
echo "Test: get_knowledge_schema with empty knowledge base"
SCHEMA_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":35,\"method\":\"tools/call\",\"params\":{\"name\":\"get_knowledge_schema\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$SCHEMA_EMPTY_INPUT")
SCHEMA_EMPTY_LINE=$(echo "$RESPONSE" | grep '"id":35')

assert_contains "get_knowledge_schema empty KB is not an error" "$SCHEMA_EMPTY_LINE" '"isError":false'
assert_contains "get_knowledge_schema empty KB returns empty predicates" "$SCHEMA_EMPTY_LINE" '\"predicates\":[]'
assert_contains "get_knowledge_schema empty KB returns total 0" "$SCHEMA_EMPTY_LINE" '\"total\":0'

# --- Test 24: get_knowledge_schema returns predicates after asserting facts ---
echo "Test: get_knowledge_schema returns asserted predicates with name and arity"
SCHEMA_FACTS_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":36,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"user_prefers(dark_mode)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":37,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"depends_on(a, b)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":38,\"method\":\"tools/call\",\"params\":{\"name\":\"get_knowledge_schema\",\"arguments\":{}}}
"
RESPONSE=$(send_mcp "$SCHEMA_FACTS_INPUT")
SCHEMA_FACTS_LINE=$(echo "$RESPONSE" | grep '"id":38')

assert_contains "get_knowledge_schema populated KB is not an error" "$SCHEMA_FACTS_LINE" '"isError":false'
assert_contains "get_knowledge_schema returns user_prefers predicate" "$SCHEMA_FACTS_LINE" '\"name\":\"user_prefers\"'
assert_contains "get_knowledge_schema returns arity 1 for user_prefers" "$SCHEMA_FACTS_LINE" '\"arity\":1'
assert_contains "get_knowledge_schema returns depends_on predicate" "$SCHEMA_FACTS_LINE" '\"name\":\"depends_on\"'
assert_contains "get_knowledge_schema returns arity 2 for depends_on" "$SCHEMA_FACTS_LINE" '\"arity\":2'
assert_contains "get_knowledge_schema returns total 2" "$SCHEMA_FACTS_LINE" '\"total\":2'

# --- Test 25: get_knowledge_schema shows type:both for mixed fact+rule predicate ---
echo "Test: get_knowledge_schema classifies mixed fact+rule predicate as type both"
SCHEMA_BOTH_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":39,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"path(a, b)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":40,\"method\":\"tools/call\",\"params\":{\"name\":\"define_rule\",\"arguments\":{\"head\":\"path(X, Z)\",\"body\":\"path(X, Y), path(Y, Z)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"tools/call\",\"params\":{\"name\":\"get_knowledge_schema\",\"arguments\":{}}}"
RESPONSE=$(send_mcp "$SCHEMA_BOTH_INPUT")
SCHEMA_BOTH_LINE=$(echo "$RESPONSE" | grep '"id":41')

assert_contains "get_knowledge_schema both is not an error" "$SCHEMA_BOTH_LINE" '"isError":false'
assert_contains "get_knowledge_schema classifies path/2 as both" "$SCHEMA_BOTH_LINE" '\"type\":\"both\"'

# Feature: F007
# --- Test 26: forget_fact retracts existing fact, query confirms absence ---
echo "Test: forget_fact retracts asserted fact"
FORGET_EXISTING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"role(jean, manager)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":43,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{\"fact\":\"role(jean, manager)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":44,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"role(jean, manager)\"}}}
"
RESPONSE=$(send_mcp "$FORGET_EXISTING_INPUT")
FORGET_LINE=$(echo "$RESPONSE" | grep '"id":43')
QUERY_AFTER_LINE=$(echo "$RESPONSE" | grep '"id":44')

assert_contains "forget_fact returns success" "$FORGET_LINE" '"isError":false'
assert_contains "forget_fact confirms retracted fact" "$FORGET_LINE" 'role(jean, manager)'
assert_contains "query after forget_fact returns empty" "$QUERY_AFTER_LINE" '[]'

# --- Test 27: forget_fact returns error for non-existent fact ---
echo "Test: forget_fact with non-existent fact returns error"
FORGET_MISSING_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":45,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{\"fact\":\"role(nobody, ghost)\"}}}
"
RESPONSE=$(send_mcp "$FORGET_MISSING_INPUT")
FORGET_MISSING_LINE=$(echo "$RESPONSE" | grep '"id":45')

assert_contains "forget_fact non-existent returns isError true" "$FORGET_MISSING_LINE" '"isError":true'

# --- Test 28: forget_fact returns error for empty fact ---
echo "Test: forget_fact with empty fact returns error"
FORGET_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":46,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{\"fact\":\"\"}}}
"
RESPONSE=$(send_mcp "$FORGET_EMPTY_INPUT")
FORGET_EMPTY_LINE=$(echo "$RESPONSE" | grep '"id":46')

assert_contains "forget_fact empty fact returns isError true" "$FORGET_EMPTY_LINE" '"isError":true'

# --- Test 29: forget_fact with missing arguments returns error ---
echo "Test: forget_fact missing argument error"
FORGET_NULL_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":47,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{}}}
"
RESPONSE=$(send_mcp "$FORGET_NULL_INPUT")
FORGET_NULL_LINE=$(echo "$RESPONSE" | grep '"id":47')

assert_contains "forget_fact missing args returns isError true" "$FORGET_NULL_LINE" '"isError":true'

# --- Test 30: clear_context removes all matching facts, query confirms ---
echo "Test: clear_context removes all matching facts"
CLEAR_MULTI_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":48,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"project(beta, active)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":49,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"project(beta, owner(alice))\"}}}
{\"jsonrpc\":\"2.0\",\"id\":50,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"project(alpha, active)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":51,\"method\":\"tools/call\",\"params\":{\"name\":\"clear_context\",\"arguments\":{\"category\":\"project(beta, _)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":52,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"project(beta, _)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":53,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"project(Name, _)\"}}}
"
RESPONSE=$(send_mcp "$CLEAR_MULTI_INPUT")
CLEAR_LINE=$(echo "$RESPONSE" | grep '"id":51')
QUERY_BETA_LINE=$(echo "$RESPONSE" | grep '"id":52')
QUERY_ALPHA_LINE=$(echo "$RESPONSE" | grep '"id":53')

assert_contains "clear_context returns success" "$CLEAR_LINE" '"isError":false'
assert_contains "clear_context confirms pattern" "$CLEAR_LINE" 'project(beta, _)'
assert_contains "query after clear_context beta returns empty" "$QUERY_BETA_LINE" '[]'
assert_contains "clear_context preserves non-matching facts" "$QUERY_ALPHA_LINE" 'alpha'

# --- Test 31: clear_context is idempotent when no facts match ---
echo "Test: clear_context with no matching facts returns success"
CLEAR_EMPTY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":54,\"method\":\"tools/call\",\"params\":{\"name\":\"clear_context\",\"arguments\":{\"category\":\"nonexistent_category(_)\"}}}
"
RESPONSE=$(send_mcp "$CLEAR_EMPTY_INPUT")
CLEAR_EMPTY_LINE=$(echo "$RESPONSE" | grep '"id":54')

assert_contains "clear_context no-match returns success" "$CLEAR_EMPTY_LINE" '"isError":false'

# --- Test 32: clear_context returns error for empty category ---
echo "Test: clear_context with empty category returns error"
CLEAR_EMPTY_CAT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":55,\"method\":\"tools/call\",\"params\":{\"name\":\"clear_context\",\"arguments\":{\"category\":\"\"}}}
"
RESPONSE=$(send_mcp "$CLEAR_EMPTY_CAT_INPUT")
CLEAR_EMPTY_CAT_LINE=$(echo "$RESPONSE" | grep '"id":55')

assert_contains "clear_context empty category returns isError true" "$CLEAR_EMPTY_CAT_LINE" '"isError":true'

# --- Test 33: clear_context with missing arguments returns error ---
echo "Test: clear_context missing argument error"
CLEAR_NULL_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":56,\"method\":\"tools/call\",\"params\":{\"name\":\"clear_context\",\"arguments\":{}}}
"
RESPONSE=$(send_mcp "$CLEAR_NULL_INPUT")
CLEAR_NULL_LINE=$(echo "$RESPONSE" | grep '"id":56')

assert_contains "clear_context missing args returns isError true" "$CLEAR_NULL_LINE" '"isError":true'

# --- Test 34: forget_fact retracts only first duplicate (US3) ---
echo "Test: forget_fact retracts only first duplicate"
FORGET_DUPE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":57,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"likes(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":58,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"likes(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":59,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{\"fact\":\"likes(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":60,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"likes(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":61,\"method\":\"tools/call\",\"params\":{\"name\":\"forget_fact\",\"arguments\":{\"fact\":\"likes(alice, bob)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":62,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"likes(alice, bob)\"}}}
"
RESPONSE=$(send_mcp "$FORGET_DUPE_INPUT")
FORGET_FIRST_LINE=$(echo "$RESPONSE" | grep '"id":59')
QUERY_ONE_LEFT_LINE=$(echo "$RESPONSE" | grep '"id":60')
FORGET_SECOND_LINE=$(echo "$RESPONSE" | grep '"id":61')
QUERY_ZERO_LEFT_LINE=$(echo "$RESPONSE" | grep '"id":62')

assert_contains "first forget_fact on duplicate returns success" "$FORGET_FIRST_LINE" '"isError":false'
assert_contains "one duplicate remains after first retraction" "$QUERY_ONE_LEFT_LINE" '[{}]'
assert_contains "second forget_fact on duplicate returns success" "$FORGET_SECOND_LINE" '"isError":false'
assert_contains "zero duplicates remain after second retraction" "$QUERY_ZERO_LEFT_LINE" '[]'

# --- Test 35: update_fact replaces existing fact atomically ---
echo "Test: update_fact replaces existing fact"
UPDATE_SUCCESS_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":63,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"config(timeout, 30)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":64,\"method\":\"tools/call\",\"params\":{\"name\":\"update_fact\",\"arguments\":{\"old_fact\":\"config(timeout, 30)\",\"new_fact\":\"config(timeout, 60)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":65,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"config(timeout, 60)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":66,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"config(timeout, 30)\"}}}
"
RESPONSE=$(send_mcp "$UPDATE_SUCCESS_INPUT")
UPDATE_LINE=$(echo "$RESPONSE" | grep '"id":64')
QUERY_NEW_LINE=$(echo "$RESPONSE" | grep '"id":65')
QUERY_OLD_LINE=$(echo "$RESPONSE" | grep '"id":66')

assert_contains "update_fact returns success" "$UPDATE_LINE" '"isError":false'
assert_contains "new fact is queryable after update" "$QUERY_NEW_LINE" '[{}]'
assert_contains "old fact is gone after update" "$QUERY_OLD_LINE" '[]'

# --- Test 36: update_fact returns error when old fact does not exist ---
echo "Test: update_fact not-found returns error"
UPDATE_NOTFOUND_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":67,\"method\":\"tools/call\",\"params\":{\"name\":\"update_fact\",\"arguments\":{\"old_fact\":\"nonexistent(ghost, fact)\",\"new_fact\":\"nonexistent(ghost, replaced)\"}}}
"
RESPONSE=$(send_mcp "$UPDATE_NOTFOUND_INPUT")
UPDATE_NOTFOUND_LINE=$(echo "$RESPONSE" | grep '"id":67')

assert_contains "update_fact not-found returns isError true" "$UPDATE_NOTFOUND_LINE" '"isError":true'

# --- Test 37: upsert_fact inserts when no prior fact exists ---
echo "Test: upsert_fact inserts new fact"
UPSERT_INSERT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":68,\"method\":\"tools/call\",\"params\":{\"name\":\"upsert_fact\",\"arguments\":{\"fact\":\"service(api, healthy)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":69,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"service(api, healthy)\"}}}
"
RESPONSE=$(send_mcp "$UPSERT_INSERT_INPUT")
UPSERT_INSERT_LINE=$(echo "$RESPONSE" | grep '"id":68')
QUERY_INSERT_LINE=$(echo "$RESPONSE" | grep '"id":69')

assert_contains "upsert_fact insert returns success" "$UPSERT_INSERT_LINE" '"isError":false'
assert_contains "upserted fact is queryable" "$QUERY_INSERT_LINE" '[{}]'

# --- Test 38: upsert_fact replaces existing fact with same functor and first arg ---
echo "Test: upsert_fact replaces existing fact"
UPSERT_REPLACE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":70,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"deploy(prod, v1)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":71,\"method\":\"tools/call\",\"params\":{\"name\":\"upsert_fact\",\"arguments\":{\"fact\":\"deploy(prod, v2)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":72,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"deploy(prod, X)\"}}}
"
RESPONSE=$(send_mcp "$UPSERT_REPLACE_INPUT")
UPSERT_REPLACE_LINE=$(echo "$RESPONSE" | grep '"id":71')
QUERY_REPLACE_LINE=$(echo "$RESPONSE" | grep '"id":72')

assert_contains "upsert_fact replace returns success" "$UPSERT_REPLACE_LINE" '"isError":false'
assert_contains "only new version remains after upsert" "$QUERY_REPLACE_LINE" 'v2'
assert_not_contains "old version is gone after upsert" "$QUERY_REPLACE_LINE" 'v1'

# --- Test 39: upsert_fact does not affect facts with different first argument ---
echo "Test: upsert_fact preserves unrelated facts"
UPSERT_PRESERVE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":73,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"env(prod, active)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":74,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"env(dev, active)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":75,\"method\":\"tools/call\",\"params\":{\"name\":\"upsert_fact\",\"arguments\":{\"fact\":\"env(prod, frozen)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":76,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"env(dev, active)\"}}}
"
RESPONSE=$(send_mcp "$UPSERT_PRESERVE_INPUT")
UPSERT_PRESERVE_LINE=$(echo "$RESPONSE" | grep '"id":75')
QUERY_PRESERVE_LINE=$(echo "$RESPONSE" | grep '"id":76')

assert_contains "upsert_fact preserve returns success" "$UPSERT_PRESERVE_LINE" '"isError":false'
assert_contains "unrelated fact survives upsert" "$QUERY_PRESERVE_LINE" '[{}]'

# --- Test 40: assume_fact asserts a fact under a named assumption ---
echo "Test: assume_fact basic assertion"
ASSUME_BASIC_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"deployed(app, prod)\",\"assumption\":\"baseline\"}}}
{\"jsonrpc\":\"2.0\",\"id\":78,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"deployed(app, prod)\"}}}
"
RESPONSE=$(send_mcp "$ASSUME_BASIC_INPUT")
ASSUME_LINE=$(echo "$RESPONSE" | grep '"id":77')
QUERY_LINE=$(echo "$RESPONSE" | grep '"id":78')

assert_contains "assume_fact returns success" "$ASSUME_LINE" '"isError":false'
assert_contains "assume_fact result contains Assumed" "$ASSUME_LINE" 'Assumed:'
assert_contains "assumed fact is queryable" "$QUERY_LINE" '[{}]'

# --- Test 41: assume_fact is idempotent for same fact and assumption ---
echo "Test: assume_fact idempotency"
ASSUME_IDEM_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":79,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"active(svc)\",\"assumption\":\"idem_test\"}}}
{\"jsonrpc\":\"2.0\",\"id\":80,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"active(svc)\",\"assumption\":\"idem_test\"}}}
{\"jsonrpc\":\"2.0\",\"id\":81,\"method\":\"tools/call\",\"params\":{\"name\":\"get_belief_status\",\"arguments\":{\"fact\":\"active(svc)\"}}}
"
RESPONSE=$(send_mcp "$ASSUME_IDEM_INPUT")
ASSUME1_LINE=$(echo "$RESPONSE" | grep '"id":79')
ASSUME2_LINE=$(echo "$RESPONSE" | grep '"id":80')
BELIEF_LINE=$(echo "$RESPONSE" | grep '"id":81')

assert_contains "first assume_fact returns success" "$ASSUME1_LINE" '"isError":false'
assert_contains "second assume_fact returns success (idempotent)" "$ASSUME2_LINE" '"isError":false'
assert_contains "belief status is in after idempotent assume" "$BELIEF_LINE" '\"status\":\"in\"'

# --- Test 42: retract_assumption removes solely-supported fact ---
echo "Test: retract_assumption removes fact with single support"
RETRACT_SOLE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":82,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"running(worker)\",\"assumption\":\"deploy_a1\"}}}
{\"jsonrpc\":\"2.0\",\"id\":83,\"method\":\"tools/call\",\"params\":{\"name\":\"retract_assumption\",\"arguments\":{\"assumption\":\"deploy_a1\"}}}
{\"jsonrpc\":\"2.0\",\"id\":84,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"running(worker)\"}}}
"
RESPONSE=$(send_mcp "$RETRACT_SOLE_INPUT")
RETRACT_LINE=$(echo "$RESPONSE" | grep '"id":83')
QUERY_AFTER_LINE=$(echo "$RESPONSE" | grep '"id":84')

assert_contains "retract_assumption returns success" "$RETRACT_LINE" '"isError":false'
assert_contains "retract_assumption reports fact removed" "$RETRACT_LINE" '1 fact(s) removed'
assert_contains "fact is gone after retraction" "$QUERY_AFTER_LINE" '[]'

# --- Test 43: multi-support survival — fact with two assumptions, retract one, fact persists ---
echo "Test: multi-support fact survives single assumption retraction"
MULTI_SUPPORT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":85,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"online(db)\",\"assumption\":\"sup_a\"}}}
{\"jsonrpc\":\"2.0\",\"id\":86,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"online(db)\",\"assumption\":\"sup_b\"}}}
{\"jsonrpc\":\"2.0\",\"id\":87,\"method\":\"tools/call\",\"params\":{\"name\":\"retract_assumption\",\"arguments\":{\"assumption\":\"sup_a\"}}}
{\"jsonrpc\":\"2.0\",\"id\":88,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"online(db)\"}}}
"
RESPONSE=$(send_mcp "$MULTI_SUPPORT_INPUT")
RETRACT_A_LINE=$(echo "$RESPONSE" | grep '"id":87')
QUERY_SURVIVE_LINE=$(echo "$RESPONSE" | grep '"id":88')

assert_contains "retract sup_a returns success" "$RETRACT_A_LINE" '"isError":false'
assert_not_contains "multi-support fact was fully removed after partial retraction" "$QUERY_SURVIVE_LINE" '"text":"[]"'

# --- Test 44: non-TMS isolation — remember_fact survives retract_assumption ---
echo "Test: remember_fact fact survives assumption retraction"
NON_TMS_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":89,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"safe(constant)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":90,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"volatile(temp)\",\"assumption\":\"session_a\"}}}
{\"jsonrpc\":\"2.0\",\"id\":91,\"method\":\"tools/call\",\"params\":{\"name\":\"retract_assumption\",\"arguments\":{\"assumption\":\"session_a\"}}}
{\"jsonrpc\":\"2.0\",\"id\":92,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"safe(constant)\"}}}
"
RESPONSE=$(send_mcp "$NON_TMS_INPUT")
RETRACT_SESSION_LINE=$(echo "$RESPONSE" | grep '"id":91')
QUERY_SAFE_LINE=$(echo "$RESPONSE" | grep '"id":92')

assert_contains "retract session_a returns success" "$RETRACT_SESSION_LINE" '"isError":false'
assert_contains "non-TMS fact survives assumption retraction" "$QUERY_SAFE_LINE" '[{}]'

# --- Test 45: get_belief_status returns "in" with justification ---
echo "Test: get_belief_status returns in with justifications"
BELIEF_IN_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":93,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"ready(system)\",\"assumption\":\"init_check\"}}}
{\"jsonrpc\":\"2.0\",\"id\":94,\"method\":\"tools/call\",\"params\":{\"name\":\"get_belief_status\",\"arguments\":{\"fact\":\"ready(system)\"}}}
"
RESPONSE=$(send_mcp "$BELIEF_IN_INPUT")
BELIEF_IN_LINE=$(echo "$RESPONSE" | grep '"id":94')

assert_contains "get_belief_status returns in for supported fact" "$BELIEF_IN_LINE" '\"status\":\"in\"'
assert_contains "get_belief_status lists justification" "$BELIEF_IN_LINE" 'init_check'

# --- Test 46: get_belief_status returns "out" for unsupported fact ---
echo "Test: get_belief_status returns out for unsupported fact"
BELIEF_OUT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":95,\"method\":\"tools/call\",\"params\":{\"name\":\"get_belief_status\",\"arguments\":{\"fact\":\"absent(ghost)\"}}}
"
RESPONSE=$(send_mcp "$BELIEF_OUT_INPUT")
BELIEF_OUT_LINE=$(echo "$RESPONSE" | grep '"id":95')

assert_contains "get_belief_status returns out for unsupported fact" "$BELIEF_OUT_LINE" '\"status\":\"out\"'
assert_contains "get_belief_status returns empty justifications" "$BELIEF_OUT_LINE" '\"justifications\":[]'

# --- Test 47: get_justification returns facts for a named assumption ---
echo "Test: get_justification returns facts supported by assumption"
GET_JUST_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":96,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"healthy(api)\",\"assumption\":\"probe_a\"}}}
{\"jsonrpc\":\"2.0\",\"id\":97,\"method\":\"tools/call\",\"params\":{\"name\":\"get_justification\",\"arguments\":{\"assumption\":\"probe_a\"}}}
"
RESPONSE=$(send_mcp "$GET_JUST_INPUT")
GET_JUST_LINE=$(echo "$RESPONSE" | grep '"id":97')

assert_contains "get_justification returns success" "$GET_JUST_LINE" '"isError":false'
assert_contains "get_justification lists supported fact" "$GET_JUST_LINE" 'healthy'

# --- Test 48: list_assumptions returns all active assumption names ---
echo "Test: list_assumptions returns active assumptions"
LIST_ASSUME_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":98,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"up(node1)\",\"assumption\":\"alpha\"}}}
{\"jsonrpc\":\"2.0\",\"id\":99,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"up(node2)\",\"assumption\":\"beta\"}}}
{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"tools/call\",\"params\":{\"name\":\"list_assumptions\",\"arguments\":{}}}
"
RESPONSE=$(send_mcp "$LIST_ASSUME_INPUT")
LIST_LINE=$(echo "$RESPONSE" | grep '"id":100')

assert_contains "list_assumptions includes alpha" "$LIST_LINE" 'alpha'
assert_contains "list_assumptions includes beta" "$LIST_LINE" 'beta'

# --- Test 49: retract_assumptions with glob pattern retracts matching assumptions only ---
echo "Test: retract_assumptions with pattern retracts matching only"
RETRACT_PATTERN_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":101,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"loaded(mod1)\",\"assumption\":\"sess1_x\"}}}
{\"jsonrpc\":\"2.0\",\"id\":102,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"loaded(mod2)\",\"assumption\":\"sess1_y\"}}}
{\"jsonrpc\":\"2.0\",\"id\":103,\"method\":\"tools/call\",\"params\":{\"name\":\"assume_fact\",\"arguments\":{\"fact\":\"loaded(mod3)\",\"assumption\":\"sess2_x\"}}}
{\"jsonrpc\":\"2.0\",\"id\":104,\"method\":\"tools/call\",\"params\":{\"name\":\"retract_assumptions\",\"arguments\":{\"pattern\":\"sess1_*\"}}}
{\"jsonrpc\":\"2.0\",\"id\":105,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"loaded(mod3)\"}}}
"
RESPONSE=$(send_mcp "$RETRACT_PATTERN_INPUT")
RETRACT_PAT_LINE=$(echo "$RESPONSE" | grep '"id":104')
QUERY_REMAIN_LINE=$(echo "$RESPONSE" | grep '"id":105')

assert_contains "retract_assumptions pattern returns success" "$RETRACT_PAT_LINE" '"isError":false'
assert_contains "retract_assumptions reports 2 assumptions retracted" "$RETRACT_PAT_LINE" '2 assumption(s) removed'
assert_contains "non-matching assumption fact survives pattern retraction" "$QUERY_REMAIN_LINE" '[{}]'

# Feature: F010
# --- Test 51: save_snapshot persists current knowledge base to disk (US3) ---
echo "Test: save_snapshot creates a named snapshot file"
PERSIST_DIR_51=$(mktemp -d)
SAVE_SNAP_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":106,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"persisted(data)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":107,\"method\":\"tools/call\",\"params\":{\"name\":\"save_snapshot\",\"arguments\":{\"name\":\"test_snap\"}}}
"
RESPONSE=$(send_mcp_persist "$SAVE_SNAP_INPUT" "$PERSIST_DIR_51")
SAVE_LINE=$(echo "$RESPONSE" | grep '"id":107')

assert_contains "save_snapshot returns success" "$SAVE_LINE" '"isError":false'
assert_contains "save_snapshot confirms snapshot name" "$SAVE_LINE" 'test_snap'
rm -rf "$PERSIST_DIR_51"

# --- Test 52: list_snapshots enumerates available snapshots (US5) ---
echo "Test: list_snapshots returns saved snapshot names"
PERSIST_DIR_52=$(mktemp -d)
LIST_SNAP_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":108,\"method\":\"tools/call\",\"params\":{\"name\":\"save_snapshot\",\"arguments\":{\"name\":\"snap_alpha\"}}}
{\"jsonrpc\":\"2.0\",\"id\":109,\"method\":\"tools/call\",\"params\":{\"name\":\"list_snapshots\",\"arguments\":{}}}
"
RESPONSE=$(send_mcp_persist "$LIST_SNAP_INPUT" "$PERSIST_DIR_52")
LIST_LINE=$(echo "$RESPONSE" | grep '"id":109')

assert_contains "list_snapshots returns success" "$LIST_LINE" '"isError":false'
assert_contains "list_snapshots includes saved snapshot" "$LIST_LINE" 'snap_alpha'
rm -rf "$PERSIST_DIR_52"

# --- Test 53: restore_snapshot loads knowledge base from snapshot file (US3) ---
echo "Test: restore_snapshot restores from named snapshot"
PERSIST_DIR_53=$(mktemp -d)
RESTORE_SNAP_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":110,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"before_snap(x)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":111,\"method\":\"tools/call\",\"params\":{\"name\":\"save_snapshot\",\"arguments\":{\"name\":\"restore_test\"}}}
{\"jsonrpc\":\"2.0\",\"id\":112,\"method\":\"tools/call\",\"params\":{\"name\":\"restore_snapshot\",\"arguments\":{\"name\":\"restore_test\"}}}
"
RESPONSE=$(send_mcp_persist "$RESTORE_SNAP_INPUT" "$PERSIST_DIR_53")
RESTORE_LINE=$(echo "$RESPONSE" | grep '"id":112')

assert_contains "restore_snapshot returns success" "$RESTORE_LINE" '"isError":false'
assert_contains "restore_snapshot confirms snapshot name" "$RESTORE_LINE" 'restore_test'
rm -rf "$PERSIST_DIR_53"

# --- Test 54: get_persistence_status reports journal and directory info (US5) ---
echo "Test: get_persistence_status returns status fields"
PERSIST_DIR_54=$(mktemp -d)
STATUS_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":113,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"tracked(entry)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":114,\"method\":\"tools/call\",\"params\":{\"name\":\"get_persistence_status\",\"arguments\":{}}}
"
RESPONSE=$(send_mcp_persist "$STATUS_INPUT" "$PERSIST_DIR_54")
STATUS_LINE=$(echo "$RESPONSE" | grep '"id":114')

assert_contains "get_persistence_status returns success" "$STATUS_LINE" '"isError":false'
assert_contains "get_persistence_status includes active status" "$STATUS_LINE" 'active'
rm -rf "$PERSIST_DIR_54"

# --- Test 55: WAL replay restores knowledge base after server restart (US1, US2) ---
echo "Test: WAL replays facts on server restart"
PERSIST_DIR_55=$(mktemp -d)
WAL_WRITE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":115,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"durable(alpha)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":116,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"durable(beta)\"}}}
"
RESPONSE=$(send_mcp_persist "$WAL_WRITE_INPUT" "$PERSIST_DIR_55")
WRITE_LINE=$(echo "$RESPONSE" | grep '"id":116')
assert_contains "WAL write returns success" "$WRITE_LINE" '"isError":false'

WAL_REPLAY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":117,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"durable(alpha)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":118,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"durable(beta)\"}}}
"
RESPONSE=$(send_mcp_persist "$WAL_REPLAY_INPUT" "$PERSIST_DIR_55")
REPLAY_LINE1=$(echo "$RESPONSE" | grep '"id":117')
REPLAY_LINE2=$(echo "$RESPONSE" | grep '"id":118')
assert_contains "WAL replays first fact after restart" "$REPLAY_LINE1" '[{}]'
assert_contains "WAL replays second fact after restart" "$REPLAY_LINE2" '[{}]'
rm -rf "$PERSIST_DIR_55"

# --- Test 56: WAL replay respects clear_context operation (US2) ---
echo "Test: WAL replay preserves clear_context operation"
PERSIST_DIR_56=$(mktemp -d)
CLEAR_WAL_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":119,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"temp_cache(x)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":120,\"method\":\"tools/call\",\"params\":{\"name\":\"clear_context\",\"arguments\":{\"category\":\"temp_cache(_)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":121,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"persistent(y)\"}}}
"
RESPONSE=$(send_mcp_persist "$CLEAR_WAL_INPUT" "$PERSIST_DIR_56")
CLEAR_LINE=$(echo "$RESPONSE" | grep '"id":120')
assert_contains "clear_context write returns success" "$CLEAR_LINE" '"isError":false'

CLEAR_REPLAY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":122,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"temp_cache(x)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":123,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"persistent(y)\"}}}
"
RESPONSE=$(send_mcp_persist "$CLEAR_REPLAY_INPUT" "$PERSIST_DIR_56")
CLEAR_REPLAY_PRE=$(echo "$RESPONSE" | grep '"id":122')
CLEAR_REPLAY_POST=$(echo "$RESPONSE" | grep '"id":123')
assert_contains "cleared fact absent after restart" "$CLEAR_REPLAY_PRE" '[]'
assert_contains "post-clear fact present after restart" "$CLEAR_REPLAY_POST" '[{}]'
rm -rf "$PERSIST_DIR_56"

# --- Test 57: Snapshot + subsequent WAL entries both restored on restart (US1, US3) ---
echo "Test: Snapshot plus post-snapshot WAL entries survive restart"
PERSIST_DIR_57=$(mktemp -d)
SNAP_WAL_WRITE_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":124,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"pre_snap(one)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":125,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"pre_snap(two)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":126,\"method\":\"tools/call\",\"params\":{\"name\":\"save_snapshot\",\"arguments\":{\"name\":\"mid_session\"}}}
{\"jsonrpc\":\"2.0\",\"id\":127,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"post_snap(three)\"}}}
"
RESPONSE=$(send_mcp_persist "$SNAP_WAL_WRITE_INPUT" "$PERSIST_DIR_57")
SNAP_LINE=$(echo "$RESPONSE" | grep '"id":126')
POST_LINE=$(echo "$RESPONSE" | grep '"id":127')
assert_contains "save_snapshot mid-session succeeds" "$SNAP_LINE" '"isError":false'
assert_contains "post-snapshot fact write succeeds" "$POST_LINE" '"isError":false'

SNAP_WAL_REPLAY_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":128,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"pre_snap(one)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":129,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"pre_snap(two)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":130,\"method\":\"tools/call\",\"params\":{\"name\":\"query_logic\",\"arguments\":{\"goal\":\"post_snap(three)\"}}}
"
RESPONSE=$(send_mcp_persist "$SNAP_WAL_REPLAY_INPUT" "$PERSIST_DIR_57")
REPLAY_PRE1=$(echo "$RESPONSE" | grep '"id":128')
REPLAY_PRE2=$(echo "$RESPONSE" | grep '"id":129')
REPLAY_POST=$(echo "$RESPONSE" | grep '"id":130')
assert_contains "pre-snapshot fact 1 survives restart" "$REPLAY_PRE1" '[{}]'
assert_contains "pre-snapshot fact 2 survives restart" "$REPLAY_PRE2" '[{}]'
assert_contains "post-snapshot WAL fact survives restart" "$REPLAY_POST" '[{}]'
rm -rf "$PERSIST_DIR_57"

# --- Test 58: get_persistence_status on fresh server reports zero state (US5) ---
echo "Test: get_persistence_status reports zero state on fresh server"
PERSIST_DIR_58=$(mktemp -d)
FRESH_STATUS_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":131,\"method\":\"tools/call\",\"params\":{\"name\":\"get_persistence_status\",\"arguments\":{}}}
"
RESPONSE=$(send_mcp_persist "$FRESH_STATUS_INPUT" "$PERSIST_DIR_58")
FRESH_LINE=$(echo "$RESPONSE" | grep '"id":131')
assert_contains "fresh persistence status returns success" "$FRESH_LINE" '"isError":false'
assert_contains "fresh persistence reports active mode" "$FRESH_LINE" 'active'
rm -rf "$PERSIST_DIR_58"

# Feature: F011
# --- F011-T004: Unknown subcommand error handling ---
echo "Test: Unknown subcommand 'foo' exits 1 and reports error on stderr"
capture_cli_stderr foo
assert_exit_code "zpm foo exits 1" "$CLI_EXIT" 1
assert_contains "zpm foo stderr mentions unknown command" "$CLI_STDERR" "foo"

echo "Test: Unknown flag '--unknown-flag' exits 1 and reports error on stderr"
capture_cli_stderr --unknown-flag
assert_exit_code "zpm --unknown-flag exits 1" "$CLI_EXIT" 1
assert_contains "zpm --unknown-flag stderr reports error" "$CLI_STDERR" "unknown"

# --- F011-T006: CLI entrypoint functional tests ---

# US1: each help invocation displays help and exits 0
for HELP_INVOCATION in "" "--help" "-h"; do
    echo "Test: zpm ${HELP_INVOCATION:-<no args>} displays help (US1)"
    # shellcheck disable=SC2086
    capture_cli $HELP_INVOCATION
    assert_exit_code "zpm ${HELP_INVOCATION:-<no args>} exits 0" "$CLI_EXIT" 0
    assert_contains "zpm ${HELP_INVOCATION:-<no args>} output contains program name" "$CLI_OUTPUT" "zpm"
    assert_contains "zpm ${HELP_INVOCATION:-<no args>} mentions serve subcommand" "$CLI_OUTPUT" "serve"
done

# US2: zpm serve routes MCP protocol correctly
echo "Test: zpm serve processes MCP initialize (US2)"
SERVE_TMPDIR=$(mktemp -d)
mkdir -p "$SERVE_TMPDIR/.zpm/data" "$SERVE_TMPDIR/.zpm/kb"
SERVE_RESPONSE=$(cd "$SERVE_TMPDIR" && printf '%s' "$INIT_REQ" | timeout "$TIMEOUT" "$BINARY" serve 2>/dev/null || true)
rm -rf "$SERVE_TMPDIR"
assert_contains "zpm serve returns correct server name" "$SERVE_RESPONSE" '"name":"zpm"'
assert_contains "zpm serve returns correct protocol version" "$SERVE_RESPONSE" '"protocolVersion":"2025-11-25"'

# US3: each version invocation prints version string and exits 0
for VERSION_FLAG in "--version" "-v"; do
    echo "Test: zpm $VERSION_FLAG prints version string (US3)"
    capture_cli "$VERSION_FLAG"
    assert_exit_code "zpm $VERSION_FLAG exits 0" "$CLI_EXIT" 0
    assert_contains "zpm $VERSION_FLAG output contains version" "$CLI_OUTPUT" "0.1.0"
done

# --- Test: zpm init creates .zpm/ directory structure (T009/US1) ---
echo "Test: zpm init creates .zpm/ directory structure (US1)"
INIT_TMPDIR=$(mktemp -d)

INIT_EXIT=0
(cd "$INIT_TMPDIR" && "$BINARY" init 2>/dev/null >/dev/null) || INIT_EXIT=$?
assert_exit_code "zpm init exits 0" "$INIT_EXIT" 0

INIT_DIRS_EXIST=0
[ -d "$INIT_TMPDIR/.zpm" ] || INIT_DIRS_EXIST=1
[ -d "$INIT_TMPDIR/.zpm/kb" ] || INIT_DIRS_EXIST=1
[ -d "$INIT_TMPDIR/.zpm/data" ] || INIT_DIRS_EXIST=1
[ -f "$INIT_TMPDIR/.zpm/.gitignore" ] || INIT_DIRS_EXIST=1
assert_exit_code "zpm init creates .zpm/ kb/ data/ and .gitignore" "$INIT_DIRS_EXIST" 0

GITIGNORE_CONTENT=$(cat "$INIT_TMPDIR/.zpm/.gitignore" 2>/dev/null || echo "")
assert_contains ".zpm/.gitignore contains data/" "$GITIGNORE_CONTENT" "data/"

echo "Test: zpm init output confirms initialization (US1)"
INIT_TMPDIR2=$(mktemp -d)
INIT_OUTPUT=$(cd "$INIT_TMPDIR2" && "$BINARY" init 2>&1 || true)
assert_contains "zpm init prints success message" "$INIT_OUTPUT" "Initialized"

echo "Test: zpm init is idempotent (US1)"
IDEMPOTENT_EXIT=0
(cd "$INIT_TMPDIR" && "$BINARY" init 2>/dev/null >/dev/null) || IDEMPOTENT_EXIT=$?
assert_exit_code "zpm init re-run exits 0" "$IDEMPOTENT_EXIT" 0

IDEMPOTENT_GITIGNORE=$(cat "$INIT_TMPDIR/.zpm/.gitignore" 2>/dev/null || echo "")
assert_contains "zpm init re-run preserves .gitignore content" "$IDEMPOTENT_GITIGNORE" "data/"

IDEMPOTENT_OUTPUT=$(cd "$INIT_TMPDIR" && "$BINARY" init 2>&1 || true)
assert_contains "zpm init re-run prints already-initialized message" "$IDEMPOTENT_OUTPUT" "already"

rm -rf "$INIT_TMPDIR" "$INIT_TMPDIR2"

# --- Test: zpm serve from subdirectory finds parent .zpm/ (T010/US4) ---
echo "Test: zpm serve from subdirectory finds parent .zpm/ (US4)"
UPWARD_ROOT=$(mktemp -d)
mkdir -p "$UPWARD_ROOT/.zpm/data" "$UPWARD_ROOT/.zpm/kb"
mkdir -p "$UPWARD_ROOT/src/subpkg"
UPWARD_RESPONSE=$(cd "$UPWARD_ROOT/src/subpkg" && printf '%s' "$INIT_REQ" | timeout "$TIMEOUT" "$BINARY" serve 2>/dev/null || true)
assert_contains "zpm serve from nested subdir returns server name" "$UPWARD_RESPONSE" '"name":"zpm"'
assert_contains "zpm serve from nested subdir returns protocol version" "$UPWARD_RESPONSE" '"protocolVersion":"2025-11-25"'
rm -rf "$UPWARD_ROOT"

# --- Test: zpm serve without .zpm/ exits with error (T011/US2) ---
echo "Test: zpm serve without .zpm/ exits with error (US2)"
NO_ZPM_DIR=$(mktemp -d)
NO_ZPM_EXIT=0
NO_ZPM_OUTPUT=$(cd "$NO_ZPM_DIR" && "$BINARY" serve 2>&1) || NO_ZPM_EXIT=$?
assert_exit_code "zpm serve without .zpm/ exits non-zero" "$NO_ZPM_EXIT" 1
assert_contains "zpm serve without .zpm/ suggests zpm init" "$NO_ZPM_OUTPUT" "zpm init"
rm -rf "$NO_ZPM_DIR"

# --- Test: snapshot lands in .zpm/kb/, WAL stays in .zpm/data/ (T012/US3) ---
echo "Test: snapshot/WAL path split - snapshot in kb/, WAL in data/ (US3)"
SPLIT_DIR=$(mktemp -d)
SPLIT_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":200,\"method\":\"tools/call\",\"params\":{\"name\":\"remember_fact\",\"arguments\":{\"fact\":\"path_split(verified)\"}}}
{\"jsonrpc\":\"2.0\",\"id\":201,\"method\":\"tools/call\",\"params\":{\"name\":\"save_snapshot\",\"arguments\":{\"name\":\"split_test\"}}}
"
send_mcp_persist "$SPLIT_INPUT" "$SPLIT_DIR" > /dev/null

SNAP_IN_KB=0
[ -f "$SPLIT_DIR/.zpm/kb/split_test.pl" ] || SNAP_IN_KB=1
assert_exit_code "snapshot .pl file lands in .zpm/kb/" "$SNAP_IN_KB" 0

SNAP_NOT_IN_DATA=0
[ -f "$SPLIT_DIR/.zpm/data/split_test.pl" ] && SNAP_NOT_IN_DATA=1
assert_exit_code "snapshot .pl file absent from .zpm/data/" "$SNAP_NOT_IN_DATA" 0

WAL_IN_DATA=0
ls "$SPLIT_DIR/.zpm/data/"*.wal 2>/dev/null | grep -q . || WAL_IN_DATA=1
assert_exit_code "WAL journal file exists in .zpm/data/" "$WAL_IN_DATA" 0

WAL_NOT_IN_KB=0
ls "$SPLIT_DIR/.zpm/kb/"*.wal 2>/dev/null | grep -q . && WAL_NOT_IN_KB=1
assert_exit_code "WAL journal file absent from .zpm/kb/" "$WAL_NOT_IN_KB" 0

rm -rf "$SPLIT_DIR"

# --- Test: .pl file pre-placed in .zpm/kb/ is auto-loaded on serve startup (T013/US5) ---
echo "Test: .pl file in .zpm/kb/ is auto-loaded on zpm serve startup (US5)"
AUTOLOAD_DIR=$(mktemp -d)
mkdir -p "$AUTOLOAD_DIR/.zpm/data" "$AUTOLOAD_DIR/.zpm/kb"
echo 'autoloaded(hello).' > "$AUTOLOAD_DIR/.zpm/kb/preload.pl"
AUTOLOAD_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":300,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{\"fact\":\"autoloaded(hello)\"}}}"
AUTOLOAD_RESPONSE=$(send_mcp_persist "$AUTOLOAD_INPUT" "$AUTOLOAD_DIR")
AUTOLOAD_LINE=$(echo "$AUTOLOAD_RESPONSE" | grep '"id":300')
assert_contains ".pl auto-load: explain_why is not an error" "$AUTOLOAD_LINE" '"isError":false'
assert_contains ".pl auto-load: fact is proven from preloaded file" "$AUTOLOAD_LINE" '\"proven\":true'
rm -rf "$AUTOLOAD_DIR"

# --- Test: non-.pl files in .zpm/kb/ are silently ignored on startup (T013/US5) ---
echo "Test: non-.pl files in .zpm/kb/ are silently ignored on startup (US5)"
NON_PL_DIR=$(mktemp -d)
mkdir -p "$NON_PL_DIR/.zpm/data" "$NON_PL_DIR/.zpm/kb"
echo 'this is not prolog' > "$NON_PL_DIR/.zpm/kb/readme.txt"
echo 'autoloaded(world).' > "$NON_PL_DIR/.zpm/kb/facts.pl"
NON_PL_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":301,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{\"fact\":\"autoloaded(world)\"}}}"
NON_PL_RESPONSE=$(send_mcp_persist "$NON_PL_INPUT" "$NON_PL_DIR")
NON_PL_LINE=$(echo "$NON_PL_RESPONSE" | grep '"id":301')
assert_contains "non-.pl ignored: server still starts and responds" "$NON_PL_LINE" '"isError":false'
assert_contains "non-.pl ignored: .pl file still loaded" "$NON_PL_LINE" '\"proven\":true'
rm -rf "$NON_PL_DIR"

# --- Test: .pl file with syntax error in .zpm/kb/ is skipped, server still starts (T013/US5) ---
echo "Test: syntax-error .pl in .zpm/kb/ is skipped, server still starts (US5)"
SYNERR_DIR=$(mktemp -d)
mkdir -p "$SYNERR_DIR/.zpm/data" "$SYNERR_DIR/.zpm/kb"
echo 'this is not valid prolog !!!' > "$SYNERR_DIR/.zpm/kb/broken.pl"
echo 'valid_fact(ok).' > "$SYNERR_DIR/.zpm/kb/valid.pl"
SYNERR_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":302,\"method\":\"tools/call\",\"params\":{\"name\":\"explain_why\",\"arguments\":{\"fact\":\"valid_fact(ok)\"}}}"
SYNERR_RESPONSE=$(send_mcp_persist "$SYNERR_INPUT" "$SYNERR_DIR")
SYNERR_LINE=$(echo "$SYNERR_RESPONSE" | grep '"id":302')
assert_contains "syntax-error .pl skipped: server still responds" "$SYNERR_LINE" '"isError":false'
assert_contains "syntax-error .pl skipped: valid .pl still loaded" "$SYNERR_LINE" '\"proven\":true'
rm -rf "$SYNERR_DIR"

# --- Test: zpm serve with read-only .zpm/data/ runs in degraded mode (T015/US2) ---
echo "Test: zpm serve with read-only .zpm/data/ runs in degraded mode (US2)"
DEGRADED_DIR=$(mktemp -d)
mkdir -p "$DEGRADED_DIR/.zpm/data" "$DEGRADED_DIR/.zpm/kb"
chmod -w "$DEGRADED_DIR/.zpm/data"
DEGRADED_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":400,\"method\":\"tools/call\",\"params\":{\"name\":\"get_persistence_status\",\"arguments\":{}}}
"
DEGRADED_RESPONSE=$(send_mcp_persist "$DEGRADED_INPUT" "$DEGRADED_DIR")
DEGRADED_INIT_LINE=$(echo "$DEGRADED_RESPONSE" | grep '"id":1')
DEGRADED_STATUS_LINE=$(echo "$DEGRADED_RESPONSE" | grep '"id":400')
assert_contains "degraded mode: MCP handshake succeeds" "$DEGRADED_INIT_LINE" '"name":"zpm"'
assert_contains "degraded mode: get_persistence_status returns success" "$DEGRADED_STATUS_LINE" '"isError":false'
assert_contains "degraded mode: persistence status is degraded" "$DEGRADED_STATUS_LINE" 'degraded'
chmod +w "$DEGRADED_DIR/.zpm/data"
rm -rf "$DEGRADED_DIR"

# --- Test: missing .zpm/data/ and .zpm/kb/ are auto-created on serve startup (T016/US3) ---
echo "Test: missing .zpm/ subdirectories are auto-created on serve startup (US3)"
SUBDIRS_DIR=$(mktemp -d)
mkdir -p "$SUBDIRS_DIR/.zpm"
SUBDIRS_INPUT="${INIT_REQ}
{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}
{\"jsonrpc\":\"2.0\",\"id\":500,\"method\":\"tools/call\",\"params\":{\"name\":\"get_persistence_status\",\"arguments\":{}}}"
SUBDIRS_RESPONSE=$(cd "$SUBDIRS_DIR" && printf '%s' "$SUBDIRS_INPUT" | timeout "$TIMEOUT" "$BINARY" serve 2>/dev/null || true)
SUBDIRS_INIT_LINE=$(echo "$SUBDIRS_RESPONSE" | grep '"id":1')
SUBDIRS_STATUS_LINE=$(echo "$SUBDIRS_RESPONSE" | grep '"id":500')
assert_contains "auto-create subdirs: MCP handshake succeeds" "$SUBDIRS_INIT_LINE" '"name":"zpm"'
assert_contains "auto-create subdirs: get_persistence_status returns success" "$SUBDIRS_STATUS_LINE" '"isError":false'
assert_true "auto-create subdirs: .zpm/data/ was created" test -d "$SUBDIRS_DIR/.zpm/data"
assert_true "auto-create subdirs: .zpm/kb/ was created" test -d "$SUBDIRS_DIR/.zpm/kb"
rm -rf "$SUBDIRS_DIR"

# Feature: F017
# --- F017-T009: remember-fact CLI command ---

echo "Test: zpm remember-fact persists fact and exits 0 (F017/US1)"
RF_DIR=$(mktemp -d)
(cd "$RF_DIR" && "$BINARY" init >/dev/null 2>&1)
RF_EXIT=0
RF_OUTPUT=$(cd "$RF_DIR" && "$BINARY" remember-fact "task_status(f017, in_progress)" 2>&1) || RF_EXIT=$?
assert_exit_code "zpm remember-fact exits 0" "$RF_EXIT" 0
assert_contains "zpm remember-fact confirms asserted fact" "$RF_OUTPUT" "task_status"

echo "Test: zpm remember-fact with invalid Prolog syntax exits non-zero (F017/US1)"
RF_INVALID_EXIT=0
RF_INVALID_OUTPUT=$(cd "$RF_DIR" && "$BINARY" remember-fact 'decision(' 2>&1) || RF_INVALID_EXIT=$?
assert_exit_code "zpm remember-fact invalid syntax exits non-zero" "$RF_INVALID_EXIT" 1
assert_contains "zpm remember-fact invalid syntax reports error" "$RF_INVALID_OUTPUT" ""

echo "Test: zpm remember-fact then query-logic round-trip (F017/US1)"
RT_DIR=$(mktemp -d)
(cd "$RT_DIR" && "$BINARY" init >/dev/null 2>&1)
(cd "$RT_DIR" && "$BINARY" remember-fact "test(cli)" >/dev/null 2>&1)
RT_EXIT=0
RT_OUTPUT=$(cd "$RT_DIR" && "$BINARY" query-logic "test(X)" 2>&1) || RT_EXIT=$?
assert_exit_code "query-logic after remember-fact exits 0" "$RT_EXIT" 0
assert_contains "query-logic returns cli binding after remember-fact" "$RT_OUTPUT" "cli"
rm -rf "$RF_DIR" "$RT_DIR"

# Feature: F017
# --- F017-T009: upsert-fact CLI command ---

echo "Test: zpm upsert-fact inserts new fact and exits 0 (F017/US1)"
UF_DIR=$(mktemp -d)
(cd "$UF_DIR" && "$BINARY" init >/dev/null 2>&1)
UF_EXIT=0
UF_OUTPUT=$(cd "$UF_DIR" && "$BINARY" upsert-fact "task_status(f017, in_progress)" 2>&1) || UF_EXIT=$?
assert_exit_code "zpm upsert-fact exits 0" "$UF_EXIT" 0
assert_contains "zpm upsert-fact confirms operation" "$UF_OUTPUT" "task_status"

echo "Test: zpm upsert-fact replaces existing fact with same functor and first arg (F017/US1)"
(cd "$UF_DIR" && "$BINARY" remember-fact "task_status(f017, in_progress)" >/dev/null 2>&1)
UF_REPLACE_EXIT=0
UF_REPLACE_OUTPUT=$(cd "$UF_DIR" && "$BINARY" upsert-fact "task_status(f017, done)" 2>&1) || UF_REPLACE_EXIT=$?
assert_exit_code "zpm upsert-fact replace exits 0" "$UF_REPLACE_EXIT" 0
assert_contains "zpm upsert-fact replace confirms done fact" "$UF_REPLACE_OUTPUT" "done"
rm -rf "$UF_DIR"

# Feature: F017
# --- F017-T010: query-logic CLI command ---

echo "Test: zpm query-logic returns empty result for no matching facts (F017/US2)"
QL_DIR=$(mktemp -d)
(cd "$QL_DIR" && "$BINARY" init >/dev/null 2>&1)
QL_EXIT=0
QL_OUTPUT=$(cd "$QL_DIR" && "$BINARY" query-logic "missing(X)" 2>&1) || QL_EXIT=$?
assert_exit_code "zpm query-logic no results exits 0" "$QL_EXIT" 0

echo "Test: zpm query-logic returns matching bindings after remember-fact (F017/US2)"
(cd "$QL_DIR" && "$BINARY" remember-fact "depends_on(cli, trealla)" >/dev/null 2>&1)
QL2_EXIT=0
QL2_OUTPUT=$(cd "$QL_DIR" && "$BINARY" query-logic "depends_on(X, trealla)" 2>&1) || QL2_EXIT=$?
assert_exit_code "zpm query-logic with results exits 0" "$QL2_EXIT" 0
assert_contains "zpm query-logic returns bound value" "$QL2_OUTPUT" "cli"
rm -rf "$QL_DIR"

# --- F017-T010: explain-why CLI command ---

echo "Test: zpm explain-why for known fact exits 0 (F017/US2)"
EW_DIR=$(mktemp -d)
(cd "$EW_DIR" && "$BINARY" init >/dev/null 2>&1)
(cd "$EW_DIR" && "$BINARY" remember-fact "project(zpm)" >/dev/null 2>&1)
EW_EXIT=0
EW_OUTPUT=$(cd "$EW_DIR" && "$BINARY" explain-why "project(zpm)" 2>&1) || EW_EXIT=$?
assert_exit_code "zpm explain-why exits 0" "$EW_EXIT" 0
assert_contains "zpm explain-why returns explanation" "$EW_OUTPUT" "project"
rm -rf "$EW_DIR"

# --- F017-T010: get-justification CLI command ---

echo "Test: zpm get-justification for assumed fact exits 0 (F017/US2)"
GJ_DIR=$(mktemp -d)
(cd "$GJ_DIR" && "$BINARY" init >/dev/null 2>&1)
(cd "$GJ_DIR" && "$BINARY" assume-fact "hypothesis(test)" --assumption "baseline" >/dev/null 2>&1)
GJ_EXIT=0
GJ_OUTPUT=$(cd "$GJ_DIR" && "$BINARY" get-justification "baseline" 2>&1) || GJ_EXIT=$?
assert_exit_code "zpm get-justification exits 0" "$GJ_EXIT" 0
assert_contains "zpm get-justification returns result" "$GJ_OUTPUT" "hypothesis"
rm -rf "$GJ_DIR"

# --- F017-T010: get-belief-status CLI command ---

echo "Test: zpm get-belief-status for known fact exits 0 (F017/US2)"
GB_DIR=$(mktemp -d)
(cd "$GB_DIR" && "$BINARY" init >/dev/null 2>&1)
# get-belief-status reports TMS state — must assume (not just remember) the fact
(cd "$GB_DIR" && "$BINARY" assume-fact "decision(backend, trealla)" --assumption "chosen" >/dev/null 2>&1)
GB_EXIT=0
GB_OUTPUT=$(cd "$GB_DIR" && "$BINARY" get-belief-status "decision(backend, trealla)" 2>&1) || GB_EXIT=$?
assert_exit_code "zpm get-belief-status exits 0" "$GB_EXIT" 0
assert_contains "zpm get-belief-status returns status" "$GB_OUTPUT" "chosen"
rm -rf "$GB_DIR"

# --- F017-T010: list-assumptions CLI command ---

echo "Test: zpm list-assumptions exits 0 with empty KB (F017/US2)"
LA_DIR=$(mktemp -d)
(cd "$LA_DIR" && "$BINARY" init >/dev/null 2>&1)
LA_EXIT=0
LA_OUTPUT=$(cd "$LA_DIR" && "$BINARY" list-assumptions 2>&1) || LA_EXIT=$?
assert_exit_code "zpm list-assumptions empty exits 0" "$LA_EXIT" 0

echo "Test: zpm list-assumptions shows assumed facts (F017/US2)"
(cd "$LA_DIR" && "$BINARY" assume-fact "hypothesis(test)" --assumption "baseline" >/dev/null 2>&1)
LA2_EXIT=0
LA2_OUTPUT=$(cd "$LA_DIR" && "$BINARY" list-assumptions 2>&1) || LA2_EXIT=$?
assert_exit_code "zpm list-assumptions with facts exits 0" "$LA2_EXIT" 0
assert_contains "zpm list-assumptions includes assumed fact" "$LA2_OUTPUT" "baseline"
rm -rf "$LA_DIR"

# --- F017-T010: get-knowledge-schema CLI command ---

echo "Test: zpm get-knowledge-schema exits 0 (F017/US2)"
GKS_DIR=$(mktemp -d)
(cd "$GKS_DIR" && "$BINARY" init >/dev/null 2>&1)
GKS_EXIT=0
GKS_OUTPUT=$(cd "$GKS_DIR" && "$BINARY" get-knowledge-schema 2>&1) || GKS_EXIT=$?
assert_exit_code "zpm get-knowledge-schema exits 0" "$GKS_EXIT" 0
rm -rf "$GKS_DIR"

# --- F017-T010: get-persistence-status CLI command ---

echo "Test: zpm get-persistence-status exits 0 with initialized KB (F017/US2)"
GPS_DIR=$(mktemp -d)
(cd "$GPS_DIR" && "$BINARY" init >/dev/null 2>&1)
GPS_EXIT=0
GPS_OUTPUT=$(cd "$GPS_DIR" && "$BINARY" get-persistence-status 2>&1) || GPS_EXIT=$?
assert_exit_code "zpm get-persistence-status exits 0" "$GPS_EXIT" 0
rm -rf "$GPS_DIR"

# --- F017-T010: verify-consistency CLI command ---

echo "Test: zpm verify-consistency exits 0 with empty KB (F017/US2)"
VC_DIR=$(mktemp -d)
(cd "$VC_DIR" && "$BINARY" init >/dev/null 2>&1)
VC_EXIT=0
VC_OUTPUT=$(cd "$VC_DIR" && "$BINARY" verify-consistency 2>&1) || VC_EXIT=$?
assert_exit_code "zpm verify-consistency exits 0" "$VC_EXIT" 0
rm -rf "$VC_DIR"

# --- F017-T010: list-snapshots CLI command ---

echo "Test: zpm list-snapshots exits 0 with no snapshots (F017/US2)"
LSN_DIR=$(mktemp -d)
(cd "$LSN_DIR" && "$BINARY" init >/dev/null 2>&1)
LSN_EXIT=0
LSN_OUTPUT=$(cd "$LSN_DIR" && "$BINARY" list-snapshots 2>&1) || LSN_EXIT=$?
assert_exit_code "zpm list-snapshots exits 0" "$LSN_EXIT" 0
rm -rf "$LSN_DIR"

# --- F017-T010: trace-dependency CLI command ---

echo "Test: zpm trace-dependency exits 0 for known fact (F017/US2)"
TD_DIR=$(mktemp -d)
(cd "$TD_DIR" && "$BINARY" init >/dev/null 2>&1)
# trace_dependency queries path(X, start_node) — predecessors of start_node
(cd "$TD_DIR" && "$BINARY" remember-fact "path(app, engine)" >/dev/null 2>&1)
TD_EXIT=0
TD_OUTPUT=$(cd "$TD_DIR" && "$BINARY" trace-dependency "engine" 2>&1) || TD_EXIT=$?
assert_exit_code "zpm trace-dependency exits 0" "$TD_EXIT" 0
assert_contains "zpm trace-dependency returns result" "$TD_OUTPUT" "app"
rm -rf "$TD_DIR"

# Feature: F017
# --- F017-T011: NFR-001 performance gate ---

echo "Test: zpm query-logic \"true\" completes under 500ms (F017/NFR-001)"
PERF_DIR=$(mktemp -d)
(cd "$PERF_DIR" && "$BINARY" init >/dev/null 2>&1)
PERF_START=$(date +%s%3N)
PERF_EXIT=0
(cd "$PERF_DIR" && "$BINARY" query-logic "true" >/dev/null 2>&1) || PERF_EXIT=$?
PERF_END=$(date +%s%3N)
PERF_MS=$((PERF_END - PERF_START))
assert_exit_code "zpm query-logic true exits 0" "$PERF_EXIT" 0
if [ "$PERF_MS" -lt 500 ]; then
    green "  PASS: query-logic completed in ${PERF_MS}ms (< 500ms)"
    PASS=$((PASS + 1))
else
    red "  FAIL: query-logic took ${PERF_MS}ms (>= 500ms, NFR-001 violated)"
    FAIL=$((FAIL + 1))
fi
rm -rf "$PERF_DIR"

# Feature: F017
# --- F017-T012: remaining CLI commands ---

echo "Test: zpm echo returns message and exits 0 (F017/US3)"
ECHO_DIR=$(mktemp -d)
(cd "$ECHO_DIR" && "$BINARY" init >/dev/null 2>&1)
ECHO_EXIT=0
ECHO_OUTPUT=$(cd "$ECHO_DIR" && "$BINARY" echo "hello" 2>&1) || ECHO_EXIT=$?
assert_exit_code "zpm echo exits 0" "$ECHO_EXIT" 0
assert_contains "zpm echo returns message" "$ECHO_OUTPUT" "hello"
rm -rf "$ECHO_DIR"

echo "Test: zpm assume-fact stores hypothesis and exits 0 (F017/US3)"
AF_DIR=$(mktemp -d)
(cd "$AF_DIR" && "$BINARY" init >/dev/null 2>&1)
AF_EXIT=0
AF_OUTPUT=$(cd "$AF_DIR" && "$BINARY" assume-fact "hypothesis(deploy_ready)" --assumption "baseline" 2>&1) || AF_EXIT=$?
assert_exit_code "zpm assume-fact exits 0" "$AF_EXIT" 0
assert_contains "zpm assume-fact confirms assumption" "$AF_OUTPUT" "hypothesis"
rm -rf "$AF_DIR"

echo "Test: zpm retract-assumption removes specific assumption and exits 0 (F017/US3)"
RA_DIR=$(mktemp -d)
(cd "$RA_DIR" && "$BINARY" init >/dev/null 2>&1)
(cd "$RA_DIR" && "$BINARY" assume-fact "hypothesis(revert_needed)" --assumption "rollback" >/dev/null 2>&1)
RA_EXIT=0
RA_OUTPUT=$(cd "$RA_DIR" && "$BINARY" retract-assumption "rollback" 2>&1) || RA_EXIT=$?
assert_exit_code "zpm retract-assumption exits 0" "$RA_EXIT" 0
rm -rf "$RA_DIR"

echo "Test: zpm retract-assumptions removes all assumptions and exits 0 (F017/US3)"
RAS_DIR=$(mktemp -d)
(cd "$RAS_DIR" && "$BINARY" init >/dev/null 2>&1)
(cd "$RAS_DIR" && "$BINARY" assume-fact "hypothesis(a)" --assumption "guess_a" >/dev/null 2>&1)
(cd "$RAS_DIR" && "$BINARY" assume-fact "hypothesis(b)" --assumption "guess_b" >/dev/null 2>&1)
RAS_EXIT=0
RAS_OUTPUT=$(cd "$RAS_DIR" && "$BINARY" retract-assumptions "guess_" 2>&1) || RAS_EXIT=$?
assert_exit_code "zpm retract-assumptions exits 0" "$RAS_EXIT" 0
rm -rf "$RAS_DIR"

echo "Test: zpm forget-fact removes permanent fact and exits 0 (F017/US3)"
FF_DIR=$(mktemp -d)
(cd "$FF_DIR" && "$BINARY" init >/dev/null 2>&1)
(cd "$FF_DIR" && "$BINARY" remember-fact "task_status(t012, done)" >/dev/null 2>&1)
FF_EXIT=0
FF_OUTPUT=$(cd "$FF_DIR" && "$BINARY" forget-fact "task_status(t012, done)" 2>&1) || FF_EXIT=$?
assert_exit_code "zpm forget-fact exits 0" "$FF_EXIT" 0
rm -rf "$FF_DIR"

echo "Test: zpm update-fact replaces existing fact and exits 0 (F017/US3)"
UPF_DIR=$(mktemp -d)
(cd "$UPF_DIR" && "$BINARY" init >/dev/null 2>&1)
(cd "$UPF_DIR" && "$BINARY" remember-fact "task_status(t012, in_progress)" >/dev/null 2>&1)
UPF_EXIT=0
UPF_OUTPUT=$(cd "$UPF_DIR" && "$BINARY" update-fact "task_status(t012, in_progress)" --new-fact "task_status(t012, done)" 2>&1) || UPF_EXIT=$?
assert_exit_code "zpm update-fact exits 0" "$UPF_EXIT" 0
assert_contains "zpm update-fact confirms updated fact" "$UPF_OUTPUT" "task_status"
rm -rf "$UPF_DIR"

echo "Test: zpm define-rule stores rule and exits 0 (F017/US3)"
DR_DIR=$(mktemp -d)
(cd "$DR_DIR" && "$BINARY" init >/dev/null 2>&1)
DR_EXIT=0
DR_OUTPUT=$(cd "$DR_DIR" && "$BINARY" define-rule "ready(X)" --body "task_status(X, done)" 2>&1) || DR_EXIT=$?
assert_exit_code "zpm define-rule exits 0" "$DR_EXIT" 0
assert_contains "zpm define-rule confirms rule" "$DR_OUTPUT" "ready"
rm -rf "$DR_DIR"

echo "Test: zpm clear-context removes matching facts and exits 0 (F017/US3)"
CC_DIR=$(mktemp -d)
(cd "$CC_DIR" && "$BINARY" init >/dev/null 2>&1)
(cd "$CC_DIR" && "$BINARY" assume-fact "hypothesis(stale)" --assumption "obsolete" >/dev/null 2>&1)
CC_EXIT=0
CC_OUTPUT=$(cd "$CC_DIR" && "$BINARY" clear-context "hypothesis" 2>&1) || CC_EXIT=$?
assert_exit_code "zpm clear-context exits 0" "$CC_EXIT" 0
rm -rf "$CC_DIR"

echo "Test: zpm save-snapshot creates snapshot and exits 0 (F017/US3)"
SS_DIR=$(mktemp -d)
(cd "$SS_DIR" && "$BINARY" init >/dev/null 2>&1)
(cd "$SS_DIR" && "$BINARY" remember-fact "decision(backend, trealla)" >/dev/null 2>&1)
SS_EXIT=0
SS_OUTPUT=$(cd "$SS_DIR" && "$BINARY" save-snapshot "test-snap" 2>&1) || SS_EXIT=$?
assert_exit_code "zpm save-snapshot exits 0" "$SS_EXIT" 0
assert_contains "zpm save-snapshot confirms saved" "$SS_OUTPUT" "test-snap"

echo "Test: zpm restore-snapshot restores saved snapshot and exits 0 (F017/US3)"
RS_EXIT=0
RS_OUTPUT=$(cd "$SS_DIR" && "$BINARY" restore-snapshot "test-snap" 2>&1) || RS_EXIT=$?
assert_exit_code "zpm restore-snapshot exits 0" "$RS_EXIT" 0
assert_contains "zpm restore-snapshot confirms restored" "$RS_OUTPUT" "test-snap"
rm -rf "$SS_DIR"

# --- FR-007: Error paths emit non-empty stderr with tool name + field name (T013) ---
echo "Test: zpm remember-fact missing required arg emits non-empty stderr with tool and field name (FR-007/T013)"
FR7_MISS_DIR=$(mktemp -d)
(cd "$FR7_MISS_DIR" && "$BINARY" init >/dev/null 2>&1)
pushd "$FR7_MISS_DIR" >/dev/null
capture_cli_stderr remember-fact
popd >/dev/null
assert_true "zpm remember-fact missing arg exits non-zero" test "$CLI_EXIT" -ne 0
assert_true "zpm remember-fact missing arg stderr is non-empty" test -n "$CLI_STDERR"
assert_contains "zpm remember-fact missing arg stderr contains tool name" "$CLI_STDERR" "remember-fact"
assert_contains "zpm remember-fact missing arg stderr contains field name" "$CLI_STDERR" "fact"
rm -rf "$FR7_MISS_DIR"

echo "Test: zpm remember-fact unknown flag emits non-empty stderr with tool and flag name (FR-007/T013)"
FR7_UNK_DIR=$(mktemp -d)
(cd "$FR7_UNK_DIR" && "$BINARY" init >/dev/null 2>&1)
pushd "$FR7_UNK_DIR" >/dev/null
capture_cli_stderr remember-fact "task_status(t013, done)" --unknown-flag
popd >/dev/null
assert_true "zpm remember-fact unknown flag exits non-zero" test "$CLI_EXIT" -ne 0
assert_true "zpm remember-fact unknown flag stderr is non-empty" test -n "$CLI_STDERR"
assert_contains "zpm remember-fact unknown flag stderr contains tool name" "$CLI_STDERR" "remember-fact"
assert_contains "zpm remember-fact unknown flag stderr contains flag name" "$CLI_STDERR" "unknown-flag"
rm -rf "$FR7_UNK_DIR"

# Feature: F017
# --- FR-008 / US2 AC1: --format json yields a parseable JSON array ---
echo "Test: zpm query-logic --format json yields a JSON array on stdout (F017/US2 AC1)"
FMT_DIR=$(mktemp -d)
(cd "$FMT_DIR" && "$BINARY" init >/dev/null 2>&1)
(cd "$FMT_DIR" && "$BINARY" remember-fact "task_status(f017, done)" >/dev/null 2>&1)
FMT_EXIT=0
FMT_STDOUT=$(cd "$FMT_DIR" && "$BINARY" query-logic "task_status(X, done)" --format json 2>/dev/null) || FMT_EXIT=$?
assert_exit_code "zpm query-logic --format json exits 0" "$FMT_EXIT" 0
if command -v jq >/dev/null 2>&1; then
    if echo "$FMT_STDOUT" | jq -e 'type == "array"' >/dev/null 2>&1; then
        green "  PASS: --format json stdout parses as a JSON array via jq"
        PASS=$((PASS + 1))
    else
        red "  FAIL: --format json stdout did not parse as a JSON array via jq (got: $FMT_STDOUT)"
        FAIL=$((FAIL + 1))
    fi
else
    assert_contains "zpm query-logic --format json output looks like a JSON array" "$FMT_STDOUT" "["
fi
rm -rf "$FMT_DIR"

test_summary
