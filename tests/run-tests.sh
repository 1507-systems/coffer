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
    # COFFER_VAULT_ROOT mimics the private vault repo (bryce-shashinka/coffer-vault)
    # in tests. Both the vault data (vault/*.yaml) and the SOPS config live under
    # COFFER_VAULT_ROOT, while COFFER_ROOT is only the tool code directory.
    # Setting COFFER_VAULT_ROOT here prevents bin/coffer from falling back to the
    # legacy in-repo layout or attempting to resolve ~/dev/coffer-vault on disk.
    export COFFER_VAULT_ROOT="${TEST_DIR}/coffer-vault"
    export COFFER_VAULT="${COFFER_VAULT_ROOT}/vault"
    export COFFER_CONFIG_DIR="${TEST_DIR}/config"
    export COFFER_SOPS_CONFIG="${COFFER_VAULT_ROOT}/config/.sops.yaml"
    export COFFER_SESSION_KEY="${COFFER_CONFIG_DIR}/.session-key"

    mkdir -p "${COFFER_ROOT}/lib" "${COFFER_VAULT_ROOT}/config" "${COFFER_VAULT}" "${COFFER_CONFIG_DIR}"

    # Copy lib files from the real project (these live in the tool repo)
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    cp "${real_root}"/lib/*.sh "${COFFER_ROOT}/lib/"

    # Create a minimal .sops.yaml in the vault config dir. The real config lives in
    # the private vault repo (bryce-shashinka/coffer-vault), not the tool repo.
    # Tests that need a specific .sops.yaml (e.g., multi-recipient tests) create
    # their own in a separate sandbox and do not go through setup_test_env.
    # This placeholder is enough to make list/get/set tests that check for the
    # file's existence pass without importing real vault data into CI.
    cat > "${COFFER_VAULT_ROOT}/config/.sops.yaml" <<'SOPSEOF'
creation_rules:
  - path_regex: vault/.*\.yaml$
    age: >-
      age1placeholder000000000000000000000000000000000000000000000000
SOPSEOF

    # Source common helpers
    # shellcheck source=../lib/common.sh
    source "${COFFER_ROOT}/lib/common.sh"
}

# Write a fake session-key file so require_identity passes in tests that
# exercise downstream code (list/get/set). Tests that need to verify the
# *absence* of an identity should call this helper's inverse by leaving the
# file un-written. The content must begin with AGE-SECRET-KEY- for unlock
# validation; we don't use this as a real key (tests either stub SOPS out
# or generate real keys via age-keygen in their own sandbox).
seed_fake_identity() {
    mkdir -p "${COFFER_CONFIG_DIR}"
    printf 'AGE-SECRET-KEY-FAKETESTFAKETESTFAKETESTFAKETESTFAKETEST\n' > "${COFFER_SESSION_KEY}"
    chmod 600 "${COFFER_SESSION_KEY}"
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

# Path-traversal hardening (corpus audit, coffer/medlow): a category that is
# "..", "../foo", a leading-dot, or contains non-[A-Za-z0-9_-] chars must be
# rejected so COFFER_VAULT_FILE can never escape the vault directory.
test_parse_path_rejects_dotdot_category() {
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_VAULT="'"${COFFER_VAULT}"'"
        parse_path "../etc/passwd"
    ' 2>&1) || true
    assert_contains "$output" "Invalid category" "parse_path should reject a '..' category"
}

test_parse_path_rejects_traversal_in_category() {
    # A multi-segment traversal where the first segment embeds ".." must die.
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_VAULT="'"${COFFER_VAULT}"'"
        parse_path "a..b/key"
    ' 2>&1) || true
    assert_contains "$output" "Invalid category" "parse_path should reject a category containing '..'"
}

test_parse_path_rejects_leading_dot_category() {
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_VAULT="'"${COFFER_VAULT}"'"
        parse_path ".hidden/key"
    ' 2>&1) || true
    assert_contains "$output" "Invalid category" "parse_path should reject a leading-dot category"
}

test_parse_path_rejects_bad_chars_category() {
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_VAULT="'"${COFFER_VAULT}"'"
        parse_path "cloud flare/key"
    ' 2>&1) || true
    assert_contains "$output" "Invalid category" "parse_path should reject a category with disallowed characters"
}

test_parse_path_rejects_dotdot_key() {
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_VAULT="'"${COFFER_VAULT}"'"
        parse_path "cloudflare/.."
    ' 2>&1) || true
    assert_contains "$output" "Invalid key" "parse_path should reject a '..' key"
}

test_parse_path_still_accepts_normal_category() {
    # Regression guard: legitimate hyphen/underscore categories must keep working
    # (the hardening must not break real usage like cloudflare/dns-token).
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_VAULT="'"${COFFER_VAULT}"'"
        parse_path "home-automation/api_token"
        echo "cat=${COFFER_CATEGORY} key=${COFFER_KEY} file=${COFFER_VAULT_FILE}"
    ' 2>&1)
    assert_contains "$output" "cat=home-automation key=api_token" "parse_path should still accept hyphen/underscore names" && \
    assert_contains "$output" "file=${COFFER_VAULT}/home-automation.yaml" "vault file path should resolve inside the vault dir"
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

# Bug C: coffer list must not crash when a vault yaml file is empty or null.
# Regression: on Verve, github.yaml was null-valued and caused list to print
#   "Error: cannot get keys of !!null" and stop iterating entirely.

test_list_empty_map_category_does_not_crash() {
    # A vault file containing `{}` (empty map) has type !!map, zero keys, and
    # should be listed as an empty category without crashing.
    printf '{}' > "${COFFER_VAULT}/emptymap.yaml"
    # Ensure there's at least one normal category file so we can confirm
    # iteration continues past the empty one.
    cat > "${COFFER_VAULT}/afterempty.yaml" <<'YAML'
existing-key: ENC[AES256_GCM,data:abc]
sops:
  lastmodified: "2026-04-07T00:00:00Z"
YAML

    # shellcheck source=../lib/list.sh
    source "${COFFER_ROOT}/lib/list.sh"
    local output rc=0
    output=$(cmd_list 2>/dev/null) || rc=$?

    # Must not crash (exit 0 expected).
    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: cmd_list exited ${rc} on empty-map vault file (expected 0)"
        return 1
    fi
    # Must show both categories — iteration must not stop at the empty one.
    assert_contains "$output" "emptymap/" "list should show empty-map category" && \
    assert_contains "$output" "afterempty/" "list should continue past empty-map to next category" && \
    assert_contains "$output" "existing-key" "list should show keys in subsequent category"
}

test_list_null_category_does_not_crash() {
    # A vault file containing the literal string "null" (or truly empty —
    # zero bytes) has yq type !!null and previously crashed the entire list.
    # Both forms should produce "(empty)" without aborting iteration.

    # Case 1: file containing the YAML null literal
    printf 'null' > "${COFFER_VAULT}/nullcontent.yaml"
    # Case 2: zero-byte file (empty)
    : > "${COFFER_VAULT}/zerobyte.yaml"
    # Case 3: a normal file AFTER the bad ones, to confirm iteration continues
    cat > "${COFFER_VAULT}/afternull.yaml" <<'YAML'
another-key: ENC[AES256_GCM,data:abc]
sops:
  lastmodified: "2026-04-07T00:00:00Z"
YAML

    # shellcheck source=../lib/list.sh
    source "${COFFER_ROOT}/lib/list.sh"
    local output rc=0
    output=$(cmd_list 2>/dev/null) || rc=$?

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: cmd_list exited ${rc} on null/empty vault files (expected 0)"
        return 1
    fi
    # The null/empty categories must appear in output (not skipped silently)
    # and the subsequent healthy category must also appear.
    assert_contains "$output" "nullcontent/" "list should show null-content category" && \
    assert_contains "$output" "zerobyte/" "list should show zero-byte category" && \
    assert_contains "$output" "afternull/" "list should continue past null/empty to next category" && \
    assert_contains "$output" "another-key" "list should show keys in subsequent category"
}

# Bug B: machine name whitespace trimming must strip only leading/trailing
# whitespace, not everything from the first space onward.
# Regression: "coffer init" typed at the machine-name prompt became "coffer"
# (the %%[[:space:]]* pattern killed everything after the first space).

test_onboard_whitespace_machine_name_internal_space() {
    # A machine-name containing an internal space ("my laptop") must survive
    # the trim step with the space intact, then be converted to "my-laptop"
    # by the sanitization step (tr replaces spaces with hyphens).
    if ! command -v age-keygen >/dev/null 2>&1; then
        echo "  SKIP (age-keygen not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    local config_dir="${sandbox}/config"
    local vault_dir="${sandbox}/vault"
    mkdir -p "$config_dir" "$vault_dir"

    local keygen_out
    keygen_out=$(age-keygen 2>&1)
    local pub_key
    pub_key=$(printf '%s\n' "$keygen_out" | grep -oE 'age1[a-z0-9]+' | head -1)
    local secret_key
    secret_key=$(printf '%s\n' "$keygen_out" | grep '^AGE-SECRET-KEY-')

    printf '%s\n' "$secret_key" > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"
    printf '%s\n' "$pub_key" > "${config_dir}/public-key"
    # Machine name with internal space — the key regression case
    printf 'my laptop\n' > "${config_dir}/machine-name"

    # shellcheck disable=SC2030,SC2031
    (
        export COFFER_ROOT="${SCRIPT_DIR}/.."
        export COFFER_CONFIG_DIR="$config_dir"
        export COFFER_SESSION_KEY="${config_dir}/.session-key"
        export COFFER_VAULT="$vault_dir"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        # shellcheck source=../lib/common.sh
        source "${COFFER_ROOT}/lib/common.sh"
        # shellcheck source=../lib/onboard.sh
        source "${COFFER_ROOT}/lib/onboard.sh"
        # shellcheck disable=SC2119
        cmd_onboard
    ) 2>/dev/null

    # Sanitization converts internal space to hyphen: "my laptop" → "my-laptop"
    local pending_file="${vault_dir}/.pending-recipient-my-laptop.pub"
    local ok=0
    [[ -f "$pending_file" ]] && ok=1
    rm -rf "$sandbox"

    if [[ $ok -eq 0 ]]; then
        echo "  FAIL: expected pending file .pending-recipient-my-laptop.pub (space→hyphen);"
        echo "        old bug would have created .pending-recipient-my.pub (truncated)"
        return 1
    fi
    return 0
}

test_onboard_whitespace_machine_name_leading_trailing() {
    # A machine-name file with leading/trailing whitespace (e.g., " verve ")
    # should be trimmed to "verve", not produce " verve" or "verve " as the
    # pending filename.
    if ! command -v age-keygen >/dev/null 2>&1; then
        echo "  SKIP (age-keygen not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    local config_dir="${sandbox}/config"
    local vault_dir="${sandbox}/vault"
    mkdir -p "$config_dir" "$vault_dir"

    local keygen_out
    keygen_out=$(age-keygen 2>&1)
    local pub_key
    pub_key=$(printf '%s\n' "$keygen_out" | grep -oE 'age1[a-z0-9]+' | head -1)
    local secret_key
    secret_key=$(printf '%s\n' "$keygen_out" | grep '^AGE-SECRET-KEY-')

    printf '%s\n' "$secret_key" > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"
    printf '%s\n' "$pub_key" > "${config_dir}/public-key"
    # Leading and trailing spaces around a simple name
    printf '  verve  \n' > "${config_dir}/machine-name"

    # shellcheck disable=SC2030,SC2031
    (
        export COFFER_ROOT="${SCRIPT_DIR}/.."
        export COFFER_CONFIG_DIR="$config_dir"
        export COFFER_SESSION_KEY="${config_dir}/.session-key"
        export COFFER_VAULT="$vault_dir"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        source "${COFFER_ROOT}/lib/common.sh"
        source "${COFFER_ROOT}/lib/onboard.sh"
        # shellcheck disable=SC2119
        cmd_onboard
    ) 2>/dev/null

    local pending_file="${vault_dir}/.pending-recipient-verve.pub"
    local ok=0
    [[ -f "$pending_file" ]] && ok=1
    rm -rf "$sandbox"

    if [[ $ok -eq 0 ]]; then
        echo "  FAIL: expected pending file .pending-recipient-verve.pub after leading/trailing trim"
        return 1
    fi
    return 0
}

# --- Get error case tests ---

test_get_missing_category_fails() {
    # shellcheck source=../lib/get.sh
    source "${COFFER_ROOT}/lib/get.sh"

    # require_identity now checks the session-key file (post Option 2
    # refactor), so seed one. ensure_unlocked short-circuits because we
    # export SOPS_AGE_KEY below, so the fake file's contents don't need
    # to be a real key for this test.
    seed_fake_identity
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

# --- Set: recipient preservation (regression test for the April 2026 lockout) ---
#
# Bug: cmd_set called `sops encrypt --age <single-pubkey>`, which overrode the
# .sops.yaml multi-recipient list and silently re-encrypted with only the
# writing machine's key. Any cross-machine `coffer set` then locked the other
# machine out of that category file. Caught after Wiles couldn't decrypt
# cloudflare/* and ai/* (last-written-on-Verve) on 2026-04-19.
#
# Fix: drop --age, use SOPS_CONFIG + --filename-override so all recipients
# from .sops.yaml are applied to both new-file and update paths.

test_set_preserves_all_recipients_on_create() {
    if ! command -v age-keygen >/dev/null || ! command -v sops >/dev/null; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    # Two test identities — one is "this machine" (A), the other is "remote" (B).
    age-keygen -o "${sandbox}/keyA.txt" 2>/dev/null
    age-keygen -o "${sandbox}/keyB.txt" 2>/dev/null
    local pub_a pub_b
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')
    pub_b=$(grep "public key" "${sandbox}/keyB.txt" | awk '{print $4}')

    mkdir -p "${sandbox}/vault" "${sandbox}/config" "${sandbox}/.coffer-config"
    cat > "${sandbox}/config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: vault/.*\.yaml\$
    age: >-
      ${pub_a},${pub_b}
EOF
    echo "$pub_a" > "${sandbox}/.coffer-config/public-key"

    # Run cmd_set in a subshell with all the env coffer would normally set.
    (
        export SOPS_AGE_KEY
        SOPS_AGE_KEY=$(grep AGE-SECRET "${sandbox}/keyA.txt")
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/test.yaml"
        export COFFER_CATEGORY="test"
        export COFFER_KEY="key1"
        export COFFER_CONFIG_DIR="${sandbox}/.coffer-config"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"

        # Stub out helpers from common.sh that we're not testing here.
        die() { echo "die: $*" >&2; exit 1; }
        log() { :; }
        warn() { :; }
        require_cmd() { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked() { :; }
        parse_path() { :; }

        # shellcheck source=../lib/set.sh
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/set.sh"
        cmd_set test/key1 "value-1"
    ) || { rm -rf "$sandbox"; return 1; }

    local count
    count=$(grep -c "recipient:" "${sandbox}/vault/test.yaml")
    rm -rf "$sandbox"
    assert_eq "2" "$count" "create path should preserve both recipients from .sops.yaml"
}

test_set_preserves_all_recipients_on_update() {
    if ! command -v age-keygen >/dev/null || ! command -v sops >/dev/null; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    age-keygen -o "${sandbox}/keyA.txt" 2>/dev/null
    age-keygen -o "${sandbox}/keyB.txt" 2>/dev/null
    local pub_a pub_b
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')
    pub_b=$(grep "public key" "${sandbox}/keyB.txt" | awk '{print $4}')

    mkdir -p "${sandbox}/vault" "${sandbox}/config" "${sandbox}/.coffer-config"
    cat > "${sandbox}/config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: vault/.*\.yaml\$
    age: >-
      ${pub_a},${pub_b}
EOF
    echo "$pub_a" > "${sandbox}/.coffer-config/public-key"

    (
        export SOPS_AGE_KEY
        SOPS_AGE_KEY=$(grep AGE-SECRET "${sandbox}/keyA.txt")
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/test.yaml"
        export COFFER_CATEGORY="test"
        export COFFER_CONFIG_DIR="${sandbox}/.coffer-config"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"

        die() { echo "die: $*" >&2; exit 1; }
        log() { :; }
        warn() { :; }
        require_cmd() { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked() { :; }
        parse_path() { :; }

        # shellcheck source=../lib/set.sh
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/set.sh"

        export COFFER_KEY="first"
        cmd_set test/first "value-1"
        export COFFER_KEY="second"
        cmd_set test/second "value-2"   # exercises the update path

        # Critical assertion: the OTHER key (B) must still decrypt — proves
        # we didn't strip its recipient on the update.
        SOPS_AGE_KEY=$(grep AGE-SECRET "${sandbox}/keyB.txt") sops decrypt \
            --extract '["first"]' "${sandbox}/vault/test.yaml" >/dev/null \
            || die "key B locked out — update stripped its recipient"
    ) || { rm -rf "$sandbox"; return 1; }

    local count
    count=$(grep -c "recipient:" "${sandbox}/vault/test.yaml")
    rm -rf "$sandbox"
    assert_eq "2" "$count" "update path should preserve both recipients from .sops.yaml"
}

# --- Identity: Option 2 (file-only, no Keychain) tests ---
#
# These tests cover the April 2026 refactor that made ~/.config/coffer/.session-key
# the single source of truth for coffer's identity. The previous dual-path
# design (file OR Keychain) produced real bugs in SSH-spawned shells where
# Keychain access is denied by default. The tests below simulate that
# "headless / no-Keychain" context by running coffer in a bash subshell
# with no access to `security` helpers (we don't actually strip `security`
# from PATH — we just never invoke it in the new code path, which is the
# point of the refactor).

test_require_identity_passes_with_file() {
    # Happy path: session-key file present, require_identity returns 0.
    seed_fake_identity
    local output
    output=$(bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"${COFFER_SESSION_KEY}"'"
        require_identity
        echo "ok"
    ' 2>&1)
    assert_contains "$output" "ok" "require_identity should succeed when session-key file exists"
}

test_require_identity_fails_without_file() {
    # Missing file: require_identity dies with an actionable message that
    # mentions `coffer init` so the user knows exactly what to do.
    local missing="${COFFER_CONFIG_DIR}/no-such-file"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"$missing"'"
        require_identity
    ' 2>&1) || true
    assert_contains "$output" "No identity found" "require_identity should fail loudly when file is missing" && \
    assert_contains "$output" "coffer init" "error message should tell the user to run coffer init"
}

test_require_identity_fails_on_empty_file() {
    # Zero-byte file is a corruption case, not a "missing" one. We want a
    # distinct, actionable error rather than silently falling through.
    mkdir -p "${COFFER_CONFIG_DIR}"
    : > "${COFFER_SESSION_KEY}"
    chmod 600 "${COFFER_SESSION_KEY}"

    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"${COFFER_SESSION_KEY}"'"
        require_identity
    ' 2>&1) || true
    assert_contains "$output" "empty" "require_identity should call out empty identity files"
}

test_ensure_unlocked_loads_from_file() {
    # This is the SSH / headless regression test: with NO SOPS_AGE_KEY in
    # the environment and NO Keychain access, ensure_unlocked must pick up
    # the key from the session-key file. Before Option 2 this worked on some
    # contexts and failed on SSH-spawned shells; now there's only one path.
    seed_fake_identity
    local output
    output=$(bash -c '
        unset SOPS_AGE_KEY
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"${COFFER_SESSION_KEY}"'"
        ensure_unlocked
        echo "key=${SOPS_AGE_KEY:0:16}"
    ' 2>&1)
    assert_contains "$output" "key=AGE-SECRET-KEY-" "ensure_unlocked should export SOPS_AGE_KEY from file"
}

test_ensure_unlocked_prefers_env_var() {
    # If SOPS_AGE_KEY is already set (e.g., user ran `eval $(coffer unlock)`
    # in the parent shell), ensure_unlocked must trust it and not rewrite
    # it from the file. This keeps `eval $(coffer unlock)` idempotent and
    # also supports alternative identity delivery (e.g., passed through an
    # LDAP-fed env var in a job runner).
    seed_fake_identity
    local output
    output=$(bash -c '
        export SOPS_AGE_KEY="AGE-SECRET-KEY-FROM-ENV"
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"${COFFER_SESSION_KEY}"'"
        ensure_unlocked
        echo "${SOPS_AGE_KEY}"
    ' 2>&1)
    assert_contains "$output" "AGE-SECRET-KEY-FROM-ENV" "ensure_unlocked should not overwrite a pre-set SOPS_AGE_KEY"
}

test_ensure_unlocked_fails_without_file_or_env() {
    # Nothing in env, no file: must die with the same actionable message
    # as require_identity so the user isn't chasing a mysterious "locked".
    local missing="${COFFER_CONFIG_DIR}/no-such-file"
    local output
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        unset SOPS_AGE_KEY
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        export COFFER_SESSION_KEY="'"$missing"'"
        ensure_unlocked
    ' 2>&1) || true
    assert_contains "$output" "No identity found" "ensure_unlocked should fail loudly when identity is missing" && \
    assert_contains "$output" "coffer init" "error should tell the user how to fix it"
}

test_no_keychain_calls_in_library() {
    # Structural check: the refactor's whole point is to kill Keychain
    # dependency. If someone reintroduces a `security find-generic-password`
    # call in the library, this test catches it before the diff lands.
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"
    local hits
    hits=$(grep -l 'security find-generic-password\|security add-generic-password\|security delete-generic-password' \
        "${real_root}/bin/coffer" "${real_root}"/lib/*.sh 2>/dev/null || true)
    assert_eq "" "$hits" "no library/bin file should call the macOS 'security' helper"
}

test_unlock_reads_from_file() {
    # `coffer unlock` emits `export SOPS_AGE_KEY=...` from the file. This
    # smoke-tests the dispatcher path, not just the library function.
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    seed_fake_identity
    local output
    output=$(COFFER_SESSION_KEY="${COFFER_SESSION_KEY}" \
             COFFER_NTFY_TOPIC="http://localhost:1/fake" \
             bash "${real_root}/bin/coffer" unlock 2>/dev/null) || true
    assert_contains "$output" "export SOPS_AGE_KEY=" "coffer unlock should emit an export statement when the file exists"
}

test_unlock_auto_is_noop() {
    # --auto is retained as a no-op for LaunchAgent backward compatibility.
    # It must exit 0 without emitting an export (nothing to eval).
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    seed_fake_identity
    local stdout
    stdout=$(COFFER_SESSION_KEY="${COFFER_SESSION_KEY}" \
             COFFER_NTFY_TOPIC="http://localhost:1/fake" \
             bash "${real_root}/bin/coffer" unlock --auto 2>/dev/null) || true
    # stdout should be empty (no export); the informational log goes to stderr.
    assert_eq "" "$stdout" "coffer unlock --auto should not emit stdout (it's a no-op)"
}

# --- Onboard tests ---
#
# These tests cover the vault-dir-as-transport bootstrap flow introduced in
# the 2026-04-22 multi-machine fix. They simulate a "new machine" by overriding
# COFFER_CONFIG_DIR and COFFER_SESSION_KEY to a fresh temp directory, then
# verify that .pending-recipient-*.pub appears (or doesn't) as expected.

test_onboard_writes_pending_file() {
    # Happy path: machine has an identity, onboard should write the pending file.
    # We seed a real age keypair (age-keygen) so the pubkey passes the regex.
    if ! command -v age-keygen >/dev/null 2>&1; then
        echo "  SKIP (age-keygen not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)

    # Generate a real keypair into the sandbox config dir.
    local config_dir="${sandbox}/config"
    local vault_dir="${sandbox}/vault"
    mkdir -p "$config_dir" "$vault_dir"

    local keygen_out
    keygen_out=$(age-keygen 2>&1)
    local pub_key
    pub_key=$(printf '%s\n' "$keygen_out" | grep -oE 'age1[a-z0-9]+' | head -1)
    local secret_key
    secret_key=$(printf '%s\n' "$keygen_out" | grep '^AGE-SECRET-KEY-')

    printf '%s\n' "$secret_key" > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"
    printf '%s\n' "$pub_key" > "${config_dir}/public-key"
    printf 'test-machine\n' > "${config_dir}/machine-name"

    # Source onboard.sh with sandbox env; stub out the sub-invocation of init
    # (not needed since the identity already exists) and other helpers.
    # shellcheck disable=SC2030,SC2031
    (
        export COFFER_ROOT="${SCRIPT_DIR}/.."
        export COFFER_CONFIG_DIR="$config_dir"
        export COFFER_SESSION_KEY="${config_dir}/.session-key"
        export COFFER_VAULT="$vault_dir"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        # shellcheck source=../lib/common.sh
        source "${COFFER_ROOT}/lib/common.sh"
        # shellcheck source=../lib/onboard.sh
        source "${COFFER_ROOT}/lib/onboard.sh"

        # shellcheck disable=SC2119
        cmd_onboard
    ) 2>/dev/null

    local pending_file="${vault_dir}/.pending-recipient-test-machine.pub"
    local found=0
    [[ -f "$pending_file" ]] && found=1

    # Check content matches the generated pubkey.
    local content_ok=0
    if [[ $found -eq 1 ]]; then
        local file_content
        file_content=$(< "$pending_file")
        file_content="${file_content%%[[:space:]]*}"
        [[ "$file_content" == "$pub_key" ]] && content_ok=1
    fi

    rm -rf "$sandbox"

    if [[ $found -eq 0 ]]; then
        echo "  FAIL: .pending-recipient-test-machine.pub was not created"
        return 1
    fi
    if [[ $content_ok -eq 0 ]]; then
        echo "  FAIL: pending file content does not match the pubkey"
        return 1
    fi
    return 0
}

test_onboard_skips_init_if_identity_exists() {
    # If the session-key file already exists and is non-empty, onboard must NOT
    # attempt to re-run init (which would prompt the user for a machine name
    # and block the test). We confirm by checking that onboard exits 0 without
    # any die() and that the pending file still appears.
    if ! command -v age-keygen >/dev/null 2>&1; then
        echo "  SKIP (age-keygen not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    local config_dir="${sandbox}/config"
    local vault_dir="${sandbox}/vault"
    mkdir -p "$config_dir" "$vault_dir"

    local keygen_out
    keygen_out=$(age-keygen 2>&1)
    local pub_key
    pub_key=$(printf '%s\n' "$keygen_out" | grep -oE 'age1[a-z0-9]+' | head -1)
    local secret_key
    secret_key=$(printf '%s\n' "$keygen_out" | grep '^AGE-SECRET-KEY-')

    printf '%s\n' "$secret_key" > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"
    printf '%s\n' "$pub_key" > "${config_dir}/public-key"
    printf 'existing-machine\n' > "${config_dir}/machine-name"

    local rc=0
    # shellcheck disable=SC2030,SC2031
    (
        export COFFER_ROOT="${SCRIPT_DIR}/.."
        export COFFER_CONFIG_DIR="$config_dir"
        export COFFER_SESSION_KEY="${config_dir}/.session-key"
        export COFFER_VAULT="$vault_dir"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        source "${COFFER_ROOT}/lib/common.sh"
        source "${COFFER_ROOT}/lib/onboard.sh"
        # shellcheck disable=SC2119
        cmd_onboard
    ) 2>/dev/null || rc=$?

    local pending_file="${vault_dir}/.pending-recipient-existing-machine.pub"
    local ok=0
    [[ -f "$pending_file" ]] && ok=1
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: cmd_onboard exited ${rc} (expected 0) when identity exists"
        return 1
    fi
    if [[ $ok -eq 0 ]]; then
        echo "  FAIL: pending file not created even though identity exists"
        return 1
    fi
    return 0
}

test_finalize_onboard_no_pending_files() {
    # When there are no .pending-recipient-*.pub files, finalize-onboard should
    # print "No pending recipients." and exit 0.
    local sandbox
    sandbox=$(mktemp -d)
    local vault_dir="${sandbox}/vault"
    mkdir -p "$vault_dir"

    local output rc=0
    output=$(
        COFFER_ROOT="${SCRIPT_DIR}/.." \
        COFFER_VAULT="$vault_dir" \
        COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        COFFER_CONFIG_DIR="${sandbox}/config" \
        COFFER_SESSION_KEY="${sandbox}/config/.session-key" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/onboard.sh"'"
            # ensure_unlocked would fail with no identity; stub it since
            # finalize-onboard only calls it before processing files.
            # Since there are no files, it never reaches ensure_unlocked in the loop.
            ensure_unlocked() { return 0; }
            require_cmd() { return 0; }
            cmd_finalize_onboard
        ' 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: finalize-onboard exited ${rc} (expected 0) with no pending files"
        echo "    output: $output"
        return 1
    fi
    assert_contains "$output" "No pending recipients" "finalize-onboard should report nothing to do"
}

test_onboard_rejects_unknown_args() {
    local output rc=0
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        source "'"${COFFER_ROOT}/lib/onboard.sh"'"
        cmd_onboard --bogus-flag
    ' 2>&1) || rc=$?
    assert_contains "$output" "Unknown argument" "onboard should reject unknown flags"
}

test_finalize_onboard_rejects_unknown_args() {
    local output rc=0
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" bash -c '
        source "'"${COFFER_ROOT}/lib/common.sh"'"
        source "'"${COFFER_ROOT}/lib/onboard.sh"'"
        cmd_finalize_onboard --bogus-flag
    ' 2>&1) || rc=$?
    assert_contains "$output" "Unknown argument" "finalize-onboard should reject unknown flags"
}

test_lock_does_not_delete_file() {
    # Regression guard: `coffer lock` must leave the session-key file alone
    # because the file IS the persistent identity. Wiping it would force
    # a re-init on every "lock" which defeats the command's purpose.
    local real_root
    real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    seed_fake_identity
    COFFER_SESSION_KEY="${COFFER_SESSION_KEY}" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash "${real_root}/bin/coffer" lock >/dev/null 2>&1 || true
    if [[ -f "${COFFER_SESSION_KEY}" ]]; then
        return 0
    else
        echo "  FAIL: coffer lock deleted the session-key file"
        return 1
    fi
}

# =============================================================================
# --- Doctor and auto-sync tests ---
#
# These tests cover the drift-detection and auto-commit infrastructure added
# in feat/doctor-and-auto-sync (April 2026) to prevent a recurrence of the
# .sops.yaml/vault-file recipient mismatch bug.
# =============================================================================

# Helper: build a minimal test git repo with age keypairs and a .sops.yaml
# so doctor and preflight tests have something realistic to work with.
# Usage:  _setup_doctor_sandbox <sandbox_path>
# Sets:   DOCTOR_SANDBOX_VAULT, DOCTOR_SANDBOX_CONFIG, DOCTOR_SANDBOX_SOPS
#         DOCTOR_SANDBOX_PUBA, DOCTOR_SANDBOX_PRIK_A (for signing)
_setup_doctor_sandbox() {
    local sandbox="$1"
    local config_dir="${sandbox}/config"
    local vault_dir="${sandbox}/vault"
    local git_dir="${sandbox}/repo"

    mkdir -p "$config_dir" "$vault_dir" "$git_dir"

    # Generate two age keypairs so we can simulate multi-recipient scenarios
    age-keygen -o "${sandbox}/keyA.txt" 2>/dev/null
    age-keygen -o "${sandbox}/keyB.txt" 2>/dev/null

    local pub_a pub_b
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')
    pub_b=$(grep "public key" "${sandbox}/keyB.txt" | awk '{print $4}')

    # Write .sops.yaml with BOTH keys as canonical recipients
    local sops_config="${config_dir}/.sops.yaml"
    cat > "$sops_config" <<EOF
creation_rules:
  - path_regex: vault/.*\\.yaml\$
    age: >-
      ${pub_a},${pub_b}
EOF

    # Write the machine identity as key A (simulating "this machine")
    printf '%s\n' "$pub_a" > "${config_dir}/public-key"
    printf 'test-machine\n' > "${config_dir}/machine-name"
    printf '%s\n' "$(grep AGE-SECRET "${sandbox}/keyA.txt")" > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"

    # NOTE: We do NOT initialize a git repo here. The doctor's git checks
    # are skipped when COFFER_VAULT_ROOT has no .git directory. Vault-drift
    # tests focus on recipient set comparison, not git state. The auto_sync_push
    # tests create their own git sandboxes independently.

    # Export the paths that callers need. Key files are accessed via
    # the `sandbox` variable in each test function body (no export needed since
    # the helper runs in the same shell scope, not a subshell).
    DOCTOR_SANDBOX_VAULT="$vault_dir"
    DOCTOR_SANDBOX_CONFIG="$config_dir"
    DOCTOR_SANDBOX_SOPS="$sops_config"
    # DOCTOR_SANDBOX_ROOT is the directory that COFFER_VAULT_ROOT should point at
    # in test subshells. The sandbox dir contains config/ and vault/ at the
    # expected relative positions.
    DOCTOR_SANDBOX_ROOT="$sandbox"
}

# a. coffer doctor on a clean vault exits 0 with correct output.
test_doctor_clean_vault_exits_zero() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    _setup_doctor_sandbox "$sandbox"

    # Encrypt one vault file with BOTH keys so doctor has something to check
    local sops_age_key
    sops_age_key=$(grep AGE-SECRET "${sandbox}/keyA.txt")

    jq -n '{"test-key": "test-value"}' \
        | SOPS_AGE_KEY="$sops_age_key" \
          SOPS_CONFIG="$DOCTOR_SANDBOX_SOPS" \
          sops encrypt \
            --filename-override "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" \
            --input-type json --output-type yaml \
            /dev/stdin > "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" 2>/dev/null \
        || { rm -rf "$sandbox"; echo "  SKIP (sops encrypt failed)"; return 0; }

    local output rc=0
    output=$(
        COFFER_VAULT_ROOT="${DOCTOR_SANDBOX_ROOT}" \
        COFFER_ROOT="${sandbox}" \
        COFFER_VAULT="${DOCTOR_SANDBOX_VAULT}" \
        COFFER_SOPS_CONFIG="${DOCTOR_SANDBOX_SOPS}" \
        COFFER_CONFIG_DIR="${DOCTOR_SANDBOX_CONFIG}" \
        COFFER_SESSION_KEY="${DOCTOR_SANDBOX_CONFIG}/.session-key" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/doctor.sh"'"
            cmd_doctor
        ' 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    # All vault files match .sops.yaml: should exit 0
    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: doctor exited ${rc} on a clean vault (expected 0)"
        echo "    output: ${output}"
        return 1
    fi
    assert_contains "$output" "[OK]" "doctor should print at least one [OK] line" && \
    assert_contains "$output" "all checks passed" "doctor should report all checks passed"
}

# b. coffer doctor on a drifted vault exits 1 with specific drift output.
test_doctor_drifted_vault_exits_one() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    _setup_doctor_sandbox "$sandbox"

    # Encrypt a vault file with ONLY key A — simulating a write that happened
    # before key B was added (i.e., the vault file has fewer recipients than .sops.yaml)
    local sops_age_key
    sops_age_key=$(grep AGE-SECRET "${sandbox}/keyA.txt")
    local pub_a
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')

    # Write a temporary single-recipient .sops.yaml just for the encrypt step
    local single_sops="${sandbox}/single.sops.yaml"
    cat > "$single_sops" <<EOF
creation_rules:
  - path_regex: vault/.*\\.yaml\$
    age: >-
      ${pub_a}
EOF

    jq -n '{"test-key": "test-value"}' \
        | SOPS_AGE_KEY="$sops_age_key" \
          SOPS_CONFIG="$single_sops" \
          sops encrypt \
            --filename-override "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" \
            --input-type json --output-type yaml \
            /dev/stdin > "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" 2>/dev/null \
        || { rm -rf "$sandbox"; echo "  SKIP (sops encrypt failed)"; return 0; }

    # Now the vault file has 1 recipient (key A) but .sops.yaml lists 2 (A + B)
    # This is exactly the drift condition doctor must catch.
    local output rc=0
    output=$(
        COFFER_VAULT_ROOT="${DOCTOR_SANDBOX_ROOT}" \
        COFFER_ROOT="${sandbox}" \
        COFFER_VAULT="${DOCTOR_SANDBOX_VAULT}" \
        COFFER_SOPS_CONFIG="${DOCTOR_SANDBOX_SOPS}" \
        COFFER_CONFIG_DIR="${DOCTOR_SANDBOX_CONFIG}" \
        COFFER_SESSION_KEY="${DOCTOR_SANDBOX_CONFIG}/.session-key" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/doctor.sh"'"
            cmd_doctor
        ' 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    # Must exit 1 (drift found)
    if [[ $rc -ne 1 ]]; then
        echo "  FAIL: doctor exited ${rc} on a drifted vault (expected 1)"
        echo "    output: ${output}"
        return 1
    fi
    assert_contains "$output" "[DRIFT]" "doctor should print at least one [DRIFT] line" && \
    assert_contains "$output" "issue(s) found" "doctor should report issues found"
}

# c. auto_sync_push with COFFER_AUTO_SYNC=0 skips all git ops.
test_auto_sync_push_disabled_by_env() {
    local sandbox
    sandbox=$(mktemp -d)

    # Init a git repo (needs to be a repo to test auto_sync_push behavior).
    # The sandbox acts as COFFER_VAULT_ROOT (the vault data repo), not COFFER_ROOT
    # (the tool code repo). auto_sync_push now targets COFFER_VAULT_ROOT.
    git -C "$sandbox" init -q
    git -C "$sandbox" config user.email "test@test.local"
    git -C "$sandbox" config user.name "Test"
    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    touch "${sandbox}/vault/test.yaml"
    git -C "$sandbox" add . 2>/dev/null
    git -C "$sandbox" commit -m "initial" -q

    # Modify a file so there would be something to stage
    echo "change" > "${sandbox}/vault/test.yaml"

    local output rc=0
    output=$(
        COFFER_AUTO_SYNC=0 \
        COFFER_VAULT_ROOT="$sandbox" \
        COFFER_ROOT="$sandbox" \
        COFFER_VAULT="${sandbox}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_push "test commit"
        ' 2>&1
    ) || rc=$?

    # Verify no new commit was made
    local commit_count
    commit_count=$(git -C "$sandbox" rev-list --count HEAD 2>/dev/null || echo 0)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_push exited ${rc} with COFFER_AUTO_SYNC=0 (expected 0)"
        return 1
    fi
    assert_contains "$output" "COFFER_AUTO_SYNC=0" "should log that auto-sync is disabled" && \
    assert_eq "1" "$commit_count" "should not have committed anything (still just initial commit)"
}

# d. auto_sync_push on a non-main branch commits locally but does NOT push.
test_auto_sync_push_non_main_commits_only() {
    local sandbox
    sandbox=$(mktemp -d)

    # Set up a git repo on a non-main branch. The sandbox is COFFER_VAULT_ROOT
    # (the vault data repo) -- auto_sync_push now targets COFFER_VAULT_ROOT.
    git -C "$sandbox" init -q
    git -C "$sandbox" config user.email "test@test.local"
    git -C "$sandbox" config user.name "Test"
    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    echo "initial" > "${sandbox}/vault/test.yaml"
    cat > "${sandbox}/config/.sops.yaml" <<'SOPSEOF'
creation_rules:
  - path_regex: vault/.*\.yaml$
    age: >-
      age1test123
SOPSEOF
    git -C "$sandbox" add . 2>/dev/null
    git -C "$sandbox" commit -m "initial" -q
    git -C "$sandbox" checkout -b feat/not-main -q

    # Make a change to vault/
    echo "modified" > "${sandbox}/vault/test.yaml"

    local output rc=0
    output=$(
        COFFER_AUTO_SYNC=1 \
        COFFER_VAULT_ROOT="$sandbox" \
        COFFER_ROOT="$sandbox" \
        COFFER_VAULT="${sandbox}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_push "test change"
        ' 2>&1
    ) || rc=$?

    local commit_count
    commit_count=$(git -C "$sandbox" rev-list --count HEAD 2>/dev/null || echo 0)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_push exited ${rc} on non-main branch (expected 0)"
        echo "    output: ${output}"
        return 1
    fi
    # Must have committed (commit_count should be 2: initial + the auto-commit)
    if [[ "$commit_count" -lt 2 ]]; then
        echo "  FAIL: expected at least 2 commits (initial + auto), got ${commit_count}"
        return 1
    fi
    assert_contains "$output" "not 'main'" "should warn about non-main branch" && \
    # Push must NOT have been attempted (no remote configured, so we just
    # verify the warning appears — if push were attempted, it would error out
    # loudly since there's no remote, and rc would be non-zero)
    return 0
}

# e. preflight_recipient_check refuses write when drift is detected.
test_preflight_blocks_write_on_drift() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    _setup_doctor_sandbox "$sandbox"

    # Encrypt a vault file with ONLY key A (drifted: .sops.yaml has A + B)
    local sops_age_key
    sops_age_key=$(grep AGE-SECRET "${sandbox}/keyA.txt")
    local pub_a
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')

    local single_sops="${sandbox}/single.sops.yaml"
    cat > "$single_sops" <<EOF
creation_rules:
  - path_regex: vault/.*\\.yaml\$
    age: >-
      ${pub_a}
EOF

    jq -n '{"test-key": "test-value"}' \
        | SOPS_AGE_KEY="$sops_age_key" \
          SOPS_CONFIG="$single_sops" \
          sops encrypt \
            --filename-override "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" \
            --input-type json --output-type yaml \
            /dev/stdin > "${DOCTOR_SANDBOX_VAULT}/testcat.yaml" 2>/dev/null \
        || { rm -rf "$sandbox"; echo "  SKIP (sops encrypt failed)"; return 0; }

    # preflight_recipient_check should detect the drift and call die()
    local output rc=0
    output=$(
        COFFER_VAULT_ROOT="${DOCTOR_SANDBOX_ROOT}" \
        COFFER_ROOT="${sandbox}" \
        COFFER_VAULT="${DOCTOR_SANDBOX_VAULT}" \
        COFFER_SOPS_CONFIG="${DOCTOR_SANDBOX_SOPS}" \
        COFFER_CONFIG_DIR="${DOCTOR_SANDBOX_CONFIG}" \
        COFFER_SESSION_KEY="${DOCTOR_SANDBOX_CONFIG}/.session-key" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/doctor.sh"'"
            # Override die so we can capture the error without sending ntfy
            die() { echo "die: $*" >&2; exit 1; }
            preflight_recipient_check
        ' 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: preflight_recipient_check should have exited non-zero on a drifted vault"
        return 1
    fi
    assert_contains "$output" "inconsistent" "error should mention inconsistency" && \
    assert_contains "$output" "coffer doctor" "error should point the user to coffer doctor"
}

# =============================================================================
# --- auto_sync_pull tests (feat/auto-pull-before-write, April 2026) ---
#
# These tests cover the pre-write pull-rebase added to close the drift window
# that caused the April 2026 non-fast-forward push rejection. The failure mode:
#   1. Session starts, sync-pull runs (vault is current).
#   2. Other machine writes + pushes (origin advances).
#   3. This machine runs `coffer set` -- local commit + push rejected (non-ff).
#
# The fix: auto_sync_pull() runs BEFORE the write. These tests verify:
#   a. COFFER_AUTO_SYNC=0 suppresses the pull (escape hatch preserved).
#   b. No-op when already up to date (nothing staged unnecessarily).
#   c. Behind-origin: pull-rebase succeeds, log message emitted.
#   d. Rebase conflict: abort + die() loudly (don't proceed with corrupt state).
#   e. Local commits ahead: pushed before pull-rebase.
# =============================================================================

# Helper: create a bare "origin" repo and a local clone that is behind it.
# Usage: _setup_pull_sandbox <sandbox_path>
# Sets:  PULL_SANDBOX_LOCAL (the "local machine" clone)
#        PULL_SANDBOX_ORIGIN (the bare origin repo)
_setup_pull_sandbox() {
    local sandbox="$1"

    local origin_dir="${sandbox}/origin.git"
    local local_dir="${sandbox}/local"

    # Init a bare repo that acts as origin
    git init --bare -q "$origin_dir"
    git -C "$origin_dir" config user.email "test@test.local"
    git -C "$origin_dir" config user.name "Test"

    # Clone into local
    git clone -q "$origin_dir" "$local_dir" 2>/dev/null
    git -C "$local_dir" config user.email "test@test.local"
    git -C "$local_dir" config user.name "Test"

    # Create initial structure in local and push
    mkdir -p "${local_dir}/vault" "${local_dir}/config"
    cat > "${local_dir}/config/.sops.yaml" <<'SOPSEOF'
creation_rules:
  - path_regex: vault/.*\.yaml$
    age: >-
      age1placeholder000000000000000000000000000000000000000000000000
SOPSEOF
    echo "v1" > "${local_dir}/vault/secrets.yaml"
    git -C "$local_dir" add . 2>/dev/null
    git -C "$local_dir" commit -m "initial" -q
    git -C "$local_dir" push -q

    PULL_SANDBOX_LOCAL="$local_dir"
    PULL_SANDBOX_ORIGIN="$origin_dir"
}

# a. auto_sync_pull with COFFER_AUTO_SYNC=0 is a no-op.
test_auto_sync_pull_disabled_by_env() {
    local sandbox
    sandbox=$(mktemp -d)
    _setup_pull_sandbox "$sandbox"

    # Push a new commit to origin to make local behind
    local work_dir="${sandbox}/work"
    git clone -q "$PULL_SANDBOX_ORIGIN" "$work_dir" 2>/dev/null
    git -C "$work_dir" config user.email "test@test.local"
    git -C "$work_dir" config user.name "Test"
    echo "v2" > "${work_dir}/vault/secrets.yaml"
    git -C "$work_dir" add . 2>/dev/null
    git -C "$work_dir" commit -m "origin advance" -q
    git -C "$work_dir" push -q 2>/dev/null

    # Local should now be behind; but with COFFER_AUTO_SYNC=0 the pull is skipped
    local local_sha_before
    local_sha_before=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)

    local output rc=0
    output=$(
        COFFER_AUTO_SYNC=0 \
        COFFER_VAULT_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_VAULT="${PULL_SANDBOX_LOCAL}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_pull
        ' 2>&1
    ) || rc=$?

    local local_sha_after
    local_sha_after=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_pull exited ${rc} with COFFER_AUTO_SYNC=0 (expected 0)"
        return 1
    fi
    # HEAD must not have moved (pull was skipped)
    assert_eq "$local_sha_before" "$local_sha_after" "auto_sync_pull with COFFER_AUTO_SYNC=0 must not change HEAD"
}

# b. auto_sync_pull when already up to date is a no-op (fast path).
test_auto_sync_pull_noop_when_current() {
    local sandbox
    sandbox=$(mktemp -d)
    _setup_pull_sandbox "$sandbox"

    local local_sha_before
    local_sha_before=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)

    local rc=0
    (
        COFFER_AUTO_SYNC=1 \
        COFFER_VAULT_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_VAULT="${PULL_SANDBOX_LOCAL}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_pull
        ' 2>&1
    ) || rc=$?

    local local_sha_after
    local_sha_after=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_pull exited ${rc} when already up to date (expected 0)"
        return 1
    fi
    assert_eq "$local_sha_before" "$local_sha_after" "auto_sync_pull must not change HEAD when already current"
}

# c. auto_sync_pull successfully pulls when behind origin (drift recovery).
# This is the primary regression test for the April 2026 push-rejection bug.
test_auto_sync_pull_pulls_when_behind() {
    local sandbox
    sandbox=$(mktemp -d)
    _setup_pull_sandbox "$sandbox"

    # Push a new commit to origin to make local behind
    local work_dir="${sandbox}/work"
    git clone -q "$PULL_SANDBOX_ORIGIN" "$work_dir" 2>/dev/null
    git -C "$work_dir" config user.email "test@test.local"
    git -C "$work_dir" config user.name "Test"
    echo "v2" > "${work_dir}/vault/secrets.yaml"
    git -C "$work_dir" add . 2>/dev/null
    git -C "$work_dir" commit -m "origin advance" -q
    git -C "$work_dir" push -q 2>/dev/null

    local origin_sha
    origin_sha=$(git -C "$work_dir" rev-parse HEAD)

    local output rc=0
    output=$(
        COFFER_AUTO_SYNC=1 \
        COFFER_VAULT_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_VAULT="${PULL_SANDBOX_LOCAL}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_pull
        ' 2>&1
    ) || rc=$?

    local local_sha_after
    local_sha_after=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_pull exited ${rc} when behind origin (expected 0)"
        echo "    output: ${output}"
        return 1
    fi
    assert_eq "$origin_sha" "$local_sha_after" "auto_sync_pull must bring local HEAD to origin HEAD" && \
    assert_contains "$output" "synced" "auto_sync_pull should log that it synced commits"
}

# d. auto_sync_pull with a local commit ahead: pushes first, then stays current.
test_auto_sync_pull_pushes_local_ahead_commits() {
    local sandbox
    sandbox=$(mktemp -d)
    _setup_pull_sandbox "$sandbox"

    # Make a local commit that was never pushed (simulates prior session ending
    # before auto_sync_push completed)
    echo "local-only" > "${PULL_SANDBOX_LOCAL}/vault/local.yaml"
    git -C "$PULL_SANDBOX_LOCAL" add vault/ 2>/dev/null
    git -C "$PULL_SANDBOX_LOCAL" commit -m "unpushed local commit" -q

    local local_sha_before
    local_sha_before=$(git -C "$PULL_SANDBOX_LOCAL" rev-parse HEAD)

    local output rc=0
    output=$(
        COFFER_AUTO_SYNC=1 \
        COFFER_VAULT_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_ROOT="$PULL_SANDBOX_LOCAL" \
        COFFER_VAULT="${PULL_SANDBOX_LOCAL}/vault" \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        bash -c '
            source "'"${SCRIPT_DIR}/../lib/common.sh"'"
            source "'"${SCRIPT_DIR}/../lib/git-sync.sh"'"
            auto_sync_pull
        ' 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: auto_sync_pull exited ${rc} when local is ahead (expected 0)"
        echo "    output: ${output}"
        return 1
    fi
    assert_contains "$output" "not yet pushed" "should log about unpushed local commits"
}

# --- Main ---

# --- Delete command tests (feat/delete-command, May 2026) ---
#
# cmd_delete is tested via real age/sops when both tools are installed, and with
# a set of error-path unit tests that stub out the heavy crypto helpers (same
# pattern as the set/get error-path tests above). The SKIP guard mirrors the
# set recipient-preservation tests.

test_delete_removes_key() {
    # Happy path: set a key, then delete it; confirm the key is gone but other
    # keys in the same category survive.
    if ! command -v age-keygen >/dev/null || ! command -v sops >/dev/null; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    age-keygen -o "${sandbox}/key.txt" 2>/dev/null
    local pub_key
    pub_key=$(grep "public key" "${sandbox}/key.txt" | awk '{print $4}')
    local secret_key
    secret_key=$(grep "^AGE-SECRET-KEY-" "${sandbox}/key.txt")

    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    cat > "${sandbox}/config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: vault/.*\.yaml\$
    age: >-
      ${pub_key}
EOF

    # Create an initial vault file with two keys using cmd_set.
    (
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/testcat.yaml"
        export COFFER_CATEGORY="testcat"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        die()   { echo "die: $*" >&2; exit 1; }
        log()   { :; }
        warn()  { :; }
        require_cmd()    { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked()  { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }

        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/set.sh"
        cmd_set testcat/to-delete "gone"
        cmd_set testcat/to-keep   "stays"
    ) || { rm -rf "$sandbox"; echo "  FAIL: setup step failed"; return 1; }

    # Now delete one key, keeping the other.
    local rc=0
    (
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/testcat.yaml"
        export COFFER_CATEGORY="testcat"
        export COFFER_KEY="to-delete"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        die()   { echo "die: $*" >&2; exit 1; }
        log()   { :; }
        warn()  { :; }
        require_cmd()    { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked()  { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        list_categories() { ls "${COFFER_VAULT}"; }

        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/delete.sh"
        cmd_delete testcat/to-delete --yes
    ) || rc=$?

    if [[ $rc -ne 0 ]]; then
        rm -rf "$sandbox"
        echo "  FAIL: cmd_delete returned exit code ${rc}"
        return 1
    fi

    # Verify the deleted key is absent and the surviving key still decrypts.
    local has_to_delete has_to_keep
    has_to_delete=$(SOPS_AGE_KEY="$secret_key" sops decrypt --output-type json \
        "${sandbox}/vault/testcat.yaml" 2>/dev/null | jq 'has("to-delete")')
    has_to_keep=$(SOPS_AGE_KEY="$secret_key" sops decrypt --output-type json \
        "${sandbox}/vault/testcat.yaml" 2>/dev/null | jq 'has("to-keep")')
    rm -rf "$sandbox"

    assert_eq "false" "$has_to_delete" "deleted key must not exist after delete" && \
    assert_eq "true"  "$has_to_keep"   "surviving key must still be present after delete"
}

test_delete_preserves_recipients() {
    # Regression guard: deleting a key must re-encrypt with ALL recipients from
    # .sops.yaml, not just the writing machine's key (same class of bug that
    # caused the April 2026 lockout in cmd_set).
    if ! command -v age-keygen >/dev/null || ! command -v sops >/dev/null; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    age-keygen -o "${sandbox}/keyA.txt" 2>/dev/null
    age-keygen -o "${sandbox}/keyB.txt" 2>/dev/null
    local pub_a pub_b
    pub_a=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')
    pub_b=$(grep "public key" "${sandbox}/keyB.txt" | awk '{print $4}')
    local secret_a secret_b
    secret_a=$(grep "^AGE-SECRET-KEY-" "${sandbox}/keyA.txt")
    secret_b=$(grep "^AGE-SECRET-KEY-" "${sandbox}/keyB.txt")

    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    cat > "${sandbox}/config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: vault/.*\.yaml\$
    age: >-
      ${pub_a},${pub_b}
EOF

    # Seed the vault with two keys using key A.
    (
        export SOPS_AGE_KEY="$secret_a"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/multi.yaml"
        export COFFER_CATEGORY="multi"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        die()   { echo "die: $*" >&2; exit 1; }
        log()   { :; }
        warn()  { :; }
        require_cmd()    { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked()  { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/set.sh"
        cmd_set multi/keep-me "value"
        cmd_set multi/drop-me "old"
    ) || { rm -rf "$sandbox"; echo "  FAIL: setup step failed"; return 1; }

    # Delete one key using key A. The surviving file must still be decryptable
    # by key B (proving the recipient list was not stripped).
    (
        export SOPS_AGE_KEY="$secret_a"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/multi.yaml"
        export COFFER_CATEGORY="multi"
        export COFFER_KEY="drop-me"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        die()   { echo "die: $*" >&2; exit 1; }
        log()   { :; }
        warn()  { :; }
        require_cmd()    { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked()  { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        list_categories() { ls "${COFFER_VAULT}"; }

        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/delete.sh"
        cmd_delete multi/drop-me --yes
    ) || { rm -rf "$sandbox"; echo "  FAIL: delete step failed"; return 1; }

    # Key B must still be able to decrypt the surviving key.
    local rc=0
    SOPS_AGE_KEY="$secret_b" sops decrypt --extract '["keep-me"]' \
        "${sandbox}/vault/multi.yaml" >/dev/null 2>&1 || rc=$?

    local recipient_count
    recipient_count=$(grep -c "recipient:" "${sandbox}/vault/multi.yaml" 2>/dev/null || echo 0)
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: key B locked out after delete (recipient stripped)"
        return 1
    fi
    assert_eq "2" "$recipient_count" "delete must preserve both recipients in the re-encrypted file"
}

test_delete_missing_key_fails() {
    # Attempting to delete a key that does not exist must exit non-zero with a
    # clear error message. Silent success on a no-op delete is a footgun for
    # automation scripts that expect deletion to be idempotent.
    if ! command -v age-keygen >/dev/null || ! command -v sops >/dev/null; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    age-keygen -o "${sandbox}/key.txt" 2>/dev/null
    local pub_key secret_key
    pub_key=$(grep "public key" "${sandbox}/key.txt" | awk '{print $4}')
    secret_key=$(grep "^AGE-SECRET-KEY-" "${sandbox}/key.txt")

    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    cat > "${sandbox}/config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: vault/.*\.yaml\$
    age: >-
      ${pub_key}
EOF

    # Create a category with one key so the category file exists.
    (
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/cat.yaml"
        export COFFER_CATEGORY="cat"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        die()   { echo "die: $*" >&2; exit 1; }
        log()   { :; }
        warn()  { :; }
        require_cmd()    { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked()  { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/set.sh"
        cmd_set cat/existing "value"
    ) || { rm -rf "$sandbox"; echo "  FAIL: setup step failed"; return 1; }

    local output rc=0
    output=$(
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/cat.yaml"
        export COFFER_CATEGORY="cat"
        export COFFER_KEY="nonexistent"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        die()   { echo "die: $*" >&2; exit 1; }
        log()   { :; }
        warn()  { :; }
        require_cmd()    { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked()  { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        list_categories() { ls "${COFFER_VAULT}"; }

        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/delete.sh"
        cmd_delete cat/nonexistent --yes 2>&1
    ) || rc=$?
    rm -rf "$sandbox"

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: expected non-zero exit when key is absent, got 0"
        return 1
    fi
    assert_contains "$output" "not found" "error must mention 'not found' when key is absent"
}

test_delete_missing_category_fails() {
    # A missing category file must produce a non-zero exit and a clear error
    # (not a sops decrypt crash). This test does not need real crypto.
    setup_test_env
    seed_fake_identity
    # shellcheck source=../lib/delete.sh
    source "${COFFER_ROOT}/lib/delete.sh"

    local output rc=0
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" \
             SOPS_AGE_KEY="AGE-SECRET-KEY-fake" \
             cmd_delete "nocat/somekey" --yes 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: expected non-zero exit for missing category, got 0"
        return 1
    fi
    assert_contains "$output" "not found" "error must mention category 'not found'"
}

test_delete_no_args_fails() {
    # Calling cmd_delete with no arguments must exit non-zero with usage text.
    setup_test_env
    # shellcheck source=../lib/delete.sh
    source "${COFFER_ROOT}/lib/delete.sh"
    local output rc=0
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" \
             cmd_delete 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: expected non-zero exit when called with no args, got 0"
        return 1
    fi
    assert_contains "$output" "Usage" "no-args error must show usage"
}

test_delete_unknown_flag_fails() {
    setup_test_env
    # shellcheck source=../lib/delete.sh
    source "${COFFER_ROOT}/lib/delete.sh"
    local output rc=0
    output=$(COFFER_NTFY_TOPIC="http://localhost:1/fake" \
             cmd_delete "cat/key" --no-such-flag 2>&1) || rc=$?

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: expected non-zero exit for unknown flag, got 0"
        return 1
    fi
    assert_contains "$output" "Unknown flag" "unknown-flag error must name the bad flag"
}

test_delete_routed_by_dispatcher() {
    # Structural test: the bin/coffer dispatcher must route `coffer delete` to
    # cmd_delete (i.e., not fall through to "Unknown command"). We verify by
    # calling the real binary with a missing category -- the error from
    # cmd_delete ("not found") differs from the dispatcher's "Unknown command"
    # error, proving the route was found.
    local real_coffer
    real_coffer="$(cd "${SCRIPT_DIR}/.." && pwd)/bin/coffer"

    local sandbox
    sandbox=$(mktemp -d)
    # A minimal vault root with no vault files -- cmd_delete will die with
    # "Category ... not found" before it ever touches sops.
    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    cat > "${sandbox}/config/.sops.yaml" <<'SOPSEOF'
creation_rules:
  - path_regex: vault/.*\.yaml$
    age: >-
      age1placeholder000000000000000000000000000000000000000000000000
SOPSEOF

    local config_dir="${sandbox}/.coffer-config"
    mkdir -p "$config_dir"
    printf 'AGE-SECRET-KEY-FAKETESTFAKETESTFAKETESTFAKETESTFAKETEST\n' \
        > "${config_dir}/.session-key"
    chmod 600 "${config_dir}/.session-key"

    local output rc=0
    output=$(
        COFFER_VAULT_ROOT="$sandbox" \
        COFFER_CONFIG_DIR="$config_dir" \
        COFFER_SESSION_KEY="${config_dir}/.session-key" \
        COFFER_AUTO_SYNC=0 \
        COFFER_NTFY_TOPIC="http://localhost:1/fake" \
        SOPS_AGE_KEY="AGE-SECRET-KEY-fake" \
        bash "$real_coffer" delete nocat/nokey --yes 2>&1
    ) || rc=$?
    rm -rf "$sandbox"

    # Exit code must be non-zero (key/category not found), NOT because of an
    # "Unknown command" fallthrough (which would also be non-zero but with
    # different text). We verify the error is from cmd_delete, not the dispatcher.
    if echo "$output" | grep -q "Unknown command"; then
        echo "  FAIL: dispatcher did not route 'delete' -- got 'Unknown command'"
        return 1
    fi
    assert_contains "$output" "not found" \
        "dispatcher must route 'delete' to cmd_delete (category not found error expected)"
}

test_delete_round_trip_set_delete_get_fails() {
    # End-to-end round-trip: set a secret, delete it, then verify cmd_get
    # exits non-zero (i.e., the key really is gone from the user's perspective,
    # not just from the on-disk YAML). This is the canonical check from the
    # 2026-05-07 Apple SSO decommission ticket.
    if ! command -v age-keygen >/dev/null || ! command -v sops >/dev/null; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    age-keygen -o "${sandbox}/key.txt" 2>/dev/null
    local pub_key secret_key
    pub_key=$(grep "public key" "${sandbox}/key.txt" | awk '{print $4}')
    secret_key=$(grep "^AGE-SECRET-KEY-" "${sandbox}/key.txt")

    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    cat > "${sandbox}/config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: vault/.*\.yaml\$
    age: >-
      ${pub_key}
EOF

    # set
    (
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_VAULT_FILE="${sandbox}/vault/apple.yaml"
        export COFFER_CATEGORY="apple"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        die()   { echo "die: $*" >&2; exit 1; }
        log()   { :; }
        warn()  { :; }
        require_cmd()    { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked()  { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/set.sh"
        cmd_set apple/sso-token "secret-value-xyz"
    ) || { rm -rf "$sandbox"; echo "  FAIL: set step failed"; return 1; }

    # delete
    (
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        die()   { echo "die: $*" >&2; exit 1; }
        log()   { :; }
        warn()  { :; }
        require_cmd()    { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked()  { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        list_categories() { ls "${COFFER_VAULT}"; }
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/delete.sh"
        cmd_delete apple/sso-token --yes
    ) || { rm -rf "$sandbox"; echo "  FAIL: delete step failed"; return 1; }

    # get must now fail
    local rc=0
    (
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"

        die()   { echo "die: $*" >&2; exit 1; }
        log()   { :; }
        warn()  { :; }
        require_cmd()    { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }
        ensure_unlocked()  { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        list_categories() { ls "${COFFER_VAULT}"; }
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/get.sh"
        cmd_get apple/sso-token >/dev/null 2>&1
    ) || rc=$?
    rm -rf "$sandbox"

    if [[ $rc -eq 0 ]]; then
        echo "  FAIL: cmd_get unexpectedly succeeded after delete"
        return 1
    fi
    return 0
}

test_delete_retype_confirm_proceeds_on_match() {
    # When the user retypes the path correctly at the prompt, delete proceeds.
    if ! command -v age-keygen >/dev/null || ! command -v sops >/dev/null; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    age-keygen -o "${sandbox}/key.txt" 2>/dev/null
    local pub_key secret_key
    pub_key=$(grep "public key" "${sandbox}/key.txt" | awk '{print $4}')
    secret_key=$(grep "^AGE-SECRET-KEY-" "${sandbox}/key.txt")

    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    cat > "${sandbox}/config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: vault/.*\.yaml\$
    age: >-
      ${pub_key}
EOF

    (
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"
        die() { echo "die: $*" >&2; exit 1; }
        log() { :; }; warn() { :; }
        require_cmd() { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }; ensure_unlocked() { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/set.sh"
        cmd_set retype/key "value"
    ) || { rm -rf "$sandbox"; echo "  FAIL: setup failed"; return 1; }

    local rc=0
    (
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"
        die() { echo "die: $*" >&2; exit 1; }
        log() { :; }; warn() { :; }
        require_cmd() { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }; ensure_unlocked() { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        list_categories() { ls "${COFFER_VAULT}"; }
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/delete.sh"
        # Pipe the matching path string into the retype prompt.
        printf 'retype/key\n' | cmd_delete retype/key
    ) || rc=$?

    local has_key
    has_key=$(SOPS_AGE_KEY="$secret_key" sops decrypt --output-type json \
        "${sandbox}/vault/retype.yaml" 2>/dev/null | jq 'has("key")')
    rm -rf "$sandbox"

    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: cmd_delete returned non-zero after correct retype"
        return 1
    fi
    assert_eq "false" "$has_key" "key must be removed when user retypes path correctly"
}

test_delete_retype_confirm_aborts_on_mismatch() {
    # When the user retypes anything other than the exact path, the delete
    # must abort and the key must remain intact.
    if ! command -v age-keygen >/dev/null || ! command -v sops >/dev/null; then
        echo "  SKIP (age-keygen or sops not installed)"
        return 0
    fi

    local sandbox
    sandbox=$(mktemp -d)
    age-keygen -o "${sandbox}/key.txt" 2>/dev/null
    local pub_key secret_key
    pub_key=$(grep "public key" "${sandbox}/key.txt" | awk '{print $4}')
    secret_key=$(grep "^AGE-SECRET-KEY-" "${sandbox}/key.txt")

    mkdir -p "${sandbox}/vault" "${sandbox}/config"
    cat > "${sandbox}/config/.sops.yaml" <<EOF
creation_rules:
  - path_regex: vault/.*\.yaml\$
    age: >-
      ${pub_key}
EOF

    (
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"
        die() { echo "die: $*" >&2; exit 1; }
        log() { :; }; warn() { :; }
        require_cmd() { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }; ensure_unlocked() { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/set.sh"
        cmd_set safe/key "value"
    ) || { rm -rf "$sandbox"; echo "  FAIL: setup failed"; return 1; }

    local rc=0
    (
        export SOPS_AGE_KEY="$secret_key"
        export COFFER_VAULT="${sandbox}/vault"
        export COFFER_SOPS_CONFIG="${sandbox}/config/.sops.yaml"
        export COFFER_AUTO_SYNC=0
        export COFFER_NTFY_TOPIC="http://localhost:1/fake"
        die() { echo "die: $*" >&2; exit 1; }
        log() { :; }; warn() { :; }
        require_cmd() { command -v "$1" >/dev/null || die "$1 missing"; }
        require_identity() { :; }; ensure_unlocked() { :; }
        parse_path() {
            COFFER_CATEGORY="${1%%/*}"; COFFER_KEY="${1#*/}"
            COFFER_VAULT_FILE="${COFFER_VAULT}/${COFFER_CATEGORY}.yaml"
            export COFFER_CATEGORY COFFER_KEY COFFER_VAULT_FILE
        }
        list_categories() { ls "${COFFER_VAULT}"; }
        source "$(cd "${SCRIPT_DIR}/.." && pwd)/lib/delete.sh"
        # User typed a yes-ish answer instead of the actual path -- must abort.
        printf 'y\n' | cmd_delete safe/key
    ) || rc=$?

    local has_key
    has_key=$(SOPS_AGE_KEY="$secret_key" sops decrypt --output-type json \
        "${sandbox}/vault/safe.yaml" 2>/dev/null | jq 'has("key")')
    rm -rf "$sandbox"

    # cmd_delete returns 0 on user-aborted (no error, just no-op).
    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: cmd_delete must exit 0 on user abort (returned ${rc})"
        return 1
    fi
    assert_eq "true" "$has_key" "key must remain when user does not retype path"
}

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
    run_test test_parse_path_rejects_dotdot_category
    run_test test_parse_path_rejects_traversal_in_category
    run_test test_parse_path_rejects_leading_dot_category
    run_test test_parse_path_rejects_bad_chars_category
    run_test test_parse_path_rejects_dotdot_key
    run_test test_parse_path_still_accepts_normal_category

    # List tests
    run_test test_list_with_test_vault
    run_test test_list_single_category
    run_test test_list_missing_category_fails
    # Bug C regression: empty/null vault files must not crash list
    run_test test_list_empty_map_category_does_not_crash
    run_test test_list_null_category_does_not_crash

    # Get error case tests
    run_test test_get_missing_category_fails
    run_test test_get_no_args_fails

    # Entrypoint tests
    run_test test_coffer_no_command_fails
    run_test test_coffer_unknown_command_fails
    run_test test_coffer_help
    run_test test_coffer_version

    # Set: recipient preservation regression tests
    run_test test_set_preserves_all_recipients_on_create
    run_test test_set_preserves_all_recipients_on_update

    # Delete command tests (feat/delete-command, May 2026)
    run_test test_delete_removes_key
    run_test test_delete_preserves_recipients
    run_test test_delete_missing_key_fails
    run_test test_delete_missing_category_fails
    run_test test_delete_no_args_fails
    run_test test_delete_unknown_flag_fails
    run_test test_delete_routed_by_dispatcher
    run_test test_delete_round_trip_set_delete_get_fails
    run_test test_delete_retype_confirm_proceeds_on_match
    run_test test_delete_retype_confirm_aborts_on_mismatch

    # Identity: Option 2 (file-only, no Keychain) tests
    run_test test_require_identity_passes_with_file
    run_test test_require_identity_fails_without_file
    run_test test_require_identity_fails_on_empty_file
    run_test test_ensure_unlocked_loads_from_file
    run_test test_ensure_unlocked_prefers_env_var
    run_test test_ensure_unlocked_fails_without_file_or_env
    run_test test_no_keychain_calls_in_library
    run_test test_unlock_reads_from_file
    run_test test_unlock_auto_is_noop
    run_test test_lock_does_not_delete_file

    # Onboard bootstrap tests
    run_test test_onboard_writes_pending_file
    run_test test_onboard_skips_init_if_identity_exists
    run_test test_finalize_onboard_no_pending_files
    run_test test_onboard_rejects_unknown_args
    run_test test_finalize_onboard_rejects_unknown_args
    # Bug B regression: machine-name whitespace trimming must preserve internal spaces
    run_test test_onboard_whitespace_machine_name_internal_space
    run_test test_onboard_whitespace_machine_name_leading_trailing

    # Doctor and auto-sync tests (feat/doctor-and-auto-sync, April 2026)
    run_test test_doctor_clean_vault_exits_zero
    run_test test_doctor_drifted_vault_exits_one
    run_test test_auto_sync_push_disabled_by_env
    run_test test_auto_sync_push_non_main_commits_only
    run_test test_preflight_blocks_write_on_drift

    # auto_sync_pull tests (feat/auto-pull-before-write, April 2026)
    run_test test_auto_sync_pull_disabled_by_env
    run_test test_auto_sync_pull_noop_when_current
    run_test test_auto_sync_pull_pulls_when_behind
    run_test test_auto_sync_pull_pushes_local_ahead_commits

    # refresh command + sync-pull alias tests (feat/coffer-refresh-command, April 2026)
    run_test test_refresh_command_works
    run_test test_sync_pull_alias_prints_deprecation

    # SOPS merge driver tests (feat/sops-merge-driver, June 2026)
    run_test test_merge_driver_diverged_add_unions
    run_test test_merge_driver_true_conflict_fails_loudly
    run_test test_merge_driver_heals_recipient_drift
    run_test test_merge_driver_delete_vs_modify_conflicts
    run_test test_merge_driver_no_plaintext_leak
    run_test test_install_merge_driver_registers_and_routes
    run_test test_merge_driver_real_git_rebase_auto_unions

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

# --- refresh command and sync-pull alias tests ---
#
# These tests drive the real `bin/coffer` dispatcher (not lib functions directly)
# so they verify the routing layer, not just the underlying cmd_refresh logic.
# The heavy sync-pull behavioural tests (dirty tree, ahead/behind, rebase) are
# already covered by the auto_sync_pull test group above.

# e. `coffer refresh` routes correctly and exits 0 when vault is up to date.
test_refresh_command_works() {
    # Use SCRIPT_DIR to find the real bin/coffer regardless of COFFER_ROOT
    # overrides set by setup_test_env. SCRIPT_DIR points at tests/, so ../bin/coffer
    # is the real binary.
    local real_coffer="${SCRIPT_DIR}/../bin/coffer"
    local sandbox
    sandbox=$(mktemp -d)
    # Create a minimal bare origin and a local clone to satisfy the vault resolver.
    git init --bare "${sandbox}/origin.git" -q
    git -C "${sandbox}/origin.git" symbolic-ref HEAD refs/heads/main
    git clone "${sandbox}/origin.git" "${sandbox}/local" -q 2>/dev/null

    local output rc=0
    output=$(
        COFFER_VAULT_ROOT="${sandbox}/local" \
        "$real_coffer" refresh 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    assert_eq 0 "$rc" "coffer refresh should exit 0 when vault is up to date" && \
    assert_contains "$output" "up to date" "coffer refresh should report vault is up to date"
}

# f. `coffer sync-pull` still works (deprecated alias) and prints a warning.
test_sync_pull_alias_prints_deprecation() {
    local real_coffer="${SCRIPT_DIR}/../bin/coffer"
    local sandbox
    sandbox=$(mktemp -d)
    git init --bare "${sandbox}/origin.git" -q
    git -C "${sandbox}/origin.git" symbolic-ref HEAD refs/heads/main
    git clone "${sandbox}/origin.git" "${sandbox}/local" -q 2>/dev/null

    local output rc=0
    output=$(
        COFFER_VAULT_ROOT="${sandbox}/local" \
        "$real_coffer" sync-pull 2>&1
    ) || rc=$?

    rm -rf "$sandbox"

    assert_eq 0 "$rc" "coffer sync-pull (alias) should exit 0 when vault is up to date" && \
    assert_contains "$output" "deprecated" "coffer sync-pull should print a deprecation warning"
}

# =============================================================================
# --- SOPS merge driver tests (feat/sops-merge-driver, June 2026) ---
#
# These cover lib/merge-driver.sh (the coffer-aware union merge driver) and
# lib/install-merge-driver.sh. They generate EPHEMERAL age keypairs and dummy
# secrets at runtime (age-keygen) -- NO secret values are committed to the repo.
# The driver is exercised both directly (cmd_merge_driver with crafted sides)
# and through a real `git rebase` to prove the auto_sync_pull integration.
# =============================================================================

# _md_sandbox <sandbox>
#   Generate two ephemeral age keypairs and a current .sops.yaml listing BOTH as
#   recipients. Sets, in the CALLER's scope (no subshell):
#     MD_PUBA MD_PUBB MD_SECA  (key A is "this machine")
#     MD_VAULT MD_SOPS MD_CFG  (vault dir, current sops config, config dir)
#     MD_STALE_SOPS            (a single-recipient [A only] sops config)
#   Also exports the COFFER_* env the driver needs and SOPS_AGE_KEY (=A's secret).
_md_sandbox() {
    local sandbox="$1"
    mkdir -p "${sandbox}/vault" "${sandbox}/config" "${sandbox}/cfg"

    age-keygen -o "${sandbox}/keyA.txt" 2>/dev/null
    age-keygen -o "${sandbox}/keyB.txt" 2>/dev/null
    MD_PUBA=$(grep "public key" "${sandbox}/keyA.txt" | awk '{print $4}')
    MD_PUBB=$(grep "public key" "${sandbox}/keyB.txt" | awk '{print $4}')
    MD_SECA=$(grep AGE-SECRET "${sandbox}/keyA.txt")

    MD_VAULT="${sandbox}/vault"
    MD_SOPS="${sandbox}/config/.sops.yaml"
    MD_CFG="${sandbox}/cfg"
    MD_STALE_SOPS="${sandbox}/config/.sops.stale.yaml"

    cat > "$MD_SOPS" <<EOF
creation_rules:
  - path_regex: vault/.*\\.yaml\$
    age: >-
      ${MD_PUBA},${MD_PUBB}
EOF
    cat > "$MD_STALE_SOPS" <<EOF
creation_rules:
  - path_regex: vault/.*\\.yaml\$
    age: >-
      ${MD_PUBA}
EOF

    printf '%s\n' "$MD_SECA" > "${MD_CFG}/.session-key"
    chmod 600 "${MD_CFG}/.session-key"

    export COFFER_VAULT_ROOT="$sandbox"
    export COFFER_VAULT="$MD_VAULT"
    export COFFER_SOPS_CONFIG="$MD_SOPS"
    export COFFER_CONFIG_DIR="$MD_CFG"
    export COFFER_SESSION_KEY="${MD_CFG}/.session-key"
    export COFFER_NTFY_TOPIC="http://localhost:1/fake"
    export SOPS_AGE_KEY="$MD_SECA"
}

# _md_enc <json> <outfile> [sops_config]
#   Encrypt a dummy JSON map to a SOPS YAML file using the given (or current)
#   .sops.yaml. Uses a vault-relative --filename-override so the creation_rule
#   path_regex matches.
_md_enc() {
    local json="$1" out="$2" cfg="${3:-$MD_SOPS}"
    printf '%s' "$json" \
        | SOPS_AGE_KEY="$MD_SECA" SOPS_CONFIG="$cfg" sops encrypt \
            --filename-override "vault/$(basename "$out")" \
            --input-type json --output-type yaml /dev/stdin > "$out"
}

# _md_run <base> <ours> <theirs> <path>
#   Invoke the real bin/coffer merge-driver dispatcher path on three crafted
#   side files. Captures combined stderr in MD_STDERR and returns the rc.
_md_run() {
    local base="$1" ours="$2" theirs="$3" path="$4"
    local rc=0
    MD_STDERR=$(bash "${SCRIPT_DIR}/../bin/coffer" merge-driver \
        "$base" "$ours" "$theirs" 7 "$path" 2>&1 >/dev/null) || rc=$?
    return $rc
}

# (a) diverged-add: branchA adds keyA, branchB adds keyB -> BOTH present,
#     re-encrypted to current recipients.
test_merge_driver_diverged_add_unions() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"; return 0
    fi
    local sb; sb=$(mktemp -d); _md_sandbox "$sb"

    _md_enc '{"seed":"s"}'               "${sb}/base.yaml"
    _md_enc '{"seed":"s","keyA":"valA"}' "${sb}/ours.yaml"
    _md_enc '{"seed":"s","keyB":"valB"}' "${sb}/theirs.yaml"

    local rc=0
    _md_run "${sb}/base.yaml" "${sb}/ours.yaml" "${sb}/theirs.yaml" "vault/test.yaml" || rc=$?
    if [[ $rc -ne 0 ]]; then
        echo "  FAIL: clean different-key merge exited ${rc} (expected 0); stderr: ${MD_STDERR}"
        rm -rf "$sb"; return 1
    fi

    local merged
    merged=$(SOPS_AGE_KEY="$MD_SECA" sops decrypt --input-type yaml --output-type json "${sb}/ours.yaml" 2>/dev/null)
    local union_ok=0
    printf '%s' "$merged" | jq -e '.keyA=="valA" and .keyB=="valB" and .seed=="s"' >/dev/null 2>&1 && union_ok=1

    # Recipient heal/parity: key B (the "other machine") must be able to decrypt.
    local b_ok=0
    SOPS_AGE_KEY=$(grep AGE-SECRET "${sb}/keyB.txt") sops decrypt --input-type yaml "${sb}/ours.yaml" >/dev/null 2>&1 && b_ok=1

    rm -rf "$sb"
    if [[ $union_ok -eq 0 ]]; then echo "  FAIL: merged map missing keyA/keyB/seed"; return 1; fi
    if [[ $b_ok -eq 0 ]]; then echo "  FAIL: merged file not encrypted to current recipient set (key B locked out)"; return 1; fi
    return 0
}

# (b) true-conflict: both set same key to different values -> FAILS loudly
#     (non-zero) and leaks NO values.
test_merge_driver_true_conflict_fails_loudly() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"; return 0
    fi
    local sb; sb=$(mktemp -d); _md_sandbox "$sb"

    _md_enc '{"seed":"s"}'                    "${sb}/base.yaml"
    _md_enc '{"seed":"s","keyX":"SECRETOURS"}'   "${sb}/ours.yaml"
    _md_enc '{"seed":"s","keyX":"SECRETTHEIRS"}' "${sb}/theirs.yaml"

    # Snapshot ours BEFORE merge: on conflict the driver must NOT overwrite %A.
    local before; before=$(cat "${sb}/ours.yaml")

    local rc=0
    _md_run "${sb}/base.yaml" "${sb}/ours.yaml" "${sb}/theirs.yaml" "vault/test.yaml" || rc=$?

    local after; after=$(cat "${sb}/ours.yaml")
    local leaked=0
    printf '%s' "$MD_STDERR" | grep -qE 'SECRETOURS|SECRETTHEIRS' && leaked=1

    rm -rf "$sb"
    if [[ $rc -eq 0 ]]; then echo "  FAIL: same-key/different-value merge exited 0 (expected non-zero conflict)"; return 1; fi
    if [[ "$before" != "$after" ]]; then echo "  FAIL: driver overwrote %A on a true conflict (must leave it for git)"; return 1; fi
    assert_contains "$MD_STDERR" "keyX" "conflict message should name the conflicting key" || return 1
    if [[ $leaked -eq 1 ]]; then echo "  FAIL: SECRET VALUE LEAKED in conflict output"; return 1; fi
    return 0
}

# (c) recipient-drift: ours encrypted to a STALE (A-only) .sops.yaml, theirs to
#     current (A+B). A clean different-key union must re-encrypt to the CURRENT
#     recipient set (B can decrypt the merged result).
test_merge_driver_heals_recipient_drift() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"; return 0
    fi
    local sb; sb=$(mktemp -d); _md_sandbox "$sb"

    _md_enc '{"seed":"s"}'              "${sb}/base.yaml"
    # ours: stale single-recipient (A only)
    _md_enc '{"seed":"s","onlyA":"v"}' "${sb}/ours.yaml" "$MD_STALE_SOPS"
    _md_enc '{"seed":"s","onlyB":"w"}' "${sb}/theirs.yaml"

    # Sanity: ours must NOT be decryptable by B before the merge.
    if SOPS_AGE_KEY=$(grep AGE-SECRET "${sb}/keyB.txt") sops decrypt --input-type yaml "${sb}/ours.yaml" >/dev/null 2>&1; then
        rm -rf "$sb"; echo "  FAIL: test setup wrong -- stale 'ours' already decryptable by B"; return 1
    fi

    local rc=0
    _md_run "${sb}/base.yaml" "${sb}/ours.yaml" "${sb}/theirs.yaml" "vault/test.yaml" || rc=$?
    if [[ $rc -ne 0 ]]; then echo "  FAIL: drift-heal merge exited ${rc} (expected 0); stderr: ${MD_STDERR}"; rm -rf "$sb"; return 1; fi

    local healed=0
    SOPS_AGE_KEY=$(grep AGE-SECRET "${sb}/keyB.txt") sops decrypt --input-type yaml "${sb}/ours.yaml" >/dev/null 2>&1 && healed=1
    rm -rf "$sb"
    if [[ $healed -eq 0 ]]; then echo "  FAIL: merged file still encrypted to stale recipients (drift not healed)"; return 1; fi
    return 0
}

# (d) delete-vs-modify: ours deletes key, theirs modifies it -> conflict.
test_merge_driver_delete_vs_modify_conflicts() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"; return 0
    fi
    local sb; sb=$(mktemp -d); _md_sandbox "$sb"

    _md_enc '{"seed":"s","k":"orig"}'    "${sb}/base.yaml"
    _md_enc '{"seed":"s"}'               "${sb}/ours.yaml"     # deleted k
    _md_enc '{"seed":"s","k":"changed"}' "${sb}/theirs.yaml"   # modified k

    local rc=0
    _md_run "${sb}/base.yaml" "${sb}/ours.yaml" "${sb}/theirs.yaml" "vault/test.yaml" || rc=$?
    local leaked=0
    printf '%s' "$MD_STDERR" | grep -q 'changed' && leaked=1
    rm -rf "$sb"
    if [[ $rc -eq 0 ]]; then echo "  FAIL: delete-vs-modify merged cleanly (expected conflict)"; return 1; fi
    assert_contains "$MD_STDERR" "k" "conflict message should name the deleted/modified key" || return 1
    if [[ $leaked -eq 1 ]]; then echo "  FAIL: value 'changed' leaked in conflict output"; return 1; fi
    return 0
}

# (e) no-plaintext-leak guard: static source check + runtime stdout/stderr check.
test_merge_driver_no_plaintext_leak() {
    local real_root; real_root="$(cd "${SCRIPT_DIR}/.." && pwd)"

    # Static: the driver must never enable `set -x` or echo a decrypted *_json var.
    local hits
    hits=$(grep -nE 'set -x|echo[[:space:]]+"?\$(base_json|ours_json|theirs_json|merge_out|merged|decrypted)' \
        "${real_root}/lib/merge-driver.sh" 2>/dev/null || true)
    if [[ -n "$hits" ]]; then
        echo "  FAIL: merge-driver.sh contains a potential plaintext-leak pattern:"
        echo "$hits"
        return 1
    fi

    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  (static check passed; SKIP runtime portion -- age-keygen/sops missing)"
        return 0
    fi

    # Runtime: a clean merge must not print the plaintext value anywhere on
    # stdout or stderr (the only durable output is the ciphertext written to %A).
    local sb; sb=$(mktemp -d); _md_sandbox "$sb"
    _md_enc '{"seed":"s"}'                       "${sb}/base.yaml"
    _md_enc '{"seed":"s","kA":"PLAINTOKENAAA"}'  "${sb}/ours.yaml"
    _md_enc '{"seed":"s","kB":"PLAINTOKENBBB"}'  "${sb}/theirs.yaml"

    local combined
    combined=$(bash "${SCRIPT_DIR}/../bin/coffer" merge-driver \
        "${sb}/base.yaml" "${sb}/ours.yaml" "${sb}/theirs.yaml" 7 "vault/test.yaml" 2>&1) || true
    rm -rf "$sb"

    if printf '%s' "$combined" | grep -qE 'PLAINTOKENAAA|PLAINTOKENBBB'; then
        echo "  FAIL: decrypted plaintext token appeared in merge-driver stdout/stderr"
        return 1
    fi
    return 0
}

# install-merge-driver: registers the per-clone driver and writes routing lines,
# including the config/.sops.yaml exclusion (it must NOT use the union driver).
test_install_merge_driver_registers_and_routes() {
    if ! command -v age-keygen >/dev/null 2>&1; then echo "  SKIP (age-keygen not installed)"; return 0; fi
    local sb; sb=$(mktemp -d); _md_sandbox "$sb"

    # Make the sandbox a git repo so install-merge-driver has somewhere to write.
    git -C "$sb" init -q
    git -C "$sb" config user.email t@t.local; git -C "$sb" config user.name T

    # Run with auto-sync off so the test does no commit/push (just config + file).
    local rc=0
    COFFER_AUTO_SYNC=0 bash "${SCRIPT_DIR}/../bin/coffer" install-merge-driver >/dev/null 2>&1 || rc=$?
    if [[ $rc -ne 0 ]]; then echo "  FAIL: install-merge-driver exited ${rc}"; rm -rf "$sb"; return 1; fi

    local driver; driver=$(git -C "$sb" config --get merge.coffer-sops.driver 2>/dev/null || echo "")
    local attrs; attrs=$(cat "${sb}/.gitattributes" 2>/dev/null || echo "")
    rm -rf "$sb"

    assert_contains "$driver" "merge-driver" "merge.coffer-sops.driver should invoke coffer merge-driver" || return 1
    assert_contains "$attrs" "vault/** merge=coffer-sops" "gitattributes should route vault/** to the union driver" || return 1
    assert_contains "$attrs" "config/.sops.yaml -merge" "gitattributes must EXCLUDE config/.sops.yaml from the union driver" || return 1
    return 0
}

# Full integration: install the driver in a real repo, create two divergent
# different-key commits, `git rebase`, and assert it auto-unions (proving the
# auto_sync_pull pull --rebase path resolves cleanly) AND that a same-key
# collision instead leaves the path conflicted.
test_merge_driver_real_git_rebase_auto_unions() {
    if ! command -v age-keygen >/dev/null 2>&1 || ! command -v sops >/dev/null 2>&1; then
        echo "  SKIP (age-keygen or sops not installed)"; return 0
    fi
    local sb; sb=$(mktemp -d); _md_sandbox "$sb"
    local real_coffer="${SCRIPT_DIR}/../bin/coffer"

    git -C "$sb" init -q
    git -C "$sb" config user.email t@t.local; git -C "$sb" config user.name T

    # Register the driver (auto-sync off: no push, just config + .gitattributes).
    COFFER_AUTO_SYNC=0 bash "$real_coffer" install-merge-driver >/dev/null 2>&1

    # Seed a base commit with one key.
    COFFER_AUTO_SYNC=0 bash "$real_coffer" set test/seed sval >/dev/null 2>&1
    git -C "$sb" add -A; git -C "$sb" commit -qm seed

    # theirs branch: a different key.
    git -C "$sb" checkout -qb theirs
    COFFER_AUTO_SYNC=0 bash "$real_coffer" set test/fromTheirs tval >/dev/null 2>&1
    git -C "$sb" add -A; git -C "$sb" commit -qm theirs

    # Check out the commit that has only the seed (theirs' parent), then branch.
    git -C "$sb" checkout -q "$(git -C "$sb" rev-parse theirs~1)" 2>/dev/null
    git -C "$sb" checkout -qB work
    COFFER_AUTO_SYNC=0 bash "$real_coffer" set test/fromOurs oval >/dev/null 2>&1
    git -C "$sb" add -A; git -C "$sb" commit -qm ours

    # Rebase the different-key commit onto theirs -> driver should auto-union.
    local rebase_rc=0
    git -C "$sb" rebase theirs >/dev/null 2>&1 || rebase_rc=$?
    if [[ $rebase_rc -ne 0 ]]; then
        git -C "$sb" rebase --abort 2>/dev/null || true
        echo "  FAIL: rebase of a different-key write did not auto-merge (exit ${rebase_rc})"
        rm -rf "$sb"; return 1
    fi
    local merged
    merged=$(SOPS_AGE_KEY="$MD_SECA" sops decrypt --input-type yaml --output-type json "${sb}/vault/test.yaml" 2>/dev/null)
    local union_ok=0
    printf '%s' "$merged" | jq -e '.seed=="sval" and .fromOurs=="oval" and .fromTheirs=="tval"' >/dev/null 2>&1 && union_ok=1
    if [[ $union_ok -eq 0 ]]; then echo "  FAIL: rebase did not union all three keys; got: ${merged}"; rm -rf "$sb"; return 1; fi

    # Now a true same-key collision must leave the rebase conflicted.
    git -C "$sb" checkout -qB tcol theirs
    COFFER_AUTO_SYNC=0 bash "$real_coffer" set test/collide theirsval >/dev/null 2>&1
    git -C "$sb" add -A; git -C "$sb" commit -qm tcol
    git -C "$sb" checkout -q "$(git -C "$sb" rev-parse tcol~1)" 2>/dev/null
    git -C "$sb" checkout -qB ocol
    COFFER_AUTO_SYNC=0 bash "$real_coffer" set test/collide oursval >/dev/null 2>&1
    git -C "$sb" add -A; git -C "$sb" commit -qm ocol
    local col_rc=0
    git -C "$sb" rebase tcol >/dev/null 2>&1 || col_rc=$?
    local conflicted=0
    git -C "$sb" status --porcelain 2>/dev/null | grep -qE '^(UU|AA|U|DD)' && conflicted=1
    git -C "$sb" rebase --abort 2>/dev/null || true
    rm -rf "$sb"

    if [[ $col_rc -eq 0 ]]; then echo "  FAIL: rebase of a same-key collision succeeded (expected conflict)"; return 1; fi
    if [[ $conflicted -eq 0 ]]; then echo "  FAIL: same-key collision did not leave the path conflicted"; return 1; fi
    return 0
}

main "$@"
