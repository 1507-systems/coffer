#!/usr/bin/env bash
# run-tests.sh -- Simple test harness for coffer
# Runs all test functions and reports pass/fail counts.
# shellcheck disable=SC2329
# Test functions are invoked dynamically via run_test, not direct calls.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
COFFER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Test counters
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# --- Test helpers ---

assert_eq() {
    local expected="$1"
    local actual="$2"
    local msg="${3:-}"
    if [[ "$expected" == "$actual" ]]; then
        return 0
    else
        echo "  FAIL: ${msg}"
        echo "    expected: '${expected}'"
        echo "    actual:   '${actual}'"
        return 1
    fi
}

assert_exit_code() {
    local expected="$1"
    shift
    local actual=0
    "$@" >/dev/null 2>&1 || actual=$?
    if [[ "$expected" -eq "$actual" ]]; then
        return 0
    else
        echo "  FAIL: expected exit code ${expected}, got ${actual}"
        echo "    command: $*"
        return 1
    fi
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local msg="${3:-}"
    if [[ "$haystack" == *"$needle"* ]]; then
        return 0
    else
        echo "  FAIL: ${msg}"
        echo "    expected to contain: '${needle}'"
        echo "    actual: '${haystack}'"
        return 1
    fi
}

run_test() {
    local test_name="$1"
    TESTS_RUN=$((TESTS_RUN + 1))
    echo "TEST: ${test_name}"
    if "$test_name"; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        echo "  PASS"
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
    fi
}

# --- Setup test fixtures ---

setup_test_env() {
    TEST_DIR=$(mktemp -d)
    export COFFER_ROOT="${TEST_DIR}/coffer"
    export COFFER_VAULT="${COFFER_ROOT}/vault"
    export COFFER_CONFIG_DIR="${TEST_DIR}/config"
    export COFFER_IDENTITY="${COFFER_CONFIG_DIR}/identity.txt"
    export COFFER_SOPS_CONFIG="${COFFER_ROOT}/config/.sops.yaml"
    export COFFER_SESSION_KEY="${COFFER_CONFIG_DIR}/.session-key"

    mkdir -p "${COFFER_ROOT}/lib" "${COFFER_ROOT}/config" "${COFFER_VAULT}" "${COFFER_CONFIG_DIR}"

    # Copy lib files from the real project
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    cp "${real_root}"/lib/*.sh "${COFFER_ROOT}/lib/"
    cp "${real_root}"/config/*.yaml "${COFFER_ROOT}/config/"

    # Source common helpers
    # shellcheck source=../lib/common.sh
    source "${COFFER_ROOT}/lib/common.sh"
}

teardown_test_env() {
    if [[ -n "${TEST_DIR:-}" ]] && [[ -d "$TEST_DIR" ]]; then
        rm -rf "$TEST_DIR"
    fi
}

# --- Common helper tests ---

test_die_exits_nonzero() {
    # die() should exit with code 1 and print to stderr
    # We override curl to avoid sending real ntfy notifications during tests
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        die "test error message"
    ' 2>&1) || true
    # die() calls exit 1, so the subshell should have exited non-zero
    # (bash -c wraps it, but the || true means we need to check output)
    assert_contains "$output" "coffer: error: test error message" "die() should print error message"
}

test_warn_prints_to_stderr() {
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        warn "test warning"
    ' 2>&1)
    assert_contains "$output" "coffer: warning: test warning" "warn() should print warning"
}

test_log_prints_to_stderr() {
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        log "test log"
    ' 2>&1)
    assert_contains "$output" "coffer: test log" "log() should print message"
}

test_require_cmd_succeeds_for_existing() {
    # 'bash' should always exist
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        require_cmd bash
        echo "ok"
    ' 2>&1)
    assert_contains "$output" "ok" "require_cmd should succeed for existing command"
}

test_require_cmd_fails_for_missing() {
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        require_cmd nonexistent_tool_xyz_12345
    ' 2>&1) || true
    assert_contains "$output" "nonexistent_tool_xyz_12345 not found" "require_cmd should fail for missing command"
}

test_parse_path_valid() {
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_VAULT="'"${COFFER_VAULT}"'"
        parse_path "cloudflare/dns-token"
        echo "cat=${COFFER_CATEGORY} key=${COFFER_KEY}"
    ' 2>&1)
    assert_contains "$output" "cat=cloudflare key=dns-token" "parse_path should parse category/key"
}

test_parse_path_invalid_no_slash() {
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_VAULT="'"${COFFER_VAULT}"'"
        parse_path "no-slash"
    ' 2>&1) || true
    assert_contains "$output" "Invalid path format" "parse_path should reject paths without /"
}

# --- List tests ---

test_list_with_test_vault() {
    # Create a fake vault file with plaintext keys (simulating SOPS encrypted file)
    cat > "${COFFER_VAULT}/testcat.yaml" <<'YAML'
key-one: ENC[AES256_GCM,data:abc]
key-two: ENC[AES256_GCM,data:def]
sops:
  lastmodified: "2026-04-07T00:00:00Z"
YAML

    # Source list.sh and run
    # shellcheck source=../lib/list.sh
    source "${COFFER_ROOT}/lib/list.sh"
    local output
    output=$(cmd_list 2>/dev/null)
    assert_contains "$output" "testcat/" "list should show category" && \
    assert_contains "$output" "key-one" "list should show key-one" && \
    assert_contains "$output" "key-two" "list should show key-two"
}

test_list_single_category() {
    cat > "${COFFER_VAULT}/singlecat.yaml" <<'YAML'
alpha: ENC[AES256_GCM,data:abc]
beta: ENC[AES256_GCM,data:def]
sops:
  lastmodified: "2026-04-07T00:00:00Z"
YAML

    # shellcheck source=../lib/list.sh
    source "${COFFER_ROOT}/lib/list.sh"
    local output
    output=$(cmd_list singlecat 2>/dev/null)
    assert_contains "$output" "alpha" "list category should show alpha" && \
    assert_contains "$output" "beta" "list category should show beta"
}

test_list_missing_category_fails() {
    # shellcheck source=../lib/list.sh
    source "${COFFER_ROOT}/lib/list.sh"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" cmd_list "nonexistent" 2>&1) || true
    assert_contains "$output" "not found" "list should fail for missing category"
}

# --- Get error case tests ---

test_get_missing_category_fails() {
    # shellcheck source=../lib/get.sh
    source "${COFFER_ROOT}/lib/get.sh"

    # Set up a fake identity so require_identity doesn't fail first
    touch "${COFFER_IDENTITY}"
    chmod 600 "${COFFER_IDENTITY}"
    export SOPS_AGE_KEY="AGE-SECRET-KEY-fake"

    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" cmd_get "nonexistent/key" 2>&1) || true
    assert_contains "$output" "not found" "get should fail for missing category"
}

test_get_no_args_fails() {
    # shellcheck source=../lib/get.sh
    source "${COFFER_ROOT}/lib/get.sh"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" cmd_get 2>&1) || true
    assert_contains "$output" "Usage" "get with no args should show usage"
}

# --- Entrypoint tests ---

test_coffer_no_command_fails() {
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash "${real_root}/bin/coffer" 2>&1) || true
    assert_contains "$output" "No command specified" "coffer with no command should fail"
}

test_coffer_unknown_command_fails() {
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash "${real_root}/bin/coffer" frobnicate 2>&1) || true
    assert_contains "$output" "Unknown command" "coffer with unknown command should fail"
}

test_coffer_help() {
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local output
    output=$(bash "${real_root}/bin/coffer" --help 2>&1)
    assert_contains "$output" "Usage: coffer" "coffer --help should show usage"
}

test_coffer_version() {
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local output
    output=$(bash "${real_root}/bin/coffer" --version 2>&1)
    assert_contains "$output" "coffer 1.0.0" "coffer --version should show version"
}

# --- Main ---

main() {
    echo "=== Coffer Test Suite ==="
    echo ""

    setup_test_env

    # Common helper tests
    run_test test_die_exits_nonzero
    run_test test_warn_prints_to_stderr
    run_test test_log_prints_to_stderr
    run_test test_require_cmd_succeeds_for_existing
    run_test test_require_cmd_fails_for_missing
    run_test test_parse_path_valid
    run_test test_parse_path_invalid_no_slash

    # List tests
    run_test test_list_with_test_vault
    run_test test_list_single_category
    run_test test_list_missing_category_fails

    # Get error case tests
    run_test test_get_missing_category_fails
    run_test test_get_no_args_fails

    # Entrypoint tests
    run_test test_coffer_no_command_fails
    run_test test_coffer_unknown_command_fails
    run_test test_coffer_help
    run_test test_coffer_version

    teardown_test_env

    echo ""
    echo "=== Results ==="
    echo "  Total:  ${TESTS_RUN}"
    echo "  Passed: ${TESTS_PASSED}"
    echo "  Failed: ${TESTS_FAILED}"
    echo ""

    if [[ $TESTS_FAILED -gt 0 ]]; then
        echo "SOME TESTS FAILED"
        exit 1
    else
        echo "ALL TESTS PASSED"
        exit 0
    fi
}

main "$@"
