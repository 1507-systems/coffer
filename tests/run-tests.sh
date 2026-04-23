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
